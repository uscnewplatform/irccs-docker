# Ticket CRF — stato di staging e porting in produzione

Data: 2026-10-23. Ambiente: staging `10.99.88.246` (`i3-irccs-staging`). Versione "tutto a Zammad" (Zammad e' l'unica fonte,
nessuna copia in HAPI). Questo documento riassume **cosa e' stato fatto su staging, cosa e' emerso e cosa va portato in produzione**.
Le istruzioni passo-passo di installazione restano in `2026-10-22-guida-installazione-produzione-ticket-crf.md`.

Nessun segreto in questo file (token, password): vanno presi dal gestore delle credenziali.

## 1. Codice e branch

Branch unico per repo: `feature/PASTRL-720/ticket-crf-zammad-live` (il vecchio `feature/PASTRL-720/ticket-crf-gate`, con copia dei ticket in HAPI,
resta intatto come alternativa). Tutti pushati. Versioni alzate: `irccs-common` e tutti i microservizi **27.1.0**, dashboard **3.2.0**.

| Repo | Contenuto |
|---|---|
| `irccs-common` | gate (`CrfTicketGate`), `evaluateAll`, chiave dalla QR salvata, ogni creazione `completed` e' una conferma |
| `irccs-microservice-zammad` | `open-for-gate`, `mine`, `patients-with-open`, `validate-closure`, copertura gruppi, reverter, sync Keycloak->Zammad corretto |
| `irccs-microservice-studio-clinico` | `/certify` blocca (senza deroga) |
| `irccs-react-dashboard` | riquadro ticket in home paziente, icona in tabella, pagina "I miei ticket", pannello ticket |
| `irccs-docker` | script di allineamento, attributi Zammad, authz Keycloak, documenti |
| altri 8 microservizi | solo bump di versione a 27.1.0 (la CI li costruisce dopo il rilascio di common) |

**Ordine di rilascio:** PR di `irccs-common` -> merge -> rilascio 27.1.0 -> PR dei microservizi (la loro CI e' rossa finche' common 27.1.0 non esiste) -> dashboard e `irccs-docker`.

## 2. Cosa e' stato fatto su staging

Le immagini di staging sono state costruite in locale e caricate a mano (la CI non le ha ancora prodotte): **non sono immagini Jenkins**.
Per le 9 immagini cambiate solo nei jar di common si e' usato un "delta" sopra la 27.0.0; in produzione si usano le immagini della CI.

1. Keycloak: ruoli `internal:close:ticket`, `internal:override:ticket-gate` e risorse/permessi del ms Zammad (`add-ticket-gate-roles.py`, `add-zammad-authz.py`).
2. Zammad: attributi Ticket (`patient`, `careplan`, `crf`, `crfscope`, `qrid`, `crfclosure`, ...) e `keycloak_ref` su User, Organization, Group (`install_zammad_attributes.sh`).
3. `.env`: versioni 27.1.0 / 3.2.0, `ZAMMAD_BASE_URL` interno, `ZAMMAD_TOKEN_SERVICE` nuovo, `CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=false`.
4. Regenerato `httpd-config/versions.json` e riavviato il container httpd (vedi 4.5).
5. Prove (9/9) con flag acceso e dati di test poi cancellati: ticket aperto -> 409; altra compilazione della stessa CRF -> 200; chiuso a mano in Zammad -> ancora 409;
   chiusura convalidata -> 200; deroga motivata -> 200; Zammad fermo -> 503 anche con deroga. Flag riportato a `false`.

## 3. Checklist per la produzione (in ordine)

1. **Prerequisiti:** common 27.1.0 rilasciato; immagini dei microservizi e della dashboard prodotte dalla CI. La dashboard deve includere l'SSO (`feature/zammad-sso-auth-sso`), come quella di staging.
2. **Backup** di `.env`, di `httpd-config/versions.json` e dei volumi (soprattutto `postgres_data_hapi`, `postgres_data_keycloak` e i database di Zammad).
3. **Salute di Elasticsearch di Zammad** (vedi 4.1): indici verdi o gialli, non rossi; spazio disco sotto il 85%.
4. **Utente di servizio Zammad dedicato** con token (permessi `admin`, `ticket.agent`). NON usare il proprio utente personale come proprietario del token (vedi 4.6).
5. Keycloak: `add-ticket-gate-roles.py` e `add-zammad-authz.py` (prima `--dry-run`).
6. Zammad: `install_zammad_attributes.sh` (crea anche `keycloak_ref`); poi attendere il riavvio automatico di Zammad.
7. `.env`: versioni, `ZAMMAD_BASE_URL=http://irccs-zammad-nginx:8080/api/v1/` (alias senza underscore, vedi 4.3), `ZAMMAD_TOKEN_SERVICE`, flag `false`.
8. Deploy delle immagini; rigenerare `versions.json` e **riavviare httpd** (vedi 4.5) — il job Jenkins di deploy lo fa da solo.
9. Verificare che il sync Keycloak->Zammad completi senza errori e che gli utenti abbiano `keycloak_ref` valorizzato (log «Keycloak to Zammad sync completed»).
10. Verificare la copertura: nei log «N gruppi Zammad aperti in full al token di servizio», e nessun avviso «non aperti».
11. Capability ai gruppi (`internal:confirm:crf`, `internal:close:ticket`, `internal:override:ticket-gate`) e nuovo login degli utenti.
12. Prove con il flag spento (pannello ticket, home paziente, "I miei ticket"), poi accensione `CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=true` su studio-clinico e prove 409 / 200 / deroga / 503.
12bis. **Segreto HMAC del segno di chiusura:** `ZAMMAD_CLOSURE_HMAC_SECRET` nel `.env` (lungo e casuale, `openssl rand -base64 48`) e la riga `zammad.closure.hmac-secret=${ZAMMAD_CLOSURE_HMAC_SECRET:}` nella config del ms zammad. Senza, il ms logga un WARN e i segni non sono firmati. Il segreto si genera sul server e non si salva nel repo.
12quater. **Admin del centro:** assegnare `internal:manage:center-tickets` ai gruppi Admins (vedi sezione 8).
12ter. **Farmacovigilanza** (e ogni gruppo che deve chiudere ticket) ha bisogno del ruolo `internal:close:ticket` sul gruppo Keycloak: su staging assegnato il 24/10 a Farmacovigilanza IRCCS. Dal 25/10 Farmacovigilanza IRCCS ha anche `internal:confirm:crf`: il pulsante «Conferma CRF» lo vedono solo i gruppi con quel ruolo (Admins e Farmacovigilanza).
13. **Ticket gia' chiusi prima della versione:** non hanno il marcatore `crfclosure` e continuano a bloccare finche' non convalidati (script di bonifica da decidere con il cliente).

## 4. Cose scoperte su staging (da non ripetere in produzione)

1. **Elasticsearch di Zammad e il disco.** Con il disco oltre il 90% Elasticsearch non assegna gli shard: indici `red`, la ricerca testuale di Zammad restituisce sempre vuoto
   e il ms Zammad non riconosce nessun utente (403 «Utente non presente su Zammad»). Su staging si sono alzate le soglie (`low 94%`, `high 96%`, `flood_stage 98%`) e ricostruito l'indice
   (`bundle exec rake zammad:searchindex:rebuild`). **Non e' una soluzione da copiare:** in produzione tenere il disco sotto l'85% e monitorare lo stato degli indici (`_cluster/health`).
2. **Il sync Keycloak->Zammad aveva due difetti**, corretti nel ms 27.1.0: ricerche per nome senza virgolette («ASL Napoli 1 Centro» si spezzava) e primo risultato preso senza verifica del valore;
   con l'indice vuoto le organizzazioni venivano ricreate (HTTP 422) e nessun utente si collegava. Ora query a frase esatta, filtro sul valore esatto e ripiego sull'elenco completo.
3. **Nome host con underscore.** `zammad-ticketing_zammad-nginx_1` non e' valido per Java (`URI.getHost()` e' null): connessione rifiutata. Usare l'alias `irccs-zammad-nginx` (gia' definito nella rete `irccs`).
4. **Attributo `keycloak_ref` mancante.** Senza `keycloak_ref` su User/Organization/Group il sync non collega nulla e ogni chiamata del pannello ticket dà 403. Ora lo crea `install_zammad_attributes.sh`.
5. **`versions.json` e il montaggio a file.** La pagina «Versioni» legge `/versions.json`, generato da `generate-versions-env.sh` dal deploy Jenkins. Lo script lo sostituisce con `mv` (nuovo inode): il container continua a vedere il vecchio
   finche' non viene **riavviato**. Un deploy manuale va seguito da: generare il file, poi `docker restart irccs-httpd-dashboard`.
6. **Il proprietario del token e' un utente sincronizzato.** Il sync riscrive i gruppi di ogni utente. Il ms riapre ora a tutti i gruppi attivi sia all'inizio sia **alla fine** di ogni giro, ma e' piu' pulito
   un utente di servizio dedicato che non sia un utente reale (e che non venga disattivato dal «cleanup degli utenti orfani»).
7. **Gruppi nuovi.** Il sync crea gruppi per ogni centro/ruolo; il token deve coprirli tutti, altrimenti il blocco CRF risponde 503. E' automatico dalla 27.1.0.
8. **Capacita' del server di staging:** 8 GB di RAM e 24 GB di disco per ~31 container; swap quasi pieno, load average fino a 227 al riavvio di molti servizi. Riavviare pochi container per volta.
9. **Container Zammad che ripartono.** `websocket`, `rails` e `scheduler` hanno decine di riavvii (exit code 0, policy `always`): causa non indagata.
10. **Il corpo degli errori del gate e' un `OperationOutcome` FHIR:** il codice sta in `issue[0].details.coding[0].code` (`CRF_OPEN_TICKETS`, `CRF_TICKET_STATE_UNVERIFIABLE`).

11. **`customer_id` come stringa.** La dashboard inviava l'id dell'utente Zammad come testo (`"3"`) e il controllo piu' severo del ms (solo numero) rifiutava ogni creazione con 403
    «puo' essere aperto solo a nome del chiamante», per qualsiasi utente. Dalla 27.1.0 (commit 31cd35a) il ms accetta anche la stringa di sole cifre, purche' sia il chiamante; la dashboard
    (3dd1b938) invia ora un numero. Il log del rifiuto riporta il motivo. Lezione: i test locali mandavano un numero e non vedevano il problema; provare sempre la creazione dal dialogo reale.
12. **Disco di staging ampliato** il 23/10 (da 24 a 77 GB): le soglie alzate di Elasticsearch (4.1) non servono piu' e possono tornare ai valori standard.
13. **Il ciclo (`CarePlan`) di una CRF e' un modello senza paziente.** Il `careplan` del ticket e' il CarePlan del percorso dello studio, condiviso da tutti i pazienti e senza `subject`
    (su staging 200/200 campionati cosi'). La verifica dei riferimenti pretendeva il paziente e dava 422 «Riferimenti non coerenti con il paziente» su ogni ticket. Dalla 27.1.0 (commit 2437e54):
    il ciclo senza paziente vale, quello con un paziente deve essere quello indicato; la compilazione (`qrid`) resta vincolata al paziente, alla CRF e al ciclo. Il controllo ora ha test diretti.
14. **Gruppi del nuovo ticket = quelli del centro del paziente.** Nuovo `GET /fhir/zammad/tickets/groups-for-patient?patient=` (ms 27.1.0, commit 514e1e5): paziente -> `managingOrganization` -> `Organization.identifier`
    (UUID del gruppo radice Keycloak) -> gruppi Zammad con `organization` uguale a quell'UUID, esclusi gli `annunci_*`, intersecati con i gruppi in cui il chiamante puo' creare. La creazione di un ticket di CRF
    rifiuta un gruppo di un altro centro (403). Centro non riconoscibile = nessun gruppo (mai tutti). **Serve la risorsa Keycloak `GroupsForPatient`**: la crea `add-zammad-authz.py` (commit 1073a51); senza, la dashboard non riceve i gruppi.
    La dashboard mostra UN solo gruppo da scegliere (prima selezione multipla = un ticket per gruppo, quindi piu' ticket da chiudere e piu' blocchi sulla stessa CRF).
15. **CRF compilate dal paziente = niente ticket.** Il questionario con l'estensione `http://irccs.pascale.napoli.it/fhir/StructureDefinition/render-as-patient-questionnaire` (valueBoolean true, diario compreso) non ha ticket:
    il ms risponde «nessun ticket» a blocco e riepilogo senza chiamare Zammad (quindi nessun 503 se Zammad e' fermo) e rifiuta la creazione (422); la dashboard non mostra «Ticket» ne' «Conferma CRF».
    Questionario non leggibile = trattato come CRF normale (cache 5 minuti, gli errori non si memorizzano).
16. **Dove sta la visibilita'.** Nella piattaforma un ticket di CRF e' visibile a chi vede il paziente nel contesto attivo; il gruppo Zammad decide chi lo prende in carico e chi riceve le notifiche in Zammad. Non sono la stessa cosa.
17. **News di studio nel popup della home.** Il click su «News studio: N» nella card dello studio non porta piu' a Zammad: apre un popup con le news (ticket-annuncio) dello studio, dalla piu' recente, con numero,
    data, scadenza (`pending_time`) ed eventuale «Scaduta»; la prima e' gia' aperta e le altre si aprono al click. Il testo e' la conversazione del ticket in sola lettura. Lato ms (`GET tickets/{id}/articles`):
    per i ticket senza paziente (annunci) la lettura segue i permessi del gruppo Zammad (lettura) o l'essere parte del ticket, e `canReply`/`canClose` sono falsi; risposta e chiusura restano riservate ai ticket con paziente.
18. **Stato Zammad «annuncio studio» (id 7).** Gli annunci si creano con `state_id: 7`, uno stato personalizzato che in produzione esiste; su una Zammad nuova (come staging) va creato: tipo «pending reminder» (3), `ignore_escalation`,
    e deve ricevere proprio l'id 7 (la dashboard lo legge da `zammadStateTicketStudyAnnunce`, default 7). La scadenza e' il `pending_time`. Gli annunci non bloccano mai nessuna CRF (`crfscope: STUDY`).
19. **Priorita' dei ticket.** La sceglie solo chi apre il ticket (bassa 1, normale 2, alta 3; default normale), sia sui ticket di CRF sia sulle news; il ms la accetta alla creazione (`priority_id` 1-3, altro = 422)
    e la espone negli elenchi. Etichetta rossa «Alta» o grigia «Bassa» nel pannello CRF, in «I miei ticket» e nel popup delle news, dove le piu' importanti vanno in cima (poi la piu' recente).
    Dopo la creazione la priorita' resta modificabile da Zammad, non dalla piattaforma.
20. **Allegati: solo sulle news di studio.** Fino a 3 file da 10 MB, tipi PDF, PNG, JPG, DOCX, XLSX, CSV, TXT. Il ms li controlla sul contenuto vero (firma del file, non il tipo dichiarato), ripulisce il nome, ricava il tipo dall'estensione
    e li rifiuta (422) su ticket di CRF o con paziente. Chi vede il ticket li scarica (`GET /tickets/{id}/articles/{articleId}/attachments/{attachmentId}`): risposta sempre come file da salvare, mai da aprire nel browser
    (`application/octet-stream`, `nosniff`, `no-store`), con il controllo che l'allegato sia di quell'articolo e non interno; ogni accesso e' nell'audit. **I file stanno solo in Zammad** (nessuna copia nella piattaforma): valgono
    i backup di Zammad e, se Zammad e' fermo, non si scaricano. Serve: la risorsa Keycloak `Attachments` (`add-zammad-authz.py`, commit successivo al 1073a51) e `quarkus.http.limits.max-body-size=45M` nel
    `microservice-config-zammad/application.properties` (3 x 10 MB in base64 superano il default di 10 MB; su staging aggiunto a mano al file del server). Apache ha `LimitRequestBody` a 1 GB. **Nessun antivirus**: da valutare (per esempio ClamAV)
    prima di aprire gli allegati in produzione, e con il DPO per il rischio di dati personali nei file.

## 5. Da NON portare in produzione

- le soglie alzate di Elasticsearch (4.1);
- le immagini "delta" costruite a mano;
- il token Zammad creato per l'utente personale (usare un utente di servizio);
- i dati di test (`ZZ-TEST`): gia' cancellati da staging.

## 6. Segreti esposti in sessione, da ruotare

- una password utente scritta in chiaro in chat;
- il token di servizio Zammad di staging, stampato per errore da un filtro troppo largo;
- un token GitHub comparso nell'elenco delle variabili d'ambiente di una shell locale;
- un frammento di password del mailer dal `.env` di staging;
- in produzione: il token Zammad presente in chiaro nel file `application.properties` del repo del ms Zammad (dal primo commit) va ruotato prima del go-live.

## 7. Aperto

- bonifica dei ticket vecchi chiusi senza marcatore;
- domande al cliente 7-16 (`2026-10-22-ticket-crf-domande-al-cliente.md`) e differenza di visibilita' del gruppo 4 in «I miei ticket»;
- decisione su deroga alla certificazione con sistema ticket in manutenzione;
- capacita' di staging (disco e RAM) e riavvii dei container Zammad;
- catalogo unico degli stati, limiti 100/300 su elenchi, audit di lettura;
- `irccs-tac`, `irccs-webpush` e `irccs-antora-docs` risultavano fermi su staging dalle 11:41 del 23/10 (SIGTERM, non fermati da noi): da verificare e riavviare se serve.

## 8. Aggiornamento 24/10: visibilita' per gruppo, segno firmato, revisione di sicurezza

**Visibilita' dei ticket di CRF** (ms zammad `TicketThreadService`): un ticket si vede solo se si vede il paziente E si e' aperto il ticket oppure si ha lettura sul gruppo Zammad a cui e' assegnato. Stessa regola per conversazione, allegati, elenchi per CRF/paziente, «I miei ticket». Rispondere, chiudere, riaprire richiedono la scrittura (aver aperto il ticket o `change`/`full` sul gruppo): la sola lettura non basta e il ripiego sull'identita' di servizio non la aggira. Il blocco della conferma CRF non cambia: decide il server per tutti, anche per chi non vede il ticket (il riepilogo mostra solo id e stato). **Admin del centro** (decisione del cliente 25/10: vedono e chiudono tutti i ticket del centro): ruolo realm `internal:manage:center-tickets` (creato da `add-ticket-gate-roles.py`) da assegnare ai gruppi Admins di ogni centro. Il sync Keycloak->Zammad da' `full` su tutti i gruppi della famiglia a chi appartiene a un gruppo con quel ruolo; la chiusura richiede comunque `internal:close:ticket`. Senza il ruolo, l'admin ha `full` solo sul proprio gruppo. Su staging assegnato a Admins IRCCS (test V3/V4, 42/42). In produzione: assegnarlo dopo `add-ticket-gate-roles.py`.

**Segno di chiusura firmato:** `crfclosure` = `v1|utente|data|firma` (HMAC-SHA256 legata all'id del ticket). Con il segreto impostato i segni non firmati o con firma errata non valgono: le chiusure fatte prima vanno riconvalidate dal pannello.

**Altre correzioni (revisione):** news di studio senza paziente/CRF; sync con collegamento per email solo se verificata e senza email nei log; `PUT` ticket e «I miei ticket» con visibilita' del paziente; risposte di creazione/modifica ridotte ai soli campi ammessi; timeout sulle chiamate a Zammad; elenchi letti in parallelo; token Zammad non piu' nel default impacchettato; blocco ticket anche sul completamento da link e sull'import Bundle (studio-clinico), fail-closed se la QR salvata non si legge, WARN a blocco spento, deroga legata alla sola scrittura `completed` (common, dashboard); `ADMIN_PASS` e paziente di prova senza default negli script.

**Test E2E su staging** (`setup/test/`, girano sul server, stdlib Python, utenti Keycloak temporanei):
- `e2e_ticket_workflow.py` — admin apre il ticket, lo sperimentatore risponde, l'admin chiude e conferma (25 controlli). Servono `E2E_PATIENT` ed `E2E_CAREPLAN`.
- `e2e_ticket_visibility.py [--keep]` — visibilita' per gruppo con admin, due sperimentatori e Farmacovigilanza (36 controlli); `--keep` lascia i dati.
Richiedono `.env` del server e il token Zammad in `~/ticket-crf-align/.zammad-token`.

**Ancora aperti:** rotazione del token Zammad e pulizia della storia git (era in chiaro in `application.properties` dal primo commit); completamento da link e import Bundle non provati su staging; TLS interno verso Zammad; 11 test di studio-clinico gia' falliti prima (TokenResource, controller link).

## 9. Aggiornamento 25/10: nuova interfaccia dei ticket

Dashboard (`ticket-gate-ui`, commit 7f5455fc e bf98acf7) e ms zammad (b039d52, campo `assignedToMe` in `/mine`) installati su staging con il metodo delta (immagine della dashboard costruita da `stg-build` con la patch applicata, `config.js` del server lasciato com'e'; jar del ms con lo stesso hash della build locale). Nessuna modifica di Keycloak, Zammad o configurazione.

Cosa cambia per gli utenti: pannello ticket con filtri, avanzamento e cronologia (a pagina intera su mobile), banner «conferma bloccata», nuovo ticket in tre passi, «I miei ticket» con filtri e anteprima, fascia «Ticket da seguire» in home paziente, news ridisegnate. Dettagli e componenti: pagina `ticket-crf.adoc`, sezione «Interfaccia e schermi».

Verifica: schermate provate in un browser vero su staging a 1440, 820 e 390 pixel con un utente temporaneo admin del centro (poi cancellato). Non viste a schermo: popup delle news e fascia in home paziente (nessun ticket di prova li faceva comparire).

Porting in produzione: nessun passo in piu' rispetto alla sezione 3; il ms zammad deve essere 27.1.0 con questo commit, altrimenti i filtri «Assegnati a me» di «I miei ticket» restano a zero (la dashboard tollera il campo mancante).

Pulsante «Conferma CRF» (25/10): ora e' disabilitato ogni volta che la conferma non e' possibile (ticket bloccanti, stato non verificabile, riepilogo in caricamento). La deroga e' un pulsante a parte, «Conferma con deroga…», visibile solo a chi ha il ruolo e solo se il server la ammette. Nessuna modifica lato server.

Audit: l'analisi dell'audit dei ticket (cosa e' tracciato e i limiti noti) e' nella pagina `ticket-crf.adoc`, sezione «Audit e log».
