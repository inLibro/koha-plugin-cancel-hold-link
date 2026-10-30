package Koha::Plugin::CancelHoldLink::Controller;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;
use utf8;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util qw( url_escape xml_escape );
use Try::Tiny;

use C4::Context;
use C4::Languages;
use Koha::Plugin::CancelHoldLink;

my %STATUS = (
    invalid        => 400,
    expired        => 400,
    not_found      => 404,
    not_cancelable    => 409,
    already_requested => 409,
    failed         => 500,
);

my %STRINGS = (
    fr => {
        title          => 'Annulation de réservation',
        confirm        => 'Voulez-vous vraiment annuler votre réservation pour ce document?',
        pickup         => 'Lieu de retrait',
        button         => 'Annuler la réservation',
        done           => 'Votre réservation a été annulée.',
        confirm_request =>
            "Ce document vous attend déjà à la bibliothèque. Voulez-vous demander l'annulation de cette réservation? Votre demande sera traitée par le personnel.",
        button_request    => "Demander l'annulation",
        done_request      => "Votre demande d'annulation a été transmise à la bibliothèque.",
        already_requested => "Une demande d'annulation a déjà été transmise à la bibliothèque pour cette réservation.",
        invalid        => "Ce lien d'annulation est invalide.",
        expired        => "Ce lien d'annulation a expiré. Connectez-vous à votre dossier pour gérer vos réservations.",
        not_found      => "Cette réservation n'existe plus. Elle a peut-être déjà été annulée ou complétée.",
        not_cancelable => 'Cette réservation ne peut plus être annulée en ligne. Veuillez communiquer avec votre bibliothèque.',
        failed         => "Une erreur est survenue lors de l'annulation. Veuillez communiquer avec votre bibliothèque.",
        opac           => 'Retour au catalogue',
    },
    en => {
        title          => 'Hold cancellation',
        confirm        => 'Do you really want to cancel your hold on this item?',
        pickup         => 'Pickup location',
        button         => 'Cancel hold',
        done           => 'Your hold has been cancelled.',
        confirm_request =>
            'This item is already waiting for you at the library. Do you want to request the cancellation of this hold? Your request will be processed by library staff.',
        button_request    => 'Request cancellation',
        done_request      => 'Your cancellation request has been sent to the library.',
        already_requested => 'A cancellation request has already been sent to the library for this hold.',
        invalid        => 'This cancellation link is invalid.',
        expired        => 'This cancellation link has expired. Log in to your account to manage your holds.',
        not_found      => 'This hold no longer exists. It may already have been cancelled or filled.',
        not_cancelable => 'This hold can no longer be cancelled online. Please contact your library.',
        failed         => 'An error occurred while cancelling. Please contact your library.',
        opac           => 'Back to the catalog',
    },
);

=head1 API

=head2 Methods

=head3 show

Affiche la page de confirmation.

=cut

sub show {
    my $c = shift->openapi->valid_input or return;

    my ( $plugin, $hold, $action, $error ) = _load($c);
    return _page( $c, hold => $hold, error => $error ) if $error;
    return _page( $c, hold => $hold, action => $action, confirm => 1 );
}

=head3 cancel

Annule la réservation et affiche le résultat.

=cut

sub cancel {
    my $c = shift->openapi->valid_input or return;

    my ( $plugin, $hold, $action, $error ) = _load($c);
    return _page( $c, hold => $hold, error => $error ) if $error;

    try {
        if ( $action eq 'request' ) {
            $hold->add_cancellation_request;
        } else {
            $hold->cancel( { cancellation_reason => $plugin->cancellation_reason } );
        }
    } catch {
        warn sprintf( "CancelHoldLink: échec (%s) pour la réservation %s : %s", $action, $hold->reserve_id, $_ );
        $error = 'failed';
    };
    return _page( $c, hold => $hold, error => $error ) if $error;

    return _page( $c, hold => $hold, action => $action, done => 1 );
}

sub _load {
    my ($c) = @_;

    my $plugin = Koha::Plugin::CancelHoldLink->new;
    my ( $hold, $error ) = $plugin->check_token( $c->param('token') );
    return ( $plugin, undef, undef, $error ) if $error;

    my ( $action, $action_error ) = $plugin->action_for($hold);
    return ( $plugin, $hold, $action, $action_error );
}

# Langue de la page, choisie comme à l'OPAC (C4::Languages::getlanguage) parmi
# les langues activées dans OPACLanguages : paramètre du lien, langue choisie à
# l'OPAC (cookie), langue de l'abonné, navigateur, puis première langue activée.
sub _lang {
    my ( $c, $hold ) = @_;

    my @enabled = grep { $_ } split /,/, C4::Context->preference('OPACLanguages') // '';
    @enabled = ('en') unless @enabled;
    my $supported = [ map { { rfc4646_subtag => $_ } } @enabled ];

    my $patron = $hold ? $hold->patron : undef;
    my @candidates = (
        scalar $c->param('lang'),
        $c->cookie('KohaOpacLanguage'),
        $patron ? $patron->lang : undef,
        $c->req->headers->accept_language,
    );

    my $lang;
    for my $candidate (@candidates) {
        next if !$candidate || $candidate eq 'default';
        $lang = C4::Languages::accept_language( $candidate, $supported ) and last;
    }
    $lang ||= $enabled[0];

    return $lang =~ /^fr/i ? 'fr' : 'en';
}

sub _page {
    my ( $c, %args ) = @_;

    my $lang = _lang( $c, $args{hold} );
    my $s    = $STRINGS{$lang};
    my $body = '';

    if ( my $hold = $args{hold} ) {
        my $biblio  = $hold->biblio;
        my $library = $hold->pickup_library;
        $body .= sprintf( '<p class="doc"><strong>%s</strong>%s</p>',
            xml_escape( $biblio ? $biblio->title // '' : '' ),
            $biblio && $biblio->author ? ' — ' . xml_escape( $biblio->author ) : '' );
        $body .= sprintf( '<p>%s : %s</p>', $s->{pickup}, xml_escape( $library->branchname ) )
            if $library && ( $args{confirm} || $args{error} );
    }

    if ( $args{error} ) {
        $body = sprintf( '<p class="msg error">%s</p>', $s->{ $args{error} } ) . $body;
    } elsif ( $args{done} ) {
        my $done = $args{action} eq 'request' ? $s->{done_request} : $s->{done};
        $body = sprintf( '<p class="msg ok">%s</p>', $done ) . $body;
    } elsif ( $args{confirm} ) {
        my $is_request = $args{action} eq 'request';
        my $url        = '?token=' . url_escape( $c->param('token') ) . '&lang=' . $lang;
        $body = sprintf( '<p>%s</p>', $is_request ? $s->{confirm_request} : $s->{confirm} ) . $body;
        $body .= sprintf( '<form method="post" action="%s"><button type="submit">%s</button></form>',
            xml_escape($url), $is_request ? $s->{button_request} : $s->{button} );
    }

    my $opac = C4::Context->preference('OPACBaseURL') // '';
    $opac =~ s{/+$}{};
    $body .= sprintf( '<p class="back"><a href="%s/cgi-bin/koha/opac-main.pl">%s</a></p>', xml_escape($opac), $s->{opac} )
        if $opac;

    my $html = <<"HTML";
<!DOCTYPE html>
<html lang="$lang">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>$s->{title}</title>
<style>
  body { font-family: system-ui, sans-serif; background: #f4f4f4; color: #222; margin: 0; padding: 16px; }
  main { max-width: 560px; margin: 10vh auto; background: #fff; border-radius: 8px; padding: 24px 28px; box-shadow: 0 1px 4px rgba(0,0,0,.12); }
  h1 { font-size: 1.4rem; margin-top: 0; }
  .doc { font-size: 1.1rem; }
  .msg { padding: 12px; border-radius: 4px; }
  .ok { background: #e6f4ea; color: #1e5631; }
  .error { background: #fdecea; color: #8a1c13; }
  button { font-size: 1rem; padding: 10px 18px; border: 0; border-radius: 4px; background: #b3261e; color: #fff; cursor: pointer; }
  .back { margin-top: 24px; font-size: .9rem; }
</style>
</head>
<body>
<main>
<h1>$s->{title}</h1>
$body
</main>
</body>
</html>
HTML

    return $c->render(
        status => $args{error} ? $STATUS{ $args{error} } : 200,
        format => 'html',
        text   => $html,
    );
}

1;
