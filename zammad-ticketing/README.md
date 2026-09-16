## Introduzione.
La presente guida si pone l'obiettivo di semplificare la prima installazione del portale
di ticketing basato sull'applicativo ZAMMAD

## PREREQUISITI INSTALLAZIONE :
Vedere Readme.md della guida all'installazione della piattaforma 

Nel caso in cui si voglia disabilitare la gestione dei ticket, va commentato/eliminato la property VITE_APP_ZAMMAD_HOST all'interno di httpd-config/config-prod.js : questo
nasconderà i bottoni e bloccherà le chiamate di polling di ricerca dei ticket

## Esposizione HTTPS e integrazione con lo stack principale

Zammad gira come stack Docker separato (questa cartella) sulla stessa macchina dello
stack principale IRCCS, dietro lo stesso Apache httpd (`irccs-httpd-dashboard`) che
termina già il certificato SSL wildcard `*.istitutotumori.na.it`.

**Perché non un sub-path** (es. `pj.istitutotumori.na.it/zammad-ui/`): Zammad non
supporta ufficialmente il deploy sotto sub-path (limite noto, non risolto nemmeno
nelle versioni 6.x — il router client-side assume di girare in root `/`). Tentato
inizialmente, causava schermata bianca/loading infinito e asset serviti come
`index.html` (mismatch MIME).

**Soluzione adottata: sottodominio dedicato, porta 443.**
Inizialmente si era optato per una porta dedicata (`8443`) sullo stesso hostname
`pj.istitutotumori.na.it`, perché non era disponibile un record DNS per un
sottodominio. Ora è stato ottenuto il record A per `pj-tk.istitutotumori.na.it` e
la porta 8443 non è comunque più raggiungibile dall'esterno per un problema di rete/
firewall perimetrale, quindi si è passati al sottodominio dedicato su 443. Zammad UI
è raggiungibile su:
```
https://pj-tk.istitutotumori.na.it/
```
stesso certificato wildcard del resto della piattaforma, nessuna porta aggiuntiva.

### Configurazione coinvolta

- `httpd-config/zammad.conf` (repo principale): `VirtualHost *:443`,
  `ServerName pj-tk.istitutotumori.na.it`, stesso cert wildcard, proxy diretto e pulito
  verso `irccs-zammad-railsserver:3000` (root, niente hack referer/sub-path) + websocket
  (`/ws`, `/cable`).
- `zammad-ticketing/.env`: `ZAMMAD_FQDN` e `NGINX_SERVER_NAME` puntano a
  `pj-tk.istitutotumori.na.it` (nessuna porta esplicita, è la 443 di default).
- `zammad-ticketing/docker-compose.yaml`:
  - `zammad-railsserver`: aggiunta `RAILS_SERVE_STATIC_FILES: "true"` — bypassando il
    nginx interno di Zammad (vedi sotto), Puma deve servire da solo gli asset
    precompilati sotto `/assets`, altrimenti cadono nella route catch-all Rails e
    tornano `index.html` (mismatch MIME).
  - `zammad-nginx`: aggiunto alias di rete `irccs-zammad-nginx` sulla rete condivisa
    `irccs` (mancava, serve al microservizio `irccs-zammad` per raggiungerlo).

### Perché si bypassa il nginx interno di Zammad

`zammad-railsserver` viene raggiunto **direttamente** da Apache (non passando dal
`zammad-nginx` incluso nell'immagine ufficiale): quel nginx interno fa sempre
`proxy_set_header X-Forwarded-Proto $scheme;`, cioè sovrascrive con lo scheme locale
(`http`, dato che il salto Apache→nginx-zammad è plain http), buttando via
l'`X-Forwarded-Proto: https` che Apache aveva già impostato. Risultato: Rack::Session
vede `request.scheme=http` mentre `Setting.http_type=https`, il check `secure_flag?`
fallisce e il cookie di sessione non viene mai confermato → "CSRF token verification
failed" persistente. Puma/Rails invece legge `X-Forwarded-Proto` senza riscriverlo,
quindi Apache lo chiama diretto.

### Certificato SSL: catena incompleta

Il certificato montato in `irccs-httpd-dashboard` (`cert-pasc-2026.crt`) conteneva
solo il certificato foglia, senza l'intermedio della CA (GlobalSign RSA OV SSL CA
2018). I browser lo tolleravano (recuperano l'intermedio da soli via AIA fetching),
ma client HTTP più rigorosi (es. Ruby/OpenSSL usato da Zammad per le chiamate OIDC
verso Keycloak) fallivano con `certificate verify failed (unable to get local issuer
certificate)`. Fix: creato `cert-pasc-2026-fullchain.crt` (leaf + intermedio
GlobalSign concatenati) e montato quello al posto del certificato originale nel
`docker-compose.yaml` (stesso path all'interno del container, nessuna modifica ai
file di config Apache necessaria).

## Microservizio `irccs-zammad` (integrazione ticket/sync Keycloak)

Il microservizio Quarkus `irccs-microservice-zammad` fa da proxy verso le API Zammad
per conto del frontend (creazione/ricerca ticket, sync organizzazioni/gruppi/utenti
da Keycloak) e sincronizza periodicamente Keycloak → Zammad (`SyncScheduler`).

- **Endpoint pubblico**: `https://pj.istitutotumori.na.it/zammad/*` (proxato da
  `irccs.conf` verso `irccs-zammad:8080/fhir/zammad/*`) — **non** l'interfaccia web
  Zammad, quella è sul sottodominio dedicato `pj-tk.istitutotumori.na.it` (vedi sopra).
- **Config chiave** (`.env` principale): `ZAMMAD_BASE_URL` deve includere il suffisso
  `/api/v1/` (es. `http://irccs-zammad-nginx:8080/api/v1/`) perché il client REST del
  microservizio fa `@Path("/organizations")`, `@Path("/groups")` ecc. assumendo che il
  base URL finisca già in `/api/v1/` — ometterlo causa 404 silenziosi su tutte le
  chiamate.
- **Bug noto corretto**: `ZammadTicketService.forwardPost`/`forwardPut` (nel repo
  `irccs-microservice-zammad`) inoltravano ciecamente tutti gli header della richiesta
  originale verso la Zammad API, incluso `Cookie` — un cookie di sessione Zammad
  residuo nel browser causava un falso positivo di "CSRF token verification failed"
  lato Zammad (la vedeva come richiesta sessione-autenticata invece che autenticata
  via token di servizio). Fix: `Cookie` aggiunto a `RESERVED_HEADERS` (mai inoltrato).

### Custom field `organization` su Group (Zammad)

Il frontend (`PatientJourneyCrudFormNew.tsx`/`PatientJourneyCrudForm.tsx`) cerca il
gruppo Zammad giusto per un ticket con la query
`name:annunci_* AND (organization:<orgId FHIR>)`, dove `organization` è un **custom
object attribute** su Group che va creato manualmente su ogni istanza Zammad nuova
(Admin → Object Manager → Group → nuovo attributo testo `organization`) e valorizzato
per ciascun gruppo `annunci_*` con l'id dell'Organization FHIR corrispondente. Se la
ricerca non trova nulla (attributo assente o non valorizzato), il frontend ricade su
un **fallback hardcoded `group_id: 49`** che quasi certamente non esiste sull'istanza
corrente e causa errori 500 lato Zammad (`undefined method 'id' for nil:NilClass`) —
va sempre verificato che ogni gruppo `annunci_*` abbia il campo `organization`
popolato correttamente prima di segnalare bug sul flusso ticket.

## Single Sign-On Zammad via Keycloak (OpenID Connect)

Login unico: gli utenti si autenticano su Zammad con lo stesso account Keycloak
usato per il resto della piattaforma (realm `pascale`), niente credenziali Zammad
separate.

### Keycloak — client dedicato

Nel realm `pascale`, client **pubblico** (no secret) chiamato `zammad`:
- Client authentication: **Off**
- Standard flow: **On** (unico flow abilitato)
- Root URL: `https://pj-tk.istitutotumori.na.it`
- Valid redirect URIs: `https://pj-tk.istitutotumori.na.it/auth/openid_connect/callback`
- Valid post logout redirect URIs: `https://pj-tk.istitutotumori.na.it/*`
- Web origins: `https://pj-tk.istitutotumori.na.it`
- Advanced → Proof Key for Code Exchange (PKCE): **S256**

### Zammad — Admin → Security → Third-party Applications → OpenID Connect

- Enable: ON
- Name: `Keycloak`
- Identifier: `zammad` (client id sopra)
- Issuer: `https://pj.istitutotumori.na.it/backoffice/realms/pascale`
- PKCE: **ON** (deve combaciare col client Keycloak, altrimenti errore
  `invalid_request` / "Missing parameter: code_challenge_method")
- **Automatic account link on initial logon: ON** — indispensabile, perché gli utenti
  esistono già su Zammad (creati dalla sync `irccs-zammad`); senza questa opzione il
  login OIDC prova a creare un nuovo utente con la stessa email e fallisce con
  "Validation failed: Email address '...' is already used for another user."

### Bug corretto in Keycloak: `KC_PROXY_HEADERS`

`docker-compose.yaml` aveva `KC_PROXY_HEADERS: forwarded`, che dice a Keycloak di
fidarsi solo dell'header standard `Forwarded:`. Apache però manda le legacy
`X-Forwarded-Proto`/`X-Forwarded-Port` (vedi `irccs.conf`), non `Forwarded:`. Con
`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`, questo mismatch faceva sì che le chiamate
**backchannel** (token exchange, usate dal login OIDC di Zammad) venissero costruite
da Keycloak con scheme `http` e porta default `80` invece di `https`/443, causando
`Connection refused` lato Zammad durante lo scambio del code OIDC. Il login
interattivo via browser (dashboard React, PWA) non era mai stato impattato perché usa
l'hostname statico (`KC_HOSTNAME_URL`), non la risoluzione dinamica backchannel — per
questo il bug è emerso solo ora, con il primo consumer OIDC server-to-server
(Zammad). Fix: `KC_PROXY_HEADERS: xforwarded`.

### Riepilogo errori affrontati (per troubleshooting futuro)

| Errore | Causa | Fix |
|---|---|---|
| `Missing parameter: code_challenge_method` | PKCE attivo lato Keycloak, disattivo lato Zammad | Attivare PKCE anche su Zammad |
| `certificate verify failed (unable to get local issuer certificate)` | Catena SSL incompleta (manca l'intermedio GlobalSign) | `cert-pasc-2026-fullchain.crt` (leaf + intermedio) |
| `Failed to open TCP connection ... port 80` | `KC_PROXY_HEADERS` non combaciava con gli header mandati da Apache | `KC_PROXY_HEADERS: xforwarded` |
| `csrf_detected` | Cookie di sessione Zammad residuo/inconsistente da tentativi precedenti | Riprovare con sessione/cookie puliti |
| `Validation failed: Email address ... already used` | Utente già esistente su Zammad, nessun collegamento automatico OIDC | `Automatic account link on initial logon: ON` |
