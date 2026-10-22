# Ticket CRF "tutto a Zammad" — piano di implementazione

> **Per chi esegue:** usare superpowers:subagent-driven-development (consigliato) o superpowers:executing-plans. I passi usano le caselle `- [ ]`.

**Obiettivo:** il blocco della conferma CRF e gli elenchi di ticket leggono lo stato direttamente da Zammad, senza la copia `Task ticket-ref` in HAPI, senza webhook, riconciliazione e heartbeat.

**Architettura:** solo il ms zammad parla con Zammad (`POST /tickets/search` con `condition`, funziona senza Elasticsearch). Il gate di `irccs-common` chiama un endpoint interno del ms zammad con l'identita' di servizio. Zammad non raggiungibile, lento o con risposta non valida = esito `INDETERMINATE` = 503 `CRF_TICKET_STATE_UNVERIFIABLE`, **mai** scavalcabile con la deroga.

**Stack:** Java 21, Quarkus 3.19, HAPI FHIR R4, JDK `HttpClient`, JUnit 5; React 18 + TypeScript + MUI + TanStack Query; Python/bash per gli script.

**Spec:** `docs/superpowers/specs/2026-10-22-ticket-crf-zammad-live-design.md`

## Vincoli globali

- Branch nuovo in ogni repo: `feature/PASTRL-720/ticket-crf-zammad-live`, creato da `feature/PASTRL-720/ticket-crf-gate`. Il branch vecchio non si tocca. Mai commit su develop/master/main. Commit solo su richiesta dell'utente.
- Messaggio per il medico (it): «Sistema di ticket in manutenzione. Riprovare o contattare l'assistenza». Chiavi i18n in it/en/de/fr, nessuna stringa fissa nella UI.
- Deroga con ticket non verificabili: regola attivabile a richiesta con `crf.confirm.override-when-unverifiable` (default `false` = nessuna deroga). `.env_example` e documentazione la riportano (Task 7).
- Timeout della chiamata a Zammad: 3 s (`zammad.ticket-lookup.timeout`, default `3s`). Pagine da 200; oltre 1000 risultati per paziente = `INDETERMINATE`.
- Nessuna cache dello stato dei ticket. Solo la mappa `id stato -> tipo` si rinfresca ogni 10 minuti.
- Stati: bloccano `new`, `open`, `pending reminder`, `pending action` e ogni tipo sconosciuto; non bloccano `closed`, `merged`. Ticket con `crfscope=STUDY` non bloccano mai.
- Commenti e log in italiano. Nei log mai token, risposte, nomi o email. Mai scrivere o creare ticket sul Zammad reale (`zammad.infocube.it`); test solo sul Zammad di prova locale (`zspike`, porta 3030).
- Credenziali di prova locali mai in file committati.
- Common si installa in `~/.m2` come `27.0.0-ticketgate` (`versions:set` + `install -DskipTests` + `git checkout -- .`) e i ms si compilano con `-Di3.common.version=27.0.0-ticketgate`.

## Review Focus

1. Zammad risponde 200 ma con corpo non JSON o non lista: `INDETERMINATE`, mai `CLEAR` (test in Task 1 e Task 3).
2. Ricerca che torna esattamente una pagina piena: si pagina; oltre 1000 risultati: `INDETERMINATE` (Task 1).
3. Paziente `383` non deve trovare i ticket del paziente `8383` (confronto esatto, Task 1).
4. Deroga (header + capability) con esito `INDETERMINATE`: con la proprieta' `crf.confirm.override-when-unverifiable` spenta (default) resta 503 e nessun audit di override; accesa, la deroga passa con audit (Task 3).
5. Ticket di studio (`crfscope=STUDY`) e ticket senza campi `patient`/`careplan`/`crf` non bloccano e non rompono l'elenco (Task 1).

---

### Task 0: Branch nuovi

**Files:** nessuno.

- [ ] **Step 1:** nei worktree `irccs-common/.claude/worktrees/ticket-gate`, `irccs-microservice-zammad/.claude/worktrees/ticket-drawer`, `irccs-microservice-studio-clinico/.claude/worktrees/ticket-gate`, `irccs-microservice-patient-interview/.claude/worktrees/ticket-gate`, `irccs-react-dashboard/.claude/worktrees/ticket-gate-ui` eseguire `git switch -c feature/PASTRL-720/ticket-crf-zammad-live`. (`irccs-docker` ha gia' il branch con il design.)
- [ ] **Step 2:** verificare con `git branch --show-current` e `git status --porcelain` (vuoto) in ognuno.

### Task 1: Ricerca dei ticket su Zammad (ms zammad)

**Files:**
- Create: `src/main/java/org/quarkus/microservice/irccs/zammad/ticketref/ZammadTicketSearch.java`
- Create: `src/main/java/org/quarkus/microservice/irccs/zammad/ticketref/ZammadUnavailableException.java`
- Test: `src/test/java/org/quarkus/microservice/irccs/zammad/ticketref/ZammadTicketSearchTest.java`

**Interfaces:**
- Produces:
  - `public record FoundTicket(long ticketId, String carePlanId, String questionnaireId, String stateType, boolean studyScope)`
  - `public class ZammadUnavailableException extends Exception` (costruttore `(String motivo)`; il messaggio non contiene mai il corpo della risposta)
  - `public ZammadTicketSearch(String baseUrl, String token, Duration timeout, ObjectMapper mapper)` (costruttore per i test) piu' un produttore CDI `@ApplicationScoped` che legge `zammad.base-url`, `zammad.token`, `zammad.ticket-lookup.timeout`
  - `public List<FoundTicket> find(String patientId, String carePlanId, String questionnaireId, boolean onlyBlocking) throws ZammadUnavailableException` — `carePlanId`/`questionnaireId` null = non filtrare; `onlyBlocking=true` esclude closed/merged e ticket di studio.

- [ ] **Step 1: test (server finto con `com.sun.net.httpserver.HttpServer`)** — nomi e asserzioni:
  - `findPostsConditionWithExactPatientCarePlanAndCrf`: il corpo ricevuto contiene `ticket.patient`/`ticket.careplan`/`ticket.crf` con `"operator":"is"` e i valori passati; la richiesta e' `POST /api/v1/tickets/search`.
  - `onlyBlockingExcludesClosedAndMergedStateIds`: con `/ticket_states` che dice closed=4 (tipo closed), merged=5 (tipo merged), la condizione contiene `ticket.state_id` `"is not"` con `["4","5"]`; con `onlyBlocking=false` la condizione di stato manca.
  - `unknownStateTypeStillBlocks`: uno stato con `state_type` fuori dall'elenco non entra tra gli esclusi.
  - `paginatesUntilShortPage`: pagina da 200 piena poi pagina da 3 = 203 risultati.
  - `moreThanOneThousandIsUnavailable`: oltre 1000 -> `ZammadUnavailableException`.
  - `studyScopeTicketIsFlaggedAndSkippedWhenOnlyBlocking`.
  - `ticketWithoutCrfFieldsIsIgnoredForCrfQuery`.
  - `malformedBodyIsUnavailable` (corpo `{}` e corpo non JSON), `http500IsUnavailable`, `timeoutIsUnavailable` (server che dorme oltre il timeout).
  - `invalidIdsAreRejected`: id con caratteri non numerici -> `IllegalArgumentException` (si validano con `CrfKey.idOf`).
- [ ] **Step 2:** eseguire `mvn -q test -Dtest=ZammadTicketSearchTest -Di3.common.version=27.0.0-ticketgate`; atteso: FAIL (classe mancante).
- [ ] **Step 3:** implementare. Approccio: `GET ticket_states` (tipo da `state_type_id` con la stessa mappa 1..6 di `ZammadHttpApi`), con TTL 10 minuti; `POST tickets/search` con `condition` e `per_page=200&page=N` (verificare sul Zammad di prova che `per_page`/`page` siano onorati dal POST; altrimenti usare `limit`/`page` come visto in prova). Header `Authorization: Bearer <token>` come `ZammadHttpApi`. Qualunque errore di rete, HTTP non 200 o JSON non lista -> `ZammadUnavailableException`.
- [ ] **Step 4:** stesso comando; atteso: PASS.
- [ ] **Step 5: commit** `feat(zammad): ricerca dei ticket di una CRF direttamente su Zammad`.

### Task 2: Collegamento nel ms zammad e rimozione della sincronizzazione

**Files:**
- Modify: `ticketref/CrfTicketLookup.java` (usa `ZammadTicketSearch`; stessi metodi pubblici `ticketIds` e `refsOfPatient`, con `onlyBlocking=false` come oggi)
- Modify: `ticketref/CrfSummaryService.java` (usa `ZammadTicketSearch`, niente `FhirClient<Task>` ne' `maxSyncAge`)
- Modify: `service/TicketThreadService.java` (rimuove `TicketRefService ticketRef` e i suoi usi; l'errore di `ZammadUnavailableException` diventa 503 `{"error":"Sistema di ticket in manutenzione"}`)
- Modify: `controller/ZammadTicketApiController.java` (aggiunge `GET /tickets/open-for-gate`; toglie `ticket-ref-report`)
- Delete: `ticketref/TicketRefService.java`, `TicketRefSyncService.java`, `TicketRefMapper.java`, `TicketRefStore.java`, `FhirTicketRefStore.java`, `TicketRefReport.java`, `ZammadWebhookResource.java`, `ZammadApi.java`, `ZammadHttpApi.java` e i test corrispondenti (`TicketRef*Test`, `ZammadWebhookResourceTest`, `CrfSummaryServiceTest` da riscrivere)
- Modify: `src/main/resources/application.properties` (toglie `zammad.ticket-ref.*`, `zammad.webhook.*`; aggiunge `zammad.ticket-lookup.timeout=${ZAMMAD_TICKET_LOOKUP_TIMEOUT:3s}`)
- Test: `TicketThreadServiceTest`, `CrfTicketLookupTest`, nuovo `OpenForGateResourceTest`

**Interfaces:**
- Consumes: `ZammadTicketSearch.find(...)`, `FoundTicket` (Task 1).
- Produces: `GET /fhir/zammad/tickets/open-for-gate?patient=&careplan=&questionnaire=` (careplan e questionnaire facoltativi; senza entrambi = tutto il paziente). Risposta 200 `{"tickets":[{"id":123,"state":"open"}]}` (solo id e tipo di stato, mai testo ne' titoli); 400 id non validi; 503 se Zammad non disponibile. **Nessun controllo `PatientVisibility`**: e' una chiamata tra servizi, ma l'accesso e' limitato dall'authz di Keycloak (Task 5).

- [ ] **Step 1: test** `OpenForGateResourceTest`: 200 con lista (mock di `ZammadTicketSearch`), 200 con lista vuota, 400 con `patient=abc`, 503 con `ZammadUnavailableException`; il corpo non contiene altri campi oltre `id` e `state`. Aggiornare `TicketThreadServiceTest` e `CrfTicketLookupTest` ai nuovi collaboratori; `CrfSummaryService` con flag spento non chiama Zammad.
- [ ] **Step 2:** eseguire i test del modulo; atteso: FAIL.
- [ ] **Step 3:** implementare; cancellare le classi elencate e ogni riferimento (`grep -rn "ticketref\|TicketRef" src` deve restare vuoto tranne `ZammadTicketSearch`/`CrfTicketLookup`/`CrfSummaryService`).
- [ ] **Step 4:** `mvn -q test -Di3.common.version=27.0.0-ticketgate`; atteso: tutti PASS.
- [ ] **Step 5: commit** `refactor(zammad): i ticket di una CRF si leggono da Zammad, via la sincronizzazione su HAPI`.

### Task 3: Il gate in `irccs-common` chiama il ms zammad

**Files:**
- Create: `i3-client/src/main/java/org/quarkus/irccs/client/ticket/TicketLookup.java`
- Create: `i3-client/src/main/java/org/quarkus/irccs/client/ticket/ZammadTicketLookup.java`
- Modify: `i3-client/.../CrfTicketGate.java`, `TicketGatePolicy.java`, `TicketRefConstants.java`
- Delete: `TicketStateMapper.java` (+ test), parti Task/heartbeat dei test di `CrfTicketGateTest`
- Modify: `i3-annotations/.../QuestionnaireResponseFlow.java` (`enforceTicketGate`)
- Test: `CrfTicketGateTest`, `TicketGatePolicyTest`, nuovo `ZammadTicketLookupTest`

**Interfaces:**
- Produces:
  - `public interface TicketLookup { List<OpenTicket> open(String patientId, String carePlanId, String questionnaireId) throws Exception; }` e `public record OpenTicket(String ticketId, String state) {}`
  - `public ZammadTicketLookup(String baseUrl, Supplier<String> bearerToken, Duration timeout)` e `static ZammadTicketLookup fromConfig(Supplier<String> bearerToken)` che legge `crf.confirm.ticket-service-url` (default `http://irccs-zammad:8080`, nome del container nel compose) e `zammad.ticket-lookup.timeout` (default `3s`).
  - `CrfTicketGate.configured(TicketLookup)`, `CrfTicketGate.knownBlock(QuestionnaireResponse, TicketLookup)`, `new CrfTicketGate(TicketLookup)`, stessi `evaluate(qr)`, `evaluate(patient, carePlan, questionnaire)`, `evaluatePatient(patient)`; `Decision`/`Outcome`/`Blocking` invariati.
- Cambia: `TicketGatePolicy.resolve(decision, rawReason, canOverride, overrideWhenUnverifiable)` — con `decision.outcome()==INDETERMINATE` e `overrideWhenUnverifiable=false` (default) il verdetto e' **sempre** `reject(503, ERROR_UNVERIFIABLE, ...)`, anche con motivo e capability; con `true` la deroga vale anche per INDETERMINATE (come prima). Il 403/422 della deroga valgono come prima. La proprieta' e' `crf.confirm.override-when-unverifiable` (env `CRF_CONFIRM_OVERRIDE_WHEN_UNVERIFIABLE`, **default `false`**), letta da `CrfTicketGate.overrideWhenUnverifiable()` (statico, via `ConfigProvider`) e passata dal chiamante.

- [ ] **Step 1: test**
  - `CrfTicketGateTest`: lookup vuoto -> CLEAR; due ticket -> BLOCKED con i loro id; lookup che lancia -> INDETERMINATE; QR senza paziente/questionario -> INDETERMINATE; `evaluatePatient` chiama il lookup con carePlan e questionnaire null; `knownBlock` ritorna presente solo per BLOCKED (mai per INDETERMINATE).
  - `TicketGatePolicyTest`: `overrideIsIgnoredWhenIndeterminate` (motivo valido + `canOverride=true` + flag false -> 503 `CRF_TICKET_STATE_UNVERIFIABLE`); `overrideWorksWhenIndeterminateAndFlagTrue` (stessi input con flag true -> `OVERRIDE`); `overrideStillWorksWhenBlocked` (-> `OVERRIDE`); motivo troppo corto con `BLOCKED` -> 422; senza capability con `BLOCKED` -> 403.
  - `ZammadTicketLookupTest` (server finto): manda `Authorization: Bearer <token del supplier>` e i parametri `patient`/`careplan`/`questionnaire`; legge `{"tickets":[...]}`; HTTP 503, corpo non JSON, corpo senza `tickets`, timeout -> eccezione.
- [ ] **Step 2:** `mvn -q test -pl i3-client`; atteso: FAIL.
- [ ] **Step 3:** implementare; in `QuestionnaireResponseFlow.enforceTicketGate` sostituire la lambda su `taskClient` con `ZammadTicketLookup.fromConfig(() -> getServiceAccountJwt().getRawToken())`; l'audit `crf-confirm-blocked-by-tickets` si scrive anche per l'esito 503. Togliere da `TicketRefConstants` solo cio' che serve ai Task (codici Task, sistemi identifier, heartbeat); restano ruoli, intestazione, limiti della motivazione, codici di errore.
- [ ] **Step 4:** `mvn -q test -pl i3-client,i3-annotations`; atteso: PASS. Poi `mvn install -DskipTests` come `27.0.0-ticketgate`.
- [ ] **Step 5: commit** `feat(common): il blocco ticket interroga il ms zammad; nessuna deroga se i ticket non sono verificabili`.

### Task 4: studio-clinico e patient-interview

**Files:**
- Modify: `studio-clinico/.../controller/PatientQuestionnaireResponseController.java:194`, `.../service/CrfCertificationService.java:257`
- Modify: `patient-interview/.../service/InterviewService.java:206`
- Test: `PatientQuestionnaireResponseControllerUnitTest` + test del servizio di certificazione e di `InterviewService` dove esistono

**Interfaces:** Consumes `ZammadTicketLookup.fromConfig(...)`, `CrfTicketGate.configured/knownBlock` (Task 3).

- [ ] **Step 1: test** — con il lookup finto: certificazione blocca (409) con ticket aperti, risponde 503 con lookup che lancia, nessuna deroga; il percorso del paziente (`knownBlock`) non si ferma se il lookup lancia (resta loggato).
- [ ] **Step 2:** eseguire i test; atteso: FAIL (firma cambiata).
- [ ] **Step 3:** sostituire le lambda su `taskClient` con `ZammadTicketLookup.fromConfig(<supplier del token di servizio gia' usato dal servizio>)`; togliere gli `@Inject FhirClient<Task>` rimasti inutilizzati.
- [ ] **Step 4:** `mvn -q test -Di3.common.version=27.0.0-ticketgate`; atteso: PASS in entrambi i repo.
- [ ] **Step 5: commit** in ciascun repo `feat(...): il blocco ticket usa il lookup su Zammad`.

### Task 5: Autorizzazioni Keycloak per l'endpoint di servizio

**Files:**
- Modify: `irccs-docker/keycloak-config/add-zammad-authz.py` (e la copia in `git pascale/irccs-docker`)

- [ ] **Step 1:** leggere lo script e `realm-export` per capire come i servizi si autenticano tra loro (service account dei client di studio-clinico/patient-interview e degli altri ms con `QuestionnaireResponseFlow`) e quale ruolo/permesso usano gli altri endpoint chiamati cosi'.
- [ ] **Step 2:** aggiungere la risorsa `OpenForGate` (`GET /open-for-gate`) con il permesso riservato ai service account dei ms che usano il gate (stesso schema delle risorse `ByPatient`, `CrfSummary`); nessun accesso per gli utenti normali. Lo script resta idempotente e con `--dry-run`.
- [ ] **Step 3:** eseguire in dry-run sul Keycloak locale (`pascale-local`), poi applicare; atteso: la risorsa esiste, un utente normale riceve 403, il service account riceve 200.
- [ ] **Step 4: commit** `feat(keycloak): risorsa open-for-gate riservata ai servizi`.

### Task 6: Dashboard

**Files:**
- Modify: `src/fhir/front-office/components/Crf/CrfConfirmButton.tsx` (esito `INDETERMINATE` o errore: bottone disabilitato **senza** dialogo di deroga; chip con il messaggio di manutenzione. Se il server consente la deroga anche per INDETERMINATE, `crf-summary` espone `"overrideWhenUnverifiable": true` e il dialogo resta disponibile come oggi)
- Modify: `src/fhir/front-office/components/Crf/CrfTherapyRenderer.tsx` (~riga 762, ramo `TICKET_ERROR_UNVERIFIABLE`: mostra il messaggio e non apre la deroga)
- Modify: `src/fhir/components/Patients/PatientOpenTickets.tsx` (se `by-patient` risponde 503: messaggio di manutenzione al posto dell'elenco)
- Modify: `public/locales/{it,en,de,fr}/translation.json` (`crf.ticketGate.unverifiableTooltip`, `crf.ticketGate.errorUnverifiable`, `crf.ticketGate.unverifiable`, nuova `crf.ticketGate.maintenance`, nuova `patients.openTicketsMaintenance`; togliere `overrideWarningUnverifiable`)
- Test: `tsc --noEmit` e prova nel browser

**Interfaces:** Consumes `GET zammad/tickets/crf-summary` (outcome `CLEAR|BLOCKED|INDETERMINATE`) e gli errori 409/422/503 gia' gestiti da `ticketGateErrorCode`.

Testo italiano `crf.ticketGate.maintenance` e `patients.openTicketsMaintenance`: «Sistema di ticket in manutenzione. Riprovare o contattare l'assistenza». Tradurre in en/de/fr.

- [ ] **Step 1:** in `CrfConfirmButton`, `mustOverride` vale solo `blocked`; con `unverifiable` il bottone e' disabilitato e il tooltip e' `crf.ticketGate.maintenance`.
- [ ] **Step 2:** `npx tsc --noEmit`; atteso: nessun errore nuovo.
- [ ] **Step 3:** aggiornare i quattro file di traduzione con le stesse chiavi; `npm run build`.
- [ ] **Step 4:** verifica a vista nel browser (Task 8).
- [ ] **Step 5: commit** `feat(dashboard): messaggio di manutenzione e nessuna deroga se i ticket non sono verificabili`.

### Task 7: Installazione e documentazione (irccs-docker e produzione)

**Files:**
- Delete: `setup/install/install_zammad_webhook.sh`
- Modify: `setup/install/align_ticket_crf.sh` (via i passi 5 e 7 e i controlli su webhook/heartbeat; aggiunge il controllo di `zammad.ticket-lookup` e una chiamata di prova a `open-for-gate` in sola lettura)
- Modify: `microservice-config-zammad/application.properties` (via `paths.7` del webhook)
- Modify: `.env_example` (via `ZAMMAD_TICKET_REF_ENABLED`, `ZAMMAD_INSTANCE_ID`, `ZAMMAD_WEBHOOK_SECRET`, `CRF_CONFIRM_TICKET_SYNC_MAX_AGE`; aggiunge `ZAMMAD_TICKET_LOOKUP_TIMEOUT=3s` e `CRF_CONFIRM_OVERRIDE_WHEN_UNVERIFIABLE=false`)
- Modify: `docs/modules/ROOT/pages/ticket-crf.adoc`, `docs/superpowers/specs/2026-10-22-guida-installazione-produzione-ticket-crf.md` (sezioni di sincronizzazione, webhook, heartbeat, configurazione montata)
- Mirror con edit mirati in `git pascale/irccs-docker` (solo script, `.env_example` e `application.properties` del ms zammad; mai il `.env` di produzione)

- [ ] **Step 1:** applicare le modifiche nel repo di sviluppo e verificare con `bash -n setup/install/align_ticket_crf.sh` e `grep -rniE "webhook|heartbeat|ticket-ref|INSTANCE_ID" setup .env_example microservice-config-zammad` (restano solo riferimenti storici nei documenti marcati come tali).
- [ ] **Step 2:** copiare gli stessi file nel repo di produzione e confrontarli con `cmp`.
- [ ] **Step 3: commit** in entrambi i repo `chore(ticket): via webhook e sincronizzazione dall'installazione`.

### Task 8: Prova completa in locale

**Files:** nessun file di prodotto; script di prova solo nello scratchpad (mai in commit).

- [ ] **Step 1:** ricostruire common (`27.0.0-ticketgate`), ms zammad, studio-clinico, patient-interview, dashboard; ricreare `pascale-local` con il Zammad di prova (`E2E_ZAMMAD_TOKEN` nello stesso comando di `docker compose up`, `-f e2e-full.yml`).
- [ ] **Step 2: scenari** (atteso tra parentesi): ticket aperto sulla CRF -> conferma 409 `CRF_OPEN_TICKETS`; chiuso -> conferma ok; deroga con capability e motivo di 10+ caratteri su ticket aperto -> ok + evento `ticket-gate-override`; **Zammad fermo** (`docker stop zspike-zammad-railsserver-1`) -> conferma 503 `CRF_TICKET_STATE_UNVERIFIABLE`, **anche con deroga** e senza evento di override; con `CRF_CONFIRM_OVERRIDE_WHEN_UNVERIFIABLE=true` la stessa deroga passa e scrive l'evento; home paziente mostra il messaggio di manutenzione, le icone spariscono senza errori in console; riavvio di Zammad -> tutto torna; ticket cancellato in Zammad smette di bloccare subito; flag spento -> nessuna chiamata a Zammad (log).
- [ ] **Step 3:** riportare l'esito per scenario. Nessun commit; i risultati vanno nel resoconto all'utente.

---

## Ordine e dipendenze

Task 0 -> 1 -> 2 (ms zammad) in parallelo possibile con 3 (common) dopo il Task 0; Task 4 dopo il 3; Task 5 e 7 indipendenti; Task 6 dopo il 2; Task 8 alla fine. Prima del merge: `irccs-common` va rilasciato con una versione nuova (schema ancora da decidere) e `i3.common.version` aggiornato nei tre ms.
