package Koha::Plugin::CancelHoldLink;
# inLibro, 2026
#
# Ajoute aux avis un lien permettant à l'abonné d'annuler une réservation
# sans se connecter. Le lien contient un JWT signé (reserve_id, borrowernumber,
# expiration) et pointe vers une route API du plugin qui affiche une page de
# confirmation (GET) puis annule la réservation (POST).
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
use Modern::Perl;
use utf8;
use base qw(Koha::Plugins::Base);

use Bytes::Random::Secure;
use Mojo::File;
use Mojo::JSON qw( decode_json );
use Mojo::JWT;
use Scalar::Util qw( blessed );
use Try::Tiny;
use URI::Escape qw( uri_escape_utf8 );

use C4::Context;
use Koha::Holds;

use constant TOKEN_SUBJECT       => 'cancel_hold';
use constant DEFAULT_EXPIRY_DAYS => 30;
use constant WAITING_MODES       => qw( none request cancel );
use constant DEFAULT_WAITING     => 'request';

our $VERSION  = '1.1.1';
our $metadata = {
    name            => 'CancelHoldLink',
    author          => 'inLibro',
    description     => "Lien d'annulation de réservation sans connexion, à insérer dans les avis",
    date_authored   => '2026-10-21',
    date_updated    => '2026-10-28',
    minimum_version => '25.05',
    maximum_version => undef,
    version         => $VERSION,
    # Clé utilisée par le hook notices_content : [% plugin_content.cancelhold.cancel_url %]
    namespace       => 'cancelhold',
};

sub new {
    my ( $class, $args ) = @_;
    $args->{metadata} = $metadata;
    $args->{metadata}->{class} = $class;
    return $class->SUPER::new($args);
}

sub install {
    my ($self) = @_;
    $self->_secret;
    $self->store_data( { expiry_days => DEFAULT_EXPIRY_DAYS } )
        unless defined $self->retrieve_data('expiry_days');
    return 1;
}

sub uninstall { return 1 }

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{cgi};

    my $template = $self->get_template( { file => 'configure.tt' } );

    if ( ( $cgi->param('op') // '' ) eq 'cud-save' ) {
        my $days = $cgi->param('expiry_days') // '';
        $days = DEFAULT_EXPIRY_DAYS unless $days =~ /^\d+$/ && $days > 0;
        my $waiting_mode = $cgi->param('waiting_mode') // '';
        $waiting_mode = DEFAULT_WAITING unless grep { $_ eq $waiting_mode } WAITING_MODES;
        $self->store_data(
            {
                expiry_days         => $days,
                waiting_mode        => $waiting_mode,
                cancellation_reason => scalar( $cgi->param('cancellation_reason') ) // '',
            }
        );
        $self->_secret( { regenerate => 1 } ) if $cgi->param('regenerate_secret');
        $template->param( saved => 1 );
    }

    $template->param(
        expiry_days         => $self->retrieve_data('expiry_days') || DEFAULT_EXPIRY_DAYS,
        waiting_mode        => $self->waiting_mode,
        cancellation_reason => $self->retrieve_data('cancellation_reason'),
        api_url             => $self->_api_base_url,
    );
    $self->output_html( $template->output );
}

=head2 API

=cut

sub api_namespace { return 'cancelhold' }

sub api_routes {
    my ($self) = @_;
    return decode_json( Mojo::File->new( $self->bundle_path, 'openapi.json' )->slurp );
}

=head2 Hook notices_content

Rend disponibles, dans tout avis (syntaxe Template Toolkit) qui reçoit une ou
plusieurs réservations :

=over

=item C<plugin_content.cancelhold.cancel_url> : le lien, quand l'avis concerne une seule réservation (HOLD, HOLDDGST, HOLDPLACED_PATRON…);

=item C<plugin_content.cancelhold.cancel_urls.${hold.reserve_id}> : le lien de chaque réservation, pour les avis qui bouclent sur C<holds> (HOLD_REMINDER).

=back

=cut

sub notices_content {
    my ( $self, $params ) = @_;

    my @reserve_ids = _reserve_ids_from($params) or return;
    my $holds       = Koha::Holds->search( { reserve_id => \@reserve_ids } );

    my %urls;
    while ( my $hold = $holds->next ) {
        my $url = $self->cancel_url( $hold, { lang => $params->{lang} } ) or return;
        $urls{ $hold->reserve_id } = $url;
    }
    return unless %urls;

    return {
        cancel_urls => \%urls,
        ( @reserve_ids == 1 ? ( cancel_url => $urls{ $reserve_ids[0] } ) : () ),
    };
}

=head2 Méthodes

=head3 cancel_url

    my $url = $plugin->cancel_url( $hold, { lang => 'fr-CA' } );

=cut

sub cancel_url {
    my ( $self, $hold, $args ) = @_;

    my $base = $self->_api_base_url or return;
    my $url  = "$base/holds/cancel?token=" . $self->generate_token($hold);

    my $lang = $args->{lang};
    $lang = $hold->patron->lang if !$lang || $lang eq 'default';
    $url .= '&lang=' . uri_escape_utf8($lang) if $lang && $lang ne 'default';

    return $url;
}

sub generate_token {
    my ( $self, $hold ) = @_;

    my $days = $self->retrieve_data('expiry_days') || DEFAULT_EXPIRY_DAYS;

    return Mojo::JWT->new(
        claims => {
            sub => TOKEN_SUBJECT,
            rid => $hold->reserve_id,
            bn  => $hold->borrowernumber,
        },
        secret  => $self->_secret,
        expires => time + $days * 86400,
    )->encode;
}

=head3 check_token

    my ( $hold, $error ) = $plugin->check_token($token);

Retourne la réservation, ou C<undef> et un code d'erreur : I<invalid>,
I<expired> ou I<not_found> (déjà annulée ou complétée).

=cut

sub check_token {
    my ( $self, $token ) = @_;

    return ( undef, 'invalid' ) unless $token;

    my ( $claims, $error );
    try {
        $claims = Mojo::JWT->new( secret => $self->_secret )->decode($token);
    } catch {
        $error = /expired/ ? 'expired' : 'invalid';
    };
    return ( undef, $error ) if $error;

    return ( undef, 'invalid' )
        unless ref $claims eq 'HASH'
        && ( $claims->{sub} // '' ) eq TOKEN_SUBJECT
        && $claims->{exp}
        && $claims->{rid}
        && $claims->{bn};

    my $hold = Koha::Holds->find( $claims->{rid} );
    return ( undef, 'not_found' ) unless $hold && $hold->borrowernumber == $claims->{bn};

    return ($hold);
}

=head3 action_for

    my ( $action, $error ) = $plugin->action_for($hold);

Retourne I<cancel> (annulation immédiate) ou I<request> (demande d'annulation
traitée par le personnel, comme à l'OPAC), sinon C<undef> et un code d'erreur :
I<not_cancelable> ou I<already_requested>.

Les réservations non encore attribuées sont annulées directement. Pour une
réservation en attente de retrait, cela dépend du mode configuré :

=over

=item I<none> : refusé;

=item I<request> : demande d'annulation si la règle de circulation
C<waiting_hold_cancellation> le permet (même comportement que l'OPAC);

=item I<cancel> : annulation immédiate.

=back

=cut

sub action_for {
    my ( $self, $hold ) = @_;

    return ('cancel') if $hold->is_cancelable_from_opac;
    return ( undef, 'not_cancelable' ) unless $hold->is_waiting;

    my $mode = $self->waiting_mode;
    return ('cancel') if $mode eq 'cancel';
    return ( undef, 'not_cancelable' ) unless $mode eq 'request';

    return ( undef, 'already_requested' ) if $hold->cancellation_requested;

    my $requestable = try { $hold->cancellation_requestable_from_opac } catch { 0 };
    return $requestable ? ('request') : ( undef, 'not_cancelable' );
}

sub waiting_mode {
    my ($self) = @_;

    my $mode = $self->retrieve_data('waiting_mode');
    return $mode if $mode;

    # Compatibilité avec la 1.0.0 (case à cocher allow_waiting)
    return $self->retrieve_data('allow_waiting') ? 'cancel' : DEFAULT_WAITING;
}

sub cancellation_reason {
    my ($self) = @_;
    return $self->retrieve_data('cancellation_reason') || undef;
}

# --- Internes ---

sub _api_base_url {
    my ($self) = @_;

    my $base = C4::Context->preference('OPACBaseURL') or return;
    $base =~ s{/+$}{};
    return "$base/api/v1/contrib/" . $self->api_namespace;
}

sub _secret {
    my ( $self, $args ) = @_;

    my $secret = $args->{regenerate} ? undef : $self->retrieve_data('secret');
    unless ($secret) {
        $secret = Bytes::Random::Secure->new( NonBlocking => 1 )->bytes_hex(32);
        $self->store_data( { secret => $secret } );
    }
    return $secret;
}

# Réservations reçues par l'avis : objects.hold, tables.reserves (HOLD,
# HOLDPLACED_PATRON…) ou loops.reserves (HOLD_REMINDER).
sub _reserve_ids_from {
    my ($params) = @_;

    my @candidates = (
        ( $params->{objects} // {} )->{hold},
        ( $params->{tables}  // {} )->{reserves},
    );
    my $loop = ( $params->{loops} // {} )->{reserves};
    push @candidates, ref $loop eq 'ARRAY' ? @$loop : $loop;

    my %seen;
    return grep { defined && !$seen{$_}++ } map { _reserve_id($_) } @candidates;
}

sub _reserve_id {
    my ($value) = @_;

    return unless defined $value;
    return $value->reserve_id if blessed $value && $value->can('reserve_id');
    return $value->{reserve_id} if ref $value eq 'HASH';
    return $value if !ref $value && $value =~ /^\d+$/;
    return;
}

1;
