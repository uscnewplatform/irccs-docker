# Guida installazione in produzione — Gate ticket CRF + pannello ticket Zammad (versione "tutto a Zammad")

Data: 2026-10-22. Branch unico per repo: `feature/PASTRL-720/ticket-crf-zammad-live` (common, zammad, studio-clinico, patient-interview, dashboard → remote `origin`; irccs-docker → remote `infocube-it`). La versione precedente, con copia dei ticket in HAPI e webhook, resta nel branch `feature/PASTRL-720/ticket-crf-gate`.

Le modifiche sono **spente di default** (`crf.confirm.require-closed-tickets=false`): si installa tutto, si verifica, poi si attiva il flag. Nessun passo rompe il comportamento attuale finché il flag è off, e con il flag spento non parte nessuna chiamata a Zammad per il blocco.

Principio: **Zammad è l'unica fonte**. Il blocco della conferma chiede lo stato dei ticket a Zammad al momento (via ms zammad). Niente webhook, niente riconciliazione, niente copia in HAPI. Con Zammad non raggiungibile la conferma è **impossibile** (503, «Sistema di ticket in manutenzione. Riprovare o contattare l'assistenza»), senza deroga.

## 0. Prerequisiti e decisioni prima del go-live

| # | Cosa | Perché |
|---|---|---|
| 1 | Token Zammad in `application.properties` è in chiaro nel repo | **Passo obbligatorio prima del go-live**, vedi 0b |
| 2 | Letture **read-only** su Zammad prod (con OK esplicito): `GET /api/v1/ticket_states` (stato 7 custom: che `state_type` ha? uno sconosciuto BLOCCA), `POST /tickets/search` con `condition` funziona, tempi di risposta su dati reali | La ricerca a condizioni non richiede Elasticsearch; il timeout di 3 s va confermato |
| 3 | Chi riceve `internal:close:ticket` e `internal:override:ticket-gate` | Decisione organizzativa (override = deroga auditata) |
| 4 | Deroga con ticket non verificabili: `crf.confirm.override-when-unverifiable` | Default `false` (nessuna deroga con sistema in manutenzione); `true` solo se serve |
| 5 | Flag globale (non per studio) | Se serve per-studio, va sviluppato prima |
| 6 | DPO: PHI nei ticket, retention | Il blocco espone solo id e stato dei ticket, non il testo |
| 7 | `zammad.visibility.patient-url` | Default `http://irccs-anagrafica-pazienti:8080/fhir/Patient`: verificare hostname in prod |
| 8 | `crf.confirm.ticket-service-url` | Default `http://irccs-zammad:8080` (container del ms zammad): verificare il nome in prod |
| 9 | `jwt.secret` presente nel ms zammad | Serve a `CallerScope` (capability dai gruppi) |

## 0b. Rotazione del token Zammad (obbligatoria prima del go-live)

1. In Zammad crea un token nuovo per l'utente di servizio (permessi: lettura e ricerca ticket, scrittura per il pannello).
2. Mettilo SOLO nel `.env` del server (`ZAMMAD_TOKEN_SERVICE`), mai nel repository.
3. Riavvia il microservizio Zammad e verifica una lettura (pannello ticket o `align_ticket_crf.sh --only 6`).
4. **Revoca il token vecchio** in Zammad: quello nel repository va considerato compromesso (resta nella storia di git).
5. Verifica: con il token vecchio una chiamata a `GET /api/v1/users/me` risponde 401.

Il token deve poter cercare i ticket di *tutti* i gruppi Zammad usati dalla piattaforma, anche quelli ristretti: se non vede un gruppo, i ticket di quel gruppo non compaiono e la CRF risulta libera senza alcun errore (vedi caso di test G9).

## 1. Ordine di rilascio (la CI dei ms è rossa finché common non è rilasciato)

1. **irccs-common** — PR → develop, merge, release (job `irccs-release`, non tag a mano). Annotare la nuova versione (la `27.0.0` è già rilasciata: serve una versione nuova, schema da decidere).
2. Nei ms (**zammad, studio-clinico, patient-interview**): aggiornare `i3.common.version` alla nuova versione, push, PR → develop → master.
3. **irccs-react-dashboard** e **irccs-docker**: PR → develop → master.
4. Tag `yyyy-mm` e deploy: job Jenkins `Deploy-Preprod-Jenkinsfile` (poi prod). Mai tag manuali.

Immagini da ricostruire/ridistribuire: `irccs-microservice-zammad`, `studio-clinico`, `patient-interview`, **tutti i ms che usano common** (stessa versione), `irccs-react-dashboard`.

## 1b. Script di allineamento (consigliato per staging/preprod/prod)

Dopo il deploy delle immagini, i passi 2-5 di questa guida si eseguono con un solo script guidato, ripetibile e con conferma prima di ogni scrittura:

```bash
cd irccs-docker
ZAMMAD_URL=https://<zammad> ZAMMAD_TOKEN=... \
KC_URL=https://<host>/backoffice ADMIN_USER=... ADMIN_PASS=... \
./setup/install/align_ticket_crf.sh            # --from N / --only N / --yes
```

Passi: preliminari, ruoli Keycloak, risorse Keycloak (incluse `ByPatient`), attributi Zammad, configurazione effettiva del container, prova della ricerca a condizioni su Zammad (sola lettura), promemoria manuali. Segreti solo da ambiente.

## 2. Keycloak (realm di prod)

Dalla cartella `irccs-docker/keycloak-config/` (backup realm prima!):

```bash
python3 add-ticket-gate-roles.py   # crea ruoli internal:confirm:crf, internal:close:ticket, internal:override:ticket-gate
python3 add-zammad-authz.py        # risorse authz: CrfSummary, ByCrf, ByPatient, Articles, StateChange (close, reopen, validate-closure), OpenForGate
# se il realm ha gia' le risorse della versione precedente, rilanciare lo script: aggiunge validate-closure
```

Gli script richiedono credenziali admin Keycloak (variabili d'ambiente, vedere l'header dello script). `GET /fhir/zammad/tickets/open-for-gate` NON ha una risorsa propria: lo chiamano solo i microservizi con il service account (ruolo admin, coperto da "Admin Resource" `/fhir/*`); gli utenti normali ricevono 403. Verificarlo dopo il deploy.

## 3. Zammad (prod)

```bash
cd irccs-docker/setup/install
bash install_zammad_attributes.sh   # attributi crfscope (CRF|STUDY), qrid, crfclosure; nasconde in modifica i campi chiave
```

- `crfclosure` e' il segno di "chiuso dalla piattaforma": senza, ogni ticket chiuso risulterebbe chiuso senza convalida e bloccherebbe. I campi `patient`, `careplan`, `crf`, `crfscope`, `qrid` e `crfclosure` diventano non modificabili nell'interfaccia di Zammad (lo script lo fa anche dove esistevano gia').
- Dopo l'aggiornamento della piattaforma, i ticket gia' chiusi PRIMA di questa versione non hanno il segno e bloccano finche' non si convalidano dal pannello (o si scrive il segno con uno script di bonifica concordato col cliente).
- Attributi: nomi `crfscope`/`qrid` (i nomi `scope` e `*_id` sono riservati in Zammad). I ticket creati dalla piattaforma portano anche `patient`, `careplan`, `crf`: sono i campi su cui cerca il blocco.
- **Niente webhook** da installare.

## 4. Config microservizio zammad (env / application.properties)

```properties
zammad.base-url=<URL INTERNO di Zammad>
zammad.token=<token di servizio>            # env ZAMMAD_TOKEN_SERVICE in staging/prod
zammad.ticket-lookup.timeout=3s             # env ZAMMAD_TICKET_LOOKUP_TIMEOUT
zammad.visibility.enforce=true
zammad.visibility.patient-url=http://irccs-anagrafica-pazienti:8080/fhir/Patient
```

Le variabili arrivano dal `.env` del server (tutti i servizi hanno `env_file: .env`; esempio in `.env_example`). Il file `microservice-config-zammad/application.properties` montato su `/deployments/config` ha priorità su quello impacchettato: **non** serve più nessuna voce per il webhook (la voce `paths.7` della versione precedente va tolta, se già applicata).

## 5. Config gate (studio-clinico, patient-interview e ms con Flow)

```properties
crf.confirm.require-closed-tickets=false          # tenere false al deploy; true all'attivazione
crf.confirm.override-when-unverifiable=false      # true = la deroga vale anche con sistema di ticket in manutenzione
crf.confirm.ticket-service-url=http://irccs-zammad:8080
crf.confirm.ticket-lookup-timeout=5s              # attesa verso il ms Zammad: MAGGIORE di zammad.ticket-lookup.timeout
```

## 6. Capability ai gruppi (UI)

Dashboard → **Gruppi utenti** → sezione CRF: assegnare ai gruppi scelti
- `internal:confirm:crf` (conferma CRF),
- `internal:close:ticket` (chiude/riapre ticket),
- `internal:override:ticket-gate` (deroga con motivazione, audit sincrono).

Le capability vengono dai **gruppi** (membership live + `X-Context-Token`), non dall'utente. Gli utenti devono rifare **login**.

## 7. Verifiche post-deploy (flag ancora off)

1. Creare un ticket di test legato a una CRF di test (non su pazienti reali): compare nel pannello della CRF e nel riquadro «Ticket aperti» della home paziente; chiuso, sparisce.
2. Pannello ticket nella CRF: elenco, risposta, chiudi/riapri (solo gruppo con capability), utente fuori contesto/organizzazione → 403/vuoto.
3. `GET /fhir/zammad/tickets/open-for-gate?patient=<id>` con il service account → 200 `{"tickets":[...]}`; con un utente normale → 403.
4. Dashboard: dopo ogni `npm run build` locale ricreare `httpd` (config.js montato); in prod il config arriva dal deploy.

## 8. Attivazione

0. **Controllo di connessione prima di accendere il flag.** Da dentro il container di studio-clinico (stessa rete e stesso nome host che userà il blocco) verifica che il ms Zammad sia raggiungibile: `curl -s -o /dev/null -w '%{http_code}' http://irccs-zammad:8080/q/health` deve rispondere 200 (o usa il nome in `crf.confirm.ticket-service-url`). Un nome sbagliato dà 503 su tutte le conferme, indistinguibile da "Zammad giù".

1. Impostare `crf.confirm.require-closed-tickets=true` (env) e riavviare studio-clinico/patient-interview.
2. Prova: CRF con ticket aperto → conferma **409 `CRF_OPEN_TICKETS`**; chiuso → OK; Zammad fermo → **503 `CRF_TICKET_STATE_UNVERIFIABLE`** e messaggio di manutenzione, **anche con deroga**; deroga con motivo di almeno 10 caratteri (header `X-Ticket-Gate-Override-Reason`) + capability su ticket aperto → OK + BusinessEvent `ticket-gate-override`; audit giù → 503 (fail-closed).
3. Monitorare 409/503 nei log (Loki/Grafana). Un aumento di 503 = Zammad lento o giù.
4. **Se compare il 503 subito dopo l'accensione**: quasi sempre è l'indirizzo (`crf.confirm.ticket-service-url`), il token di servizio, o un timeout troppo corto. Controlla nell'ordine: log di studio-clinico (`CrfTicketGate: stato dei ticket non verificabile`), `open-for-gate` raggiungibile dal container, token Zammad valido. Per tornare operativi subito: flag a `false` e riavvio.

## 9. Rollback

- Disattivare: `crf.confirm.require-closed-tickets=false` (effetto immediato al riavvio, nessun dato da toccare).
- Tornare alla versione con copia in HAPI e webhook: ridistribuire il branch `feature/PASTRL-720/ticket-crf-gate` (richiede la sincronizzazione e il webhook).
- Ruoli/risorse Keycloak e attributi Zammad possono restare.
- Se in un ambiente era già stata applicata la versione precedente: toglie a mano dal file montato `microservice-config-zammad/application.properties` la voce `quarkus.keycloak.policy-enforcer.paths.7.*` (webhook) e le variabili `ZAMMAD_TICKET_REF_*`, `ZAMMAD_WEBHOOK_SECRET`, `ZAMMAD_INSTANCE_ID` dal `.env`.

## 10. Limiti noti (non bloccanti)

Allegati non scaricabili; niente notifiche/tempo reale; `myTicket`, PUT ticket, annunci e ricerca gruppi ancora su permessi Zammad; flag globale; PATCH QR e import non coperti dal gate; `/certify` senza override; paziente (link) blocca solo se sa con certezza di ticket aperti; ticket creati direttamente in Zammad senza `patient`/`careplan`/`crf` non sono visti; ogni conferma con il blocco acceso fa una chiamata a Zammad (se è giù nessuno conferma); percorso paziente E2E, patient-interview non verificati.

## 11. Port su `git pascale/irccs-docker` (prod)

Le modifiche a `irccs-docker` (script install, keycloak-config, `.env_example`, `microservice-config-zammad/application.properties`) vanno portate anche lì con edit mirati, senza toccare le config di produzione e il `.env`.
