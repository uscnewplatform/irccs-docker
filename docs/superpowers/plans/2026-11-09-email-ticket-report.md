# Email dei ticket: report settimanale e ticket ad alta priorità — Piano di realizzazione

> **Per chi esegue:** SOTTO-SKILL OBBLIGATORIA: `superpowers:subagent-driven-development` (consigliata) oppure `superpowers:executing-plans`. I passi usano la sintassi a caselle `- [ ]`.

**Obiettivo:** il microservizio Zammad manda un report settimanale per gruppo e, per i ticket ad alta priorità, le mail di apertura, chiusura, riapertura e sollecito, senza più usare trigger e job di Zammad.

**Architettura:** due job pianificati nel microservizio (controllo ogni 5 minuti dei ticket ad alta priorità; report con cron). Logica pura e testabile (decisione dell'azione, destinatari, testo delle mail), un piccolo client Zammad con il token di servizio, invio con `EmailService` di `i3-mail`. Lo stato «già inviato» sta in tag sul ticket in Zammad.

**Stack:** Java 21, Quarkus 3.19 (`quarkus-scheduler` già nel pom), Mockito/JUnit 5, `i3-mail` (`EmailService.sendHtmlEmail`), Zammad 7.2 REST, bash/curl per l'installazione.

**Spec:** `irccs-docker/docs/superpowers/specs/2026-11-09-email-ticket-report-design.md`

Repo: `irccs-microservice-zammad` (codice), `irccs-docker` (configurazione, script, doc) e la copia di produzione `git pascale/irccs-docker` (stessi file con edit mirati). Il ramo parte da `develop` (`8adee8f`); numero PASTRL da chiedere all'utente.

## Global Constraints

- **Ticket ad alta priorità** = `priority_id` 3 («3 high»), valutata al momento del controllo. Solo ticket di CRF (non `crfscope` `STUDY`); le news non mandano mai mail.
- **Tag sul ticket** (nessun attributo, nessuna migrazione): `mail-apertura`, `mail-chiusura`, `mail-ultimo-invio-<aaaammggThhmm>` (UTC, data dell'ultima mail inviata fra apertura, riapertura e sollecito; ne esiste uno solo alla volta). Ordine: **prima la mail, poi il tag**; se tutte le mail di un invio falliscono non si scrive nessun tag (si riprova al giro dopo).
- **Azioni**: apertura (ticket non chiuso, senza `mail-apertura`, creato dopo `START_FROM`); chiusura (chiuso, con `mail-apertura`, senza `mail-chiusura`); riapertura (non chiuso, con `mail-chiusura`: si toglie quel tag); sollecito (non chiuso, con `mail-apertura`, fermo da **3 giorni**: l'ultimo messaggio `last_contact_at`, l'ultima mail e la creazione sono tutti più vecchi di 3 giorni). Ticket chiuso senza `mail-apertura`: nessuna mail.
- **Ticket già aperti all'attivazione** (creati prima di `START_FROM`, senza `mail-apertura`): solo i tag `mail-apertura` e `mail-ultimo-invio-<ora>`, **nessuna mail**; il primo sollecito arriva 3 giorni dopo.
- **Destinatari**: utenti Zammad attivi con email e permesso `read`, `change` o `full` sul gruppo (`create`/`overview` non contano), senza gli indirizzi di `EXCLUDE_EMAILS`, in minuscolo e senza doppioni. Apertura, chiusura e riapertura: gruppi coinvolti (`group_id` più `targetgroups`). Sollecito: gruppi coinvolti più `opengroup`; senza `opengroup`, il cliente del ticket se è un utente Zammad attivo con email.
- **Report**: lunedì 8:00 `Europe/Rome` (cron configurabile), una email per gruppo a ogni suo membro, con tutti i ticket di CRF non chiusi di quel gruppo (primario o `targetgroups`); ordinati prima per priorità alta, poi per anzianità; un gruppo senza ticket aperti non riceve nulla; se il servizio è fermo alle 8:00 la settimana si salta.
- **Aspetto**: HTML bilingue italiano/inglese; blu `#337ab7` (titoli, pulsanti), rosso `#a94442` su `#f2dede` (etichetta ALTA), grigio `#f5f5f5` (intestazione tabella), bordi `#dddddd`. Colonne del report: Paziente (`patientdisplay`), Studio (`patientjourneydisplay`), Ticket (`#numero · titolo`, ALTA se priorità alta), Aperto da (giorni), «Apri il ticket». Collegamento: `directlink` del ticket, altrimenti il modello `zammad.notifications.ticket-url-template` (`{id}`).
- **Configurazione** (variabile d'ambiente → proprietà): `ZAMMAD_NOTIFICATIONS_ENABLED` → `zammad.notifications.enabled` (default **false**), `…_REPORT_CRON` → `zammad.notifications.report-cron` (default `0 0 8 ? * MON`), `…_REMINDER_INTERVAL` → `zammad.notifications.reminder-interval` (`3d`), `…_POLL_INTERVAL` → `zammad.notifications.poll-interval` (`5m`), `…_START_FROM` → `zammad.notifications.start-from` (istante ISO-8601 UTC; **vuoto = il job ad alta priorità non parte** e lo dice nel log), `…_TICKET_URL`, `…_EXCLUDE_EMAILS` (elenco a virgole), `…_SEND_PAUSE` (`200ms`, pausa fra due invii), `…_CLOSE_LOOKBACK` (`7d`: ticket chiusi più vecchi non ricevono la mail di chiusura). Mailer: `quarkus.mailer.host`/`port`/`from`/`start-tls=DISABLED`/`mock`, relay `10.1.253.151:25` senza auth né TLS, mittente `noreply-pj@istitutotumori.na.it`.
- Pacchetto nuovo: `org.quarkus.microservice.irccs.zammad.notification`. Commenti e log in italiano; log solo con conteggi e identificativi numerici: **mai** indirizzi, nomi, testi o token. Stile dei file vicini; test puri senza avvio di Quarkus dove possibile.
- Nessun commit finché l'utente non lo chiede; PR aperta dalla CI.

## Review Focus

- Attivazione con ticket ad alta priorità già aperti: nessuna mail di apertura e nessun sollecito prima di 3 giorni (Task 1, 5).
- Riavvio o due esecuzioni ravvicinate: nessun doppione grazie ai tag; nessun tag se la mail non parte (Task 5).
- Ticket di news, non di CRF, priorità non alta: nessuna mail (Task 1, 4).
- Gruppo senza membri, membri senza email, indirizzi esclusi, utente inattivo: nessuna mail e nessuna eccezione; report vuoto non inviato (Task 2, 4, 6).
- Zammad o SMTP non disponibili: il job non si ferma né propaga eccezioni, log senza dati personali (Task 3, 5, 6).
- Ticket riaperto: mail di riapertura e poi di nuovo di chiusura alla chiusura successiva; il conteggio del sollecito riparte (Task 1, 5).
- `directlink` assente o con HTML nel titolo/paziente: link di ripiego e testo scappato (Task 3, 4).

---

### Task 1: Segni sul ticket e decisione dell'azione (logica pura)

**Files:**
- Create: `irccs-microservice-zammad/src/main/java/org/quarkus/microservice/irccs/zammad/notification/{TicketMarks,NotificationAction,TicketFacts,TagChanges,HighPriorityDecision}.java`
- Test: `irccs-microservice-zammad/src/test/java/org/quarkus/microservice/irccs/zammad/notification/{TicketMarksTest,HighPriorityDecisionTest}.java`

**Interfaces:**
- Produces:
  - `public record TicketMarks(boolean opened, boolean closed, Instant lastMailAt, String lastMailTag)`; costanti `TAG_OPENED = "mail-apertura"`, `TAG_CLOSED = "mail-chiusura"`, `PREFIX_LAST = "mail-ultimo-invio-"`; `static TicketMarks parse(List<String> tags)` (tag sconosciuti o data malformata ignorati; `lastMailAt` e `lastMailTag` null se manca); `static String lastMailTag(Instant at)` formato `mail-ultimo-invio-yyyyMMdd'T'HHmm` in UTC.
  - `public enum NotificationAction { NONE, OPEN, CLOSE, REOPEN, REMIND, BASELINE }`
  - `public record TicketFacts(long id, boolean highPriority, boolean closed, boolean crfTicket, Instant createdAt, Instant lastContactAt)` (`lastContactAt` può essere null)
  - `public record TagChanges(List<String> add, List<String> remove)`
  - `public final class HighPriorityDecision { static NotificationAction decide(TicketFacts f, TicketMarks m, Instant now, Instant startFrom, Duration interval); static TagChanges changes(NotificationAction a, TicketMarks m, Instant now); }`
- Regole di `decide` (nell'ordine): `!crfTicket || !highPriority` → NONE. Chiuso: `opened && !closed` → CLOSE, altrimenti NONE. Non chiuso: `closed` → REOPEN; `!opened` → (`createdAt` prima di `startFrom` → BASELINE, altrimenti OPEN); altrimenti fermo se `now - max(createdAt, lastContactAt, lastMailAt) >= interval` → REMIND, altrimenti NONE.
- Regole di `changes`: OPEN e BASELINE → aggiunge `mail-apertura` e `lastMailTag(now)`; CLOSE → aggiunge `mail-chiusura`; REOPEN → toglie `mail-chiusura`, toglie il vecchio tag dell'ultimo invio (se c'è), aggiunge `lastMailTag(now)`; REMIND → sostituisce il tag dell'ultimo invio; NONE → vuoto.

- [ ] **Step 1: Test** `TicketMarksTest`: `parseRiconosceITreSegni`; `parseIgnoraTagSconosciutiEDataMalformata`; `lastMailTagInUtcAlMinuto` (`2026-11-09T08:05:30Z` → `mail-ultimo-invio-20261109T0805`); `parseSenzaTag` (tutto false/null). `HighPriorityDecisionTest` (una riga per caso, con `now` fisso e intervallo 3 giorni): non CRF → NONE; priorità non alta → NONE; non chiuso senza segni creato prima di `startFrom` → BASELINE; stesso creato dopo → OPEN; chiuso con `opened` → CLOSE; chiuso con `opened` e `closed` → NONE; chiuso senza `opened` → NONE; non chiuso con `closed` → REOPEN; con `opened`, fermo da 3 giorni esatti → REMIND, da 2 giorni 23 ore → NONE; un messaggio recente (`lastContactAt`) rimanda; un invio recente (`lastMailAt`) rimanda; `lastContactAt` null usa `createdAt`; `changes` per ogni azione (REOPEN toglie `mail-chiusura` e il vecchio tag; REMIND sostituisce).
- [ ] **Step 2: Eseguire e vedere fallire** — `cd irccs-microservice-zammad && mvn -q -o test -Dtest='TicketMarksTest,HighPriorityDecisionTest'` — errore di compilazione.
- [ ] **Step 3: Implementare** i tipi e le due funzioni pure come da Interfaces.
- [ ] **Step 4: Eseguire e vedere passare** — atteso `Failures: 0`.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): decisione delle email dei ticket ad alta priorita'`.

---

### Task 2: Destinatari

**Files:**
- Create: `.../notification/{GroupMembers,TicketRecipients}.java`
- Test: `.../notification/{GroupMembersTest,TicketRecipientsTest}.java`

**Interfaces:**
- Consumes: `ZammadUser` (`id`, `email`, `active`, `group_ids: Map<String,List<String>>`), `TicketTargets.decode(String)` (pacchetto `ticketgroups`).
- Produces:
  - `public final class GroupMembers { public static SortedSet<String> emails(List<ZammadUser> users, Collection<Long> groupIds, Set<String> excluded); public static boolean isMember(ZammadUser u, long groupId); }` — membro = attivo, email non vuota, permesso `read`/`change`/`full` (confronto in minuscolo senza spazi) su quel gruppo; indirizzi in minuscolo, senza doppioni, senza gli esclusi (confronto senza maiuscole).
  - `public final class TicketRecipients { static Set<Long> involvedGroups(JsonNode ticket); static SortedSet<String> forOpenOrClose(JsonNode ticket, List<ZammadUser> users, Set<String> excluded); static SortedSet<String> forReminder(JsonNode ticket, List<ZammadUser> users, Set<String> excluded); }` — `involvedGroups` = `group_id` più `targetgroups`; `forReminder` aggiunge i membri di `opengroup` (cifre, altrimenti ignorato) oppure, se `opengroup` manca, il cliente (`customer_id`) se è un utente attivo con email.

- [ ] **Step 1: Test** `GroupMembersTest`: attivo con `full` sì; `create` solo no; `overview` solo no; inattivo no; senza email no; doppioni e maiuscole; escluso (maiuscole diverse) no; lista utenti vuota → vuoto. `TicketRecipientsTest`: `involvedGroups` con e senza `targetgroups`; apertura/chiusura solo gruppi coinvolti (non `opengroup`); sollecito aggiunge `opengroup`; sollecito senza `opengroup` aggiunge il cliente; cliente inattivo escluso; `opengroup` malformato ignorato.
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='GroupMembersTest,TicketRecipientsTest'`.
- [ ] **Step 3: Implementare** come da Interfaces.
- [ ] **Step 4: Eseguire e vedere passare**.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): destinatari delle email dei ticket`.

---

### Task 3: Testo delle mail ad alta priorità

**Files:**
- Create: `.../notification/{MailContent,TicketView,HighPriorityMailBuilder}.java`
- Test: `.../notification/HighPriorityMailBuilderTest.java`

**Interfaces:**
- Produces:
  - `public record MailContent(String subject, String html)`; `public record TicketView(long id, String number, String title, String patient, String study, String link)`.
  - `public final class HighPriorityMailBuilder { static MailContent build(NotificationAction action, TicketView t); }` per OPEN, CLOSE, REOPEN, REMIND (altre azioni: `IllegalArgumentException`). Oggetti: `Ticket ad alta priorità aperto / High priority ticket opened #<n>: <titolo>`, `… chiuso / closed …`, `… riaperto / reopened …`, `Sollecito risposta / Reply reminder #<n>: <titolo>`. Il corpo ripete in italiano e in inglese: titolo colorato `#337ab7`, riga con numero, titolo, paziente e studio, pulsante «Apri il ticket / Open the ticket» sul `link` (sfondo `#337ab7`, testo bianco), etichetta ALTA (`#a94442` su `#f2dede`). Titolo, paziente e studio **scappati** per HTML (`& < > " '`); il `link` entra solo se inizia per `http://` o `https://`, altrimenti niente pulsante. CR/LF nel titolo dell'oggetto sostituiti da spazio.

- [ ] **Step 1: Test**: i quattro oggetti esatti; il corpo contiene il blocco italiano prima di quello inglese, il link e i colori; titolo `A&B <script>alert(1)</script>` → nel corpo `A&amp;B &lt;script&gt;` e mai `<script>`; oggetto con `x\r\nBcc: a@b.it` senza `\r` né `\n`; link `javascript:alert(1)` → nessun pulsante; azione NONE → eccezione.
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest=HighPriorityMailBuilderTest`.
- [ ] **Step 3: Implementare** come da Interfaces (funzione di scape privata, nessuna nuova dipendenza).
- [ ] **Step 4: Eseguire e vedere passare**.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): testo delle email dei ticket ad alta priorita'`.

---

### Task 4: Pianificazione e testo del report

**Files:**
- Create: `.../notification/{ReportRow,ReportPlanner,WeeklyReportBuilder}.java`
- Test: `.../notification/{ReportPlannerTest,WeeklyReportBuilderTest}.java`

**Interfaces:**
- Consumes: `MailContent` (Task 3), `TicketRecipients.involvedGroups` (Task 2).
- Produces:
  - `public record ReportRow(String patient, String study, String number, String title, boolean high, long daysOpen, String link)`.
  - `public final class ReportPlanner { static Map<Long, List<ReportRow>> rowsByGroup(List<JsonNode> openTickets, Instant now, String urlTemplate); }` — solo ticket di CRF non chiusi (non `crfscope` `STUDY`, con `patient` valorizzato), una riga per ogni gruppo coinvolto; ordine: priorità alta prima, poi più vecchi per primi; `daysOpen` = giorni interi da `created_at`; `link` = `directlink` se inizia per `http://` o `https://`, altrimenti `urlTemplate` con `{id}` sostituito.
  - `public final class WeeklyReportBuilder { static MailContent build(String groupLabel, LocalDate from, LocalDate to, List<ReportRow> rows); }` — oggetto `Ticket aperti per <gruppo> (settimana <da>-<a>) / Open tickets for <gruppo>`; corpo con riga «Al <a> ci sono N ticket aperti …», tabella con le cinque colonne, intestazione grigia `#f5f5f5`, bordi `#dddddd`, etichetta ALTA, pulsante blu per riga, versione italiana poi inglese; tutto il testo scappato.

- [ ] **Step 1: Test** `ReportPlannerTest`: un ticket a due gruppi compare nelle due liste; news (`crfscope` `STUDY`) e ticket chiuso esclusi; ordine alta-poi-anzianità; `daysOpen` (3 giorni e 23 ore = 3); `directlink` valido usato, vuoto o non http → modello con `{id}`; senza ticket → mappa vuota. `WeeklyReportBuilderTest`: oggetto esatto; N righe → N pulsanti; titolo con HTML scappato; etichetta ALTA solo sulle righe `high`; italiano prima dell'inglese.
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='ReportPlannerTest,WeeklyReportBuilderTest'`.
- [ ] **Step 3: Implementare** come da Interfaces.
- [ ] **Step 4: Eseguire e vedere passare**.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): report settimanale dei ticket aperti per gruppo`.

---

### Task 5: Client Zammad con il token di servizio

**Files:**
- Create: `.../notification/NotificationZammadApi.java`
- Test: `.../notification/NotificationZammadApiTest.java` (server HTTP finto, stile di `ZammadTicketServiceHttpTest`)

**Interfaces:**
- Produces: `@ApplicationScoped public class NotificationZammadApi` (campi `zammad.base-url` e `zammad.token`, `ObjectMapper`) con `throws ZammadUnavailableException` su ogni metodo:
  - `List<JsonNode> openTickets(boolean onlyHighPriority)` — `POST tickets/search?per_page=200&page=N` (fino a 5 pagine) con condizione sullo stato (esclusi `closed` e `merged`, ids letti da `GET ticket_states` per nome, in cache 10 minuti) e, se richiesto, `ticket.priority_id is ["3"]`; ritorna i ticket così come li restituisce Zammad.
  - `List<JsonNode> recentlyClosedHighPriority(Duration lookback)` — stessa ricerca su stato `closed`, priorità 3, con `ticket.close_at` «within last (relative)» pari a `lookback` in giorni.
  - `List<String> tags(long ticketId)` — `GET tags?object=Ticket&o_id=<id>`.
  - `void addTag(long ticketId, String tag)` — `POST tags/add` `{object:"Ticket",o_id,item}`; `void removeTag(long ticketId, String tag)` — `DELETE tags/remove` con lo stesso corpo.
  - `List<ZammadUser> users()` — `GET users?page=N&per_page=100` fino a pagina non piena (massimo 200 pagine, con WARN se si raggiunge il limite).
  - `Map<Long,String> groupLabels()` — `GET groups`, etichetta = nome senza il suffisso `_<centro>` (`PatientCentreGroups.label`).
- Nessun log di corpi, indirizzi o token; header `Authorization: Bearer <token>`.

- [ ] **Step 1: Test** con server finto: la ricerca esclude gli stati chiusi e, con il flag, filtra la priorità (asserire il corpo della richiesta); paginazione della ricerca (200 + 5 elementi = 2 richieste); `tags` legge l'elenco; `addTag`/`removeTag` inviano metodo, percorso e corpo attesi; `users` pagina fino alla pagina non piena; Zammad che risponde 500 → `ZammadUnavailableException`; il token non compare mai nei log (verifica semplice sul testo dell'eccezione).
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest=NotificationZammadApiTest`.
- [ ] **Step 3: Implementare** con `java.net.http.HttpClient`, nello stile di `ZammadTicketSearch` (stessa gestione degli errori).
- [ ] **Step 4: Eseguire e vedere passare**.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): client Zammad per le email dei ticket`.

---

### Task 6: Invio e job dei ticket ad alta priorità

**Files:**
- Create: `.../notification/{NotificationMailer,HighPriorityNotifier,NotificationJobs}.java`
- Modify: `irccs-microservice-zammad/src/main/resources/application.properties` (proprietà `zammad.notifications.*` e `quarkus.mailer.*`)
- Test: `.../notification/{NotificationMailerTest,HighPriorityNotifierTest}.java`

**Interfaces:**
- Consumes: tutto dei Task 1-5; `org.quarkus.irccs.mail.EmailService.sendHtmlEmail(String to, String subject, String htmlBody)`.
- Produces:
  - `@ApplicationScoped public class NotificationMailer { public boolean send(String to, MailContent c); }` — `sendHtmlEmail`, vero se parte, falso se solleva (log del solo tipo di eccezione); pausa `zammad.notifications.send-pause` dopo ogni invio riuscito.
  - `@ApplicationScoped public class HighPriorityNotifier { public void runOnce(Instant now); }` — se `enabled` è falso ritorna subito; se `start-from` è vuoto o non valido scrive un ERROR e ritorna. Legge i ticket aperti ad alta priorità e i recentemente chiusi, gli utenti una volta, e per ogni ticket: tag → `TicketMarks.parse` → `TicketFacts` (`crfTicket` = `crfscope` diverso da `STUDY` e `patient` valorizzato; `highPriority` = `priority_id` 3) → `HighPriorityDecision.decide`. Per OPEN/CLOSE/REOPEN/REMIND: destinatari (`TicketRecipients`), `HighPriorityMailBuilder.build`, una mail per destinatario; se almeno una parte (o non ci sono destinatari, con WARN) si applicano i `TagChanges`; se tutte falliscono nessun tag. BASELINE: solo tag. Un errore su un ticket non ferma gli altri. Log finale con conteggi (controllati, mail inviate, fallite, saltati).
  - `@ApplicationScoped public class NotificationJobs { @Scheduled(every="{zammad.notifications.poll-interval}", concurrentExecution=SKIP) void highPriority(); }` che chiama `runOnce(Instant.now())`.
- Proprietà di default in `application.properties`: `zammad.notifications.enabled=${ZAMMAD_NOTIFICATIONS_ENABLED:false}`, `…poll-interval=${ZAMMAD_NOTIFICATIONS_POLL_INTERVAL:5m}`, `…reminder-interval=${ZAMMAD_NOTIFICATIONS_REMINDER_INTERVAL:3d}`, `…start-from=${ZAMMAD_NOTIFICATIONS_START_FROM:}`, `…close-lookback=${ZAMMAD_NOTIFICATIONS_CLOSE_LOOKBACK:7d}`, `…send-pause=${ZAMMAD_NOTIFICATIONS_SEND_PAUSE:200ms}`, `…ticket-url-template=${ZAMMAD_NOTIFICATIONS_TICKET_URL:}`, `…exclude-emails=${ZAMMAD_NOTIFICATIONS_EXCLUDE_EMAILS:}`; `quarkus.mailer.host=${SMTP_HOST:localhost}`, `…port=${SMTP_PORT:25}`, `…from=${MAIL_FROM:noreply-pj@istitutotumori.na.it}`, `…start-tls=DISABLED`, `…mock=${MAILER_MOCK:false}`, `%test.quarkus.mailer.mock=true`, `%dev.quarkus.mailer.mock=true`, e `quarkus.log.category."org.quarkus.irccs.mail.EmailService".level=WARN` (il modulo condiviso logga a INFO indirizzi e oggetto).

- [ ] **Step 1: Test** `NotificationMailerTest` (Mockito su `EmailService`, pausa 1 ms): invio riuscito → vero; `sendHtmlEmail` che solleva → falso senza eccezione. `HighPriorityNotifierTest` (mock di `NotificationZammadApi` e `NotificationMailer`; `now` e `startFrom` fissi): flag spento → nessuna lettura; `start-from` vuoto → nessuna lettura; ticket nuovo ad alta priorità creato dopo `startFrom` → tante mail quanti i membri dei gruppi coinvolti, poi `addTag(mail-apertura)` e `addTag(mail-ultimo-invio-…)`; **ticket creato prima di `startFrom` → nessuna mail, solo i due tag** (Review Focus 1); ticket con `mail-apertura` fermo da 3 giorni → sollecito ai gruppi coinvolti e a `opengroup`, tag sostituito; fermo da 2 giorni → niente; ticket con un messaggio recente → niente; ticket chiuso con `mail-apertura` → mail di chiusura e tag `mail-chiusura`, e una seconda esecuzione con gli stessi tag non manda nulla (Review Focus 2); ticket riaperto (non chiuso con `mail-chiusura`) → mail di riapertura, tolto `mail-chiusura`; **tutte le mail falliscono → nessun tag**; `addTag` che solleva `ZammadUnavailableException` su un ticket → gli altri ticket sono comunque trattati; news (`crfscope` `STUDY`) e priorità normale → nessuna mail; gruppo senza membri → WARN e tag scritto senza mail; i log non contengono `@` (catturare l'appender come nei test del repo).
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='NotificationMailerTest,HighPriorityNotifierTest'`.
- [ ] **Step 3: Implementare** `NotificationMailer`, `HighPriorityNotifier` (iniezioni da campo come nel resto del repo) e `NotificationJobs`; aggiungere le proprietà.
- [ ] **Step 4: Eseguire e vedere passare**, poi la suite intera `mvn -q -o test`.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): email dei ticket ad alta priorita' (apertura, chiusura, riapertura, sollecito)`.

---

### Task 7: Report settimanale (job)

**Files:**
- Create: `.../notification/WeeklyReportService.java`
- Modify: `.../notification/NotificationJobs.java` (job con cron), `application.properties` (`zammad.notifications.report-cron=${ZAMMAD_NOTIFICATIONS_REPORT_CRON:0 0 8 ? * MON}`)
- Test: `.../notification/WeeklyReportServiceTest.java`

**Interfaces:**
- Consumes: Task 2, 4, 5, 6 (`NotificationMailer`).
- Produces: `@ApplicationScoped public class WeeklyReportService { public void runOnce(Instant now, ZoneId zone); }` — se `enabled` è falso ritorna; legge i ticket di CRF aperti (`openTickets(false)`), `ReportPlanner.rowsByGroup`, gli utenti e le etichette dei gruppi; per ogni gruppo con righe: membri con `GroupMembers.emails` (senza esclusi), `WeeklyReportBuilder.build` e una mail per membro; un gruppo senza righe o senza membri non manda nulla; periodo = dal lunedì della settimana precedente alla domenica (`LocalDate` nel fuso indicato). Un errore su un gruppo non ferma gli altri; log con soli conteggi (gruppi, mail inviate, fallite). `NotificationJobs` aggiunge `@Scheduled(cron="{zammad.notifications.report-cron}", timeZone="Europe/Rome", concurrentExecution=SKIP) void weeklyReport()`.

- [ ] **Step 1: Test**: due gruppi con ticket → una mail per membro di ciascun gruppo, ognuno con le sue righe; un ticket a due gruppi compare nei report di entrambi; gruppo senza ticket aperti → nessuna mail; gruppo con ticket ma senza membri → nessuna mail e nessuna eccezione; utente di due gruppi → due mail (una per gruppo); indirizzo escluso → nessuna mail; flag spento → nessuna lettura; Zammad non disponibile → nessuna eccezione e nessuna mail; un invio fallito non ferma i successivi.
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest=WeeklyReportServiceTest`.
- [ ] **Step 3: Implementare** `WeeklyReportService` e il job con cron.
- [ ] **Step 4: Eseguire e vedere passare**, poi `mvn -q -o test` (suite intera) e `mvn -q -o -DskipTests package`.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): report settimanale dei ticket aperti`.

---

### Task 8: Configurazione, script di installazione e documentazione

**Files (repo `irccs-docker` e, con edit mirati, copia `git pascale/irccs-docker`):**
- Modify: `microservice-config-zammad/application.properties` (le stesse proprietà del Task 6/7 da variabili d'ambiente, con commento in italiano; `SMTP_HOST` di default `10.1.253.151`), `.env_example` (le variabili `ZAMMAD_NOTIFICATIONS_*`, `SMTP_HOST`, `SMTP_PORT`, `MAIL_FROM`), `docs/modules/ROOT/pages/ticket-crf.adoc` (sezione «Email»: cosa parte e quando, destinatari, tag, configurazione, come spegnere/accendere, limiti: un solo servizio, report saltato se il servizio è fermo)
- Create: `setup/install/disable_zammad_native_emails.sh`

**Interfaces:**
- `disable_zammad_native_emails.sh`: `ZAMMAD_TOKEN=<token> ./disable_zammad_native_emails.sh <ZAMMAD_URL> [--apply]` — senza `--apply` elenca solo cosa disattiverebbe. Disattiva (`PUT active:false`) i trigger `Ticket - conferma apertura al cliente`, `Ticket - cambio assegnatario (gruppo)`, `Ticket - apertura (gruppo)`, `Ticket - modifica (gruppo)`, `Ticket - chiusura (gruppo)` e i job `Ticket - sollecito dopo 2 giorni senza risposta` e `Ticket - promemoria giornaliero in attesa di risposta`; **non** tocca `Ticket - presa in carico alla risposta`. Idempotente, esce con errore al primo HTTP non riuscito, il token non compare in output.

- [ ] **Step 1:** aggiungere le proprietà alla configurazione montata e le variabili a `.env_example`; non cambiare le voci esistenti.
- [ ] **Step 2:** scrivere lo script con la logica «elenca / applica» e controllo di esistenza; `bash -n` pulito.
- [ ] **Step 3:** scrivere la sezione «Email» in `ticket-crf.adoc` con le variabili, il comando di attivazione in ordine (1. ms con `ENABLED=false`; 2. `START_FROM` = data di attivazione e `ENABLED=true`; 3. `disable_zammad_native_emails.sh --apply`) e il comando di spegnimento di emergenza (`ENABLED=false`).
- [ ] **Step 4:** riportare gli stessi file nella copia di produzione con modifiche mirate (non toccare `.env` né configurazioni non correlate).
- [ ] **Step 5:** provare `disable_zammad_native_emails.sh` **senza `--apply`** contro Zammad di prova (mai `--apply` contro `pj-tk` in questa fase): deve elencare i sette elementi e non toccare nulla.
- [ ] **Step 6: Commit** (solo su richiesta): `chore(zammad): configurazione e installazione delle email dei ticket`.

---

### Task 9: Prova su staging e attivazione (solo con l'OK esplicito dell'utente)

- [ ] **Step 1:** installare il ms su staging (immagine delta come nella procedura di staging, tag di rollback prima), con `ENABLED=false`: verificare che parta e che i job non facciano nulla.
- [ ] **Step 2:** su staging il relay SMTP non c'è: impostare `MAILER_MOCK=true`, `ENABLED=true`, `START_FROM` = ora, creare un ticket di prova ad alta priorità nel gruppo 17 (solo l'utente di prova come membro) e controllare nei log: mail di apertura (conteggio), tag `mail-apertura` e `mail-ultimo-invio-…` sul ticket (`GET tags`), nessun doppione al giro dopo; chiuderlo e controllare chiusura e tag; riaprirlo e controllare riapertura. Forzare il report con un cron ravvicinato (`ZAMMAD_NOTIFICATIONS_REPORT_CRON`) e controllare una mail per membro con la tabella.
- [ ] **Step 3: Passaggio in produzione** — solo dopo l'OK dell'utente: `START_FROM` = data di attivazione con `ENABLED=true`, poi `disable_zammad_native_emails.sh --apply`; verificare nel log il giro con soli conteggi e che nessun ticket già aperto abbia ricevuto una mail di apertura.
- [ ] **Step 4:** annotare l'esito nel documento di progetto («Stato») e i tag di rollback usati.
