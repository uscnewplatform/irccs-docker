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
- HMAC del marcatore `crfclosure`, catalogo unico degli stati, limiti 100/300 su elenchi, audit di lettura;
- `irccs-tac`, `irccs-webpush` e `irccs-antora-docs` risultavano fermi su staging dalle 11:41 del 23/10 (SIGTERM, non fermati da noi): da verificare e riavviare se serve.
