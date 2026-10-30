# CancelHoldLink

Plugin Koha (25.05+) qui permet d'insérer dans un avis un lien d'annulation de réservation utilisable **sans se connecter**.

## Fonctionnement

1. Le hook `notices_content` génère, pour tout avis qui reçoit une réservation, un lien
   `OPACBaseURL/api/v1/contrib/cancelhold/holds/cancel?token=…`.
2. Le jeton est un JWT HS256 (`Mojo::JWT`) contenant `reserve_id`, `borrowernumber` et une expiration.
   Il est signé avec une clé aléatoire stockée dans les données du plugin. Aucune table n'est ajoutée.
3. `GET` affiche une page de confirmation. Rien n'est annulé à ce stade, pour que les antivirus de
   courriel qui ouvrent les liens à l'avance n'annulent pas de réservation.
4. `POST` vérifie le jeton, puis que la réservation existe, appartient toujours à l'abonné et peut être annulée,
   avant d'appeler `Koha::Hold->cancel`. Une fois la réservation annulée, le lien n'a plus d'effet.

Les routes API de plugin sans `x-koha-authorization` sont acceptées de façon anonyme par Koha
(`Koha/REST/V1/Auth.pm`); le jeton est donc la seule autorisation.

## Utilisation dans un avis

Avis qui concernent une seule réservation (HOLD, HOLDDGST, HOLDPLACED_PATRON) :

```
[% IF plugin_content.cancelhold.cancel_url %]
<a href="[% plugin_content.cancelhold.cancel_url %]">Annuler cette réservation</a>
[% END %]
```

HOLDDGST fonctionne comme HOLD : Koha prépare chaque réservation séparément puis les ajoute au même message,
donc chaque bloc a son propre lien.

Avis qui bouclent sur plusieurs réservations (HOLD_REMINDER) : un lien par réservation.

```
[% FOREACH hold IN holds %]
[% hold.biblio.title %]
[% SET url = plugin_content.cancelhold.cancel_urls.${hold.reserve_id} %]
[% IF url %]<a href="[% url %]">Annuler cette réservation</a>[% END %]
[% END %]
```

HOLDPLACED est destiné à la bibliothèque, pas à l'abonné.

## Réservations en attente de retrait

Les réservations non encore attribuées sont annulées directement. Pour une réservation déjà en attente (HOLD, HOLDDGST, HOLD_REMINDER),
le comportement se configure :

- **Demande d'annulation** (par défaut) : même comportement que l'OPAC. Une demande est créée si la règle de circulation
  `waiting_hold_cancellation` le permet. Le personnel la traite dans Circulation › Réservations à récupérer, ce qui permet
  de passer l'exemplaire à la réservation suivante.
- **Annulation immédiate** : la réservation est annulée, mais l'exemplaire reste sur la tablette jusqu'à ce que le personnel le traite.
- **Refusée**.

## Langue de la page

Choisie comme à l'OPAC, parmi les langues activées dans `OPACLanguages` : paramètre `lang` du lien (langue de
l'abonné), langue choisie à l'OPAC (cookie `KohaOpacLanguage`), langue de l'abonné, langue du navigateur, puis
première langue de `OPACLanguages`. Les textes existent en français et en anglais; toute autre langue affiche l'anglais.

## Configuration

- Validité du lien en jours (30 par défaut).
- Comportement pour les réservations en attente de retrait (voir plus haut).
- Motif d'annulation (valeur autorisée HOLD_CANCELLATION, optionnel).
- Régénérer la clé secrète, ce qui invalide tous les liens déjà envoyés.

## Prérequis

- Koha 25.05 ou plus récent : le hook `notices_content` n'existe pas en 24.11.
- `OPACBaseURL` renseignée, et `/api` accessible depuis le domaine de l'OPAC.
- Plugins activés (`enable_plugins` dans `koha-conf.xml`), et serveur Plack redémarré après l'installation pour charger les routes.
