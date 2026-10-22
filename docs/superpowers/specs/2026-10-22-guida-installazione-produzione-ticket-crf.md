# Guida installazione in produzione — Gate ticket CRF + pannello ticket Zammad

Data: 2026-10-22. Branch unico per repo: `feature/PASTRL-720/ticket-crf-gate` (common, zammad, studio-clinico, patient-interview, dashboard → remote `origin`; irccs-docker → remote `infocube-it`).

Le modifiche sono **spente di default** (`crf.confirm.require-closed-tickets=false`): si installa tutto, si verifica, poi si attiva il flag. Nessun passo rompe il comportamento attuale finché il flag è off.

## 0. Prerequisiti e decisioni prima del go-live

| # | Cosa | Perché |
|---|---|---|
| 1 | Token Zammad in `application.properties` è in chiaro nel repo | Ruotarlo e passarlo come secret/env prima di prod |
| 2 | Letture **read-only** su Zammad prod (con OK esplicito): `GET /api/v1/ticket_states` (stato 7 custom, id stato "closed" = 4?), Elasticsearch attivo?, utenti con `keycloak_ref` popolato | Il mapping usa `state_type`; `zammad.ticket.closed-state-id` default 4 va verificato |
| 3 | Chi riceve `internal:close:ticket` e `internal:override:ticket-gate` | Decisione organizzativa (override = deroga auditata) |
| 4 | Flag globale (non per studio) | Se serve per-studio, va sviluppato prima |
| 5 | DPO: PHI nei ticket, retention | Il Task `ticket-ref` in HAPI contiene solo stato, non testo |
| 6 | `zammad.visibility.patient-url` | Default `http://irccs-anagrafica-pazienti:8080/fhir/Patient`: verificare hostname in prod |
| 7 | `jwt.secret` presente nel ms zammad | Serve a `CallerScope` (capability dai gruppi) |

## 1. Ordine di rilascio (la CI dei ms è rossa finché common non è rilasciato)

1. **irccs-common** — PR `feature/PASTRL-720/ticket-crf-gate` → develop, merge, release (job `irccs-release`, non tag a mano). Annotare la nuova versione.
2. Nei ms (**zammad, studio-clinico, patient-interview**): aggiornare `i3.common.version` alla nuova versione, push, PR → develop → master.
3. **irccs-react-dashboard** e **irccs-docker**: PR → develop → master.
4. Tag `yyyy-mm` e deploy: job Jenkins `Deploy-Preprod-Jenkinsfile` (poi prod). Mai tag manuali.

Immagini da ricostruire/ridistribuire: `irccs-microservice-zammad`, `studio-clinico`, `patient-interview`, **tutti i ms che usano common** (stessa versione), `irccs-react-dashboard`, `httpd` (se cambia config), Keycloak (solo config).

## 1b. Script di allineamento (consigliato per staging/preprod/prod)

Dopo il deploy delle immagini, i passi 2-8 di questa guida si eseguono con un solo script guidato, ripetibile e con conferma prima di ogni scrittura:

```bash
cd irccs-docker
ZAMMAD_URL=https://<zammad> ZAMMAD_TOKEN=... WEBHOOK_SECRET=... \
WEBHOOK_URL=http://<ms-zammad>:8080/fhir/zammad/webhook \
KC_URL=https://<host>/backoffice ADMIN_USER=... ADMIN_PASS=... \
HAPI_URL=http://localhost:8080/fhir \
./setup/install/align_ticket_crf.sh            # --from N / --only N / --yes
```

Include anche la risorsa Keycloak `ByPatient` (elenco ticket aperti nella home paziente). Segreti solo da ambiente. Il passo 6 legge la configurazione reale del container; il passo 7 controlla il battito su HAPI.

## 2. Keycloak (realm di prod)

Dalla cartella `irccs-docker/keycloak-config/` (backup realm prima!):

```bash
python3 add-ticket-gate-roles.py   # crea ruoli internal:confirm:crf, internal:close:ticket, internal:override:ticket-gate
python3 add-zammad-authz.py        # risorse authz: CrfSummary, TicketRefReport, ByCrf, Articles, StateChange
```

Gli script richiedono credenziali admin Keycloak (variabili d'ambiente, vedere l'header dello script). Verificare nella console che i ruoli/risorse esistano e che il client del ms zammad abbia le policy.

## 3. Zammad (prod)

```bash
cd irccs-docker/setup/install
bash install_zammad_attributes.sh   # attributi oggetto crfscope (CRF|STUDY) e qrid
bash install_zammad_webhook.sh      # webhook verso il ms zammad, HMAC-SHA1
```

- Il segreto webhook (`zammad.webhook.secret`) deve coincidere tra webhook Zammad e config del ms.
- Il webhook è **solo notifica**: il ms rilegge il ticket. Il path webhook è `DISABLED` nel policy enforcer (autenticato da HMAC).
- Attributi: nomi `crfscope`/`qrid` (i nomi `scope` e `*_id` sono riservati in Zammad).

## 4. Config microservizio zammad (env / application.properties)

```properties
zammad.ticket-ref.enabled=true
zammad.instance-id=<id-istanza>          # entra nell'identifier urn:zammad:<instance>|<ticketId>
zammad.webhook.secret=<secret>
zammad.visibility.enforce=true
zammad.visibility.patient-url=http://irccs-anagrafica-pazienti:8080/fhir/Patient
zammad.ticket.closed-state-id=4          # verificare in prod
```

Riconciliazione periodica ogni 5 min (scansione completa `GET /tickets`, rileva cancellazioni, scrive il Task `ticket-sync-heartbeat`).

## 4b. Attenzione: file di configurazione montato (staging/prod)

Su staging e prod il microservizio Zammad monta `irccs-docker/microservice-config-zammad/application.properties` su `/deployments/config`: quel file *ha priorita'* su quello impacchettato e definisce gia' gli indici `quarkus.keycloak.policy-enforcer.paths.0..6`. Il webhook (`/fhir/zammad/webhook`) deve quindi essere dichiarato anche li' (indice 7, `enforcement-mode=DISABLED`), altrimenti Keycloak lo respinge e resta solo la riconciliazione ogni 5 minuti. Nel repo `irccs-docker` e' gia' fatto; **va replicato nel repo di produzione** (`git pascale/irccs-docker`).

Le variabili arrivano dal `.env` del server (tutti i servizi hanno `env_file: .env`): `ZAMMAD_TICKET_REF_ENABLED`, `ZAMMAD_INSTANCE_ID`, `ZAMMAD_WEBHOOK_SECRET`, `CRF_CONFIRM_REQUIRE_CLOSED_TICKETS`, `CRF_CONFIRM_TICKET_SYNC_MAX_AGE` (esempio in `.env_example`). Il token del servizio e' `ZAMMAD_TOKEN_SERVICE`, l'URL `ZAMMAD_BASE_URL` (interno).

## 5. Config gate (studio-clinico, patient-interview e ms con Flow)

```properties
crf.confirm.require-closed-tickets=false     # tenere false al deploy; true all'attivazione
crf.confirm.ticket-sync-max-age=10m          # heartbeat più vecchio → 503 (stato non verificabile)
```

## 6. HAPI FHIR

Nessuna migrazione: usa `Task` con code `ticket-ref` e `ticket-sync-heartbeat`. Verificare che il ruolo/utente tecnico del ms zammad possa creare/aggiornare `Task` e che il Patient referenziato esista (HAPI rifiuta Task con Patient inesistente: il ms riprova senza `for`).

## 7. Capability ai gruppi (UI)

Dashboard → **Gruppi utenti** → sezione CRF: assegnare ai gruppi scelti
- `internal:confirm:crf` (conferma CRF),
- `internal:close:ticket` (chiude/riapre ticket),
- `internal:override:ticket-gate` (deroga con motivazione, audit sincrono).

Le capability vengono dai **gruppi** (membership live + `X-Context-Token`), non dall'utente. Gli utenti devono rifare **login**.

## 8. Verifiche post-deploy (flag ancora off)

1. `GET /tickets/ticket-ref-report` (admin): Task sincronizzati, nessun `sync-error`, heartbeat recente.
2. Creare un ticket di test legato a una CRF di test (non su pazienti reali) e verificare: Task `ticket-ref` in HAPI, stato corretto dopo chiusura (webhook entro ~10 s).
3. Pannello ticket nella CRF: elenco, risposta, chiudi/riapri (solo gruppo con capability), utente fuori contesto/organizzazione → 403/vuoto.
4. Dashboard: dopo ogni `npm run build` locale ricreare `httpd` (config.js montato); in prod il config arriva dal deploy.

## 9. Attivazione

1. Impostare `crf.confirm.require-closed-tickets=true` (env) e riavviare studio-clinico/patient-interview.
2. Prova: CRF con ticket aperto → conferma **409 `CRF_OPEN_TICKETS`**; chiuso → OK; sync ferma > 10 min → **503 `CRF_TICKET_STATE_UNVERIFIABLE`**; override con motivo di almeno 10 caratteri (header `X-Ticket-Gate-Override-Reason`) + capability → OK + BusinessEvent `ticket-gate-override`; audit giù → 503 (fail-closed).
3. Monitorare 409/503 e il heartbeat nei log (Loki/Grafana).

## 10. Rollback

- Disattivare: `crf.confirm.require-closed-tickets=false` (effetto immediato al riavvio, nessun dato da toccare).
- Disattivare sync: `zammad.ticket-ref.enabled=false`. I Task `ticket-ref` restano in HAPI, innocui.
- Ruoli/risorse Keycloak e attributi Zammad possono restare.

## 11. Limiti noti (non bloccanti)

Allegati non scaricabili; niente notifiche/tempo reale; `myTicket`, PUT ticket, annunci e ricerca gruppi ancora su permessi Zammad; flag globale; PATCH QR e import non coperti dal gate; `/certify` senza override; paziente (link) blocca solo ticket noti; percorso paziente E2E, patient-interview e Zammad con Elasticsearch non verificati.

## 12. Port su `git pascale/irccs-docker` (prod)

Le modifiche a `irccs-docker` (script install, keycloak-config) vanno portate anche lì con edit mirati, senza toccare le config di produzione.
