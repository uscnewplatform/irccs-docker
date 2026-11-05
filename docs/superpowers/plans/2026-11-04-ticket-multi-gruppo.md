# Ticket a più gruppi, promotore e centro — Piano di realizzazione

> **Per chi esegue:** SOTTO-SKILL OBBLIGATORIA: `superpowers:subagent-driven-development` (consigliata) oppure `superpowers:executing-plans`. I passi usano la sintassi a caselle `- [ ]`.

**Obiettivo:** un ticket di CRF può essere indirizzato a più gruppi (centro del paziente e/o promotore dello studio) con una conversazione unica; la visibilità e la chiusura le decide il microservizio.

**Architettura:** un solo ticket Zammad; `group_id` = gruppo primario, e tre/quattro attributi personalizzati (`targetgroups`, `openedby`, `opengroup`, `sponsororg`) portano i gruppi coinvolti, chi ha aperto e il promotore. `TicketAccessPolicy` tratta `{group_id} ∪ targetgroups` come «gruppi del ticket». Nuovo endpoint `GET tickets/ticket-targets` per il dialogo; `groups-for-patient` resta com'è.

**Stack:** Java 21 / Quarkus 3.19 (`irccs-microservice-zammad`), React/TypeScript/MUI/TanStack Query (`irccs-react-dashboard`), Zammad 7.2 REST, bash/curl e Python per gli script di `irccs-docker`.

**Spec:** `irccs-docker/docs/superpowers/specs/2026-11-04-ticket-multi-gruppo-design.md`

## Global Constraints

- Gruppi selezionabili: **apre il promotore** → solo gruppi del centro del paziente (uno, più o tutti); **apre un centro non promotore** → gruppi del proprio centro (= centro del paziente) e/o gruppi del promotore. **Almeno un gruppo.** Gruppi inattivi e `annunci_*` esclusi (`PatientCentreGroups.isAnnouncementGroup`).
- Conversazione unica; i gruppi coinvolti restano quelli scelti all'apertura (nessuna aggiunta/rimozione). «Tutti i gruppi del centro» = snapshot all'apertura.
- Chiusura: capability `internal:close:ticket` **e** il chiamante vede il ticket; se `openedby = SPONSOR` il chiamante deve appartenere all'organizzazione promotore dello studio del paziente; se `openedby = CENTRE` o assente vale solo capability + visibilità. Chi apre/risponde da solo non chiude (regola esistente).
- Promotore = `ResearchStudy.sponsor` dello studio del **ticket**; studio non ricavabile, senza `sponsor` o ambiguo → nessun gruppo del promotore e `openedby = CENTRE` (nessun 403).
- «Appartiene al promotore» = l'organizzazione radice del gruppo attivo di chi chiama (gruppo Zammad con `keycloak_ref` = id Keycloak del gruppo attivo → suo `organization`) coincide con quella del promotore. Il gruppo attivo va preso da `CallerScope` (verificato), mai dal solo header.
- Primario = primo gruppo scelto nell'ordine canonico (prima i gruppi del centro, poi quelli del promotore). Se Zammad non lascia creare all'utente nel gruppo primario si crea con l'identità di servizio (`forwardPost(body, null)`, già così).
- `targetgroups` si salva come `|12|34|` (barre ai due estremi) e si cerca con la condizione «contiene `|12|`».
- Ticket senza gli attributi nuovi (esistenti): comportamento di oggi, nessuna modifica. Il blocco «Conferma CRF» non cambia.
- Nomi attributi: `targetgroups`, `openedby`, `opengroup`, `sponsororg` (niente suffisso `_id`/`_ids`, niente `scope`).
- Commenti e log in italiano; log senza nomi, email, testi; stile dei file vicini. Nessun commit finché l'utente non lo chiede; branch `feature/PASTRL-<n>` (numero da chiedere all'utente), PR aperta dalla CI.
- Traduzioni dashboard in italiano, inglese, tedesco e francese (`public/locales/{it,en,de,fr}/translation.json`), mai stringhe fisse.

## Review Focus

- Un gruppo che non è fra quelli ammessi (altro centro, gruppo del promotore per chi è già promotore, gruppo inattivo): **403**, anche se il client lo manda.
- Selezione vuota → **422**; id ripetuti → deduplicati; id non numerici → 400/422.
- Promotore non ricavabile (studio mancante, `sponsor` assente, nessun legame paziente-studio): solo gruppi del centro, `openedby = CENTRE`, nessuna eccezione.
- Gruppo attivo non verificato / header falsificato: non si diventa «promotore» dichiarandolo; superadmin senza gruppo attivo non apre.
- `|12|` contro `|112|`: un gruppo 12 non vede un ticket indirizzato solo al 112.
- Ticket vecchi (senza attributi) e ticket a un solo gruppo: lettura, scrittura, chiusura e blocco «Conferma CRF» identici a prima.
- Combinazioni di chiusura: capability senza visibilità, visibilità senza capability, `SPONSOR` chiuso da un centro, `CENTRE` chiuso da un gruppo del promotore coinvolto.

---

### Task 1: Regole pure dei gruppi destinatari

**Files:**
- Create: `irccs-microservice-zammad/src/main/java/org/quarkus/microservice/irccs/zammad/ticketgroups/{OpenedBy,GroupRef,TargetOptions,TicketTargets}.java`
- Test: `irccs-microservice-zammad/src/test/java/org/quarkus/microservice/irccs/zammad/ticketgroups/TicketTargetsTest.java`

**Interfaces:**
- Produces:
  - `public enum OpenedBy { SPONSOR, CENTRE }`
  - `public record GroupRef(long id, String name, String label)`
  - `public record TargetOptions(OpenedBy openedBy, List<GroupRef> centre, List<GroupRef> sponsor)`
  - `public final class TicketTargets` con: `static TargetOptions options(boolean callerInSponsor, List<GroupRef> centreGroups, List<GroupRef> sponsorGroups)`; `static Selection select(TargetOptions o, List<Long> requested)` con `public record Selection(List<Long> ordered, String error)` (`error` null se ok, altrimenti `"EMPTY"` o `"NOT_ALLOWED"`); `static String encode(List<Long> ids)`; `static List<Long> decode(String raw)`.
- Regole: `callerInSponsor` → `openedBy = SPONSOR`, `centre = centreGroups`, `sponsor = []`. Altrimenti `CENTRE`, `centre = centreGroups`, `sponsor = sponsorGroups` senza i gruppi già presenti in `centre` (stessa organizzazione); `sponsorGroups` vuoto = nessun gruppo del promotore. `select`: dedup, ordine canonico (centre poi sponsor), vuoto → `EMPTY`, qualunque id fuori da `centre ∪ sponsor` → `NOT_ALLOWED`. `encode([12,34])` = `"|12|34|"`; `decode` di vuoto/nullo/malformato = `[]`.

- [ ] **Step 1: Test** `TicketTargetsTest` con: `promotoreVedeSoloGruppiDelCentro`; `centreVedeCentroEPromotore`; `stessaOrganizzazioneNonDuplicaIGruppi`; `senzaPromotoreSoloCentro`; `selezioneInOrdineCanonicoPrimarioPerPrimo` (richiesti `[30,10]` con centre `[10,20]`, sponsor `[30]` → `[10,30]`); `selezioneVuota` (`EMPTY`); `gruppoFuoriElenco` (`NOT_ALLOWED`); `duplicatiRimossi`; `encodeDecodeRoundTrip` (`"|12|34|"`, e `decode("|112|")` ≠ contiene 12); `decodeMalformatoVuoto` (`"abc"`, `"|x|"`, `null`, `""`).
- [ ] **Step 2: Eseguire e vedere fallire** — `cd irccs-microservice-zammad && mvn -q -o test -Dtest=TicketTargetsTest` — errore di compilazione.
- [ ] **Step 3: Implementare** i tipi e `TicketTargets` come da Interfaces (funzioni pure, nessun I/O).
- [ ] **Step 4: Eseguire e vedere passare** — atteso `Failures: 0`.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): regole dei gruppi destinatari dei ticket`.

---

### Task 2: Studio, promotore e organizzazione del chiamante

**Files:**
- Modify: `.../service/PatientCentreGroups.java` (espone la risalita al centro e i gruppi di un'organizzazione)
- Create: `.../ticketgroups/StudySponsorResolver.java`, `.../ticketgroups/CallerOrganization.java`
- Test: `.../service/PatientCentreGroupsTest.java` (estendere), `.../ticketgroups/StudySponsorResolverTest.java`, `.../ticketgroups/CallerOrganizationTest.java`

**Interfaces:**
- Produces:
  - `PatientCentreGroups`: `public String centreRootId(String patient)` (null se non riconoscibile; stessa logica di `centreKeycloakId`) e `public List<Option> forOrganization(String rootId)` (gruppi attivi non `annunci_*` con `organization` uguale a `rootId`, ordinati per etichetta); `forPatient(patient)` resta e li usa.
  - `@ApplicationScoped public class StudySponsorResolver { public Optional<String> sponsorRootId(String patientId, String studyId); }` — verifica il legame con `ResearchSubject?individual=Patient/{patientId}&study=ResearchStudy/{studyId}` (almeno una voce), poi legge `ResearchStudy.sponsor` → `Organization` → primo `identifier` in forma UUID (come `centreKeycloakId`). Qualunque assenza o errore → `Optional.empty()`, con log del solo tipo di eccezione.
  - `@ApplicationScoped public class CallerOrganization { public Optional<String> rootId(); }` — gruppo attivo verificato dal contesto del chiamante (`CallerScope(jwt, headers)`, primo id di `activeGroupIds()`; vuoto per il superadmin senza gruppo attivo), poi gruppo Zammad con `keycloak_ref` uguale (da `ZammadClient.getGroups()`) e suo `organization`.
- Consumes: `FhirClient<ResearchStudy>`, `FhirClient<ResearchSubject>` o equivalente di ricerca già in uso nel modulo `i3-client`; `FhirClient<Organization>`; `ZammadClient.getGroups()`.

- [ ] **Step 1: Verificare il modello dei dati su un ambiente reale** (pascale-local o staging, sola lettura, `curl` su HAPI): che `ResearchSubject?individual=Patient/<id>&study=ResearchStudy/<id>` restituisca il legame paziente-studio. Annotare nel report il comando e l'esito. Se il legame è modellato in un altro modo, **fermarsi** e riportare NEEDS_CONTEXT con il modello trovato.
- [ ] **Step 2: Test** — `StudySponsorResolverTest` (Mockito): legame presente + sponsor con UUID → UUID; nessun `ResearchSubject` → vuoto; `sponsor` assente → vuoto; Organization senza identifier UUID → vuoto; eccezione FHIR → vuoto. `CallerOrganizationTest`: gruppo attivo trovato → `organization` del gruppo; nessun gruppo attivo (superadmin) → vuoto; gruppo Zammad non trovato → vuoto. `PatientCentreGroupsTest`: `forOrganization` filtra attivi, esclude `annunci_*`, ordina per etichetta; `centreRootId` null senza `managingOrganization`.
- [ ] **Step 3: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='PatientCentreGroupsTest,StudySponsorResolverTest,CallerOrganizationTest'`.
- [ ] **Step 4: Implementare** le firme di Interfaces.
- [ ] **Step 5: Eseguire e vedere passare**, poi `mvn -q -o test` (suite intera, nessuna regressione).
- [ ] **Step 6: Commit** (solo su richiesta): `feat(zammad): promotore dello studio e organizzazione del chiamante`.

---

### Task 3: Endpoint `ticket-targets` e creazione a più gruppi

**Files:**
- Create: `.../ticketgroups/TicketTargetsService.java`
- Modify: `.../controller/ZammadTicketApiController.java` (nuovo `GET /ticket-targets`)
- Modify: `.../service/TicketGuard.java` (nuovi campi di creazione `study`, `target_group_ids`; rifiuto di `targetgroups`/`openedby`/`opengroup`/`sponsororg` dal client)
- Modify: `.../service/ZammadAttributeService.java` (`public boolean hasTicketAttribute(String name)`, gli attributi nuovi **non** in `REQUIRED_TICKET_ATTRIBUTES`)
- Modify: `.../service/ZammadTicketService.java` (`createTicket`: percorso a più gruppi)
- Test: `.../ticketgroups/TicketTargetsServiceTest.java`, `.../service/TicketGuardCreateTest.java`, `.../service/ZammadTicketServiceHttpTest.java`

**Interfaces:**
- Consumes: `TicketTargets`, `StudySponsorResolver`, `CallerOrganization`, `PatientCentreGroups` (Task 1-2), `PatientVisibility.canSee`.
- Produces:
  - `@ApplicationScoped public class TicketTargetsService { public TargetOptions optionsFor(String patient, String study); public String sponsorRoot(String patient, String study); }` — centro = `centreRootId(patient)` → `forOrganization`; promotore = `StudySponsorResolver.sponsorRootId`; `callerInSponsor` = `CallerOrganization.rootId()` uguale al promotore ricavato (se il promotore non c'è: falso e nessun gruppo promotore).
  - `GET /fhir/zammad/tickets/ticket-targets?patient=&study=` → 200 `{ "openedBy": "SPONSOR|CENTRE", "centre": [{id,name,label}], "sponsor": [...] }`; paziente non visibile → 403; Zammad o FHIR non disponibili → 503; parametri non validi → 400.
  - Creazione: se il corpo contiene `target_group_ids` (array di interi, 1-50, non `group_id`) il percorso è nuovo: richiede ambito CRF e `study`; calcola le opzioni, `TicketTargets.select`; `EMPTY` → 422, `NOT_ALLOWED` → 403; imposta `group_id` = primo, `targetgroups = encode(ordered)`, `openedby`, `opengroup` (gruppo Zammad del gruppo attivo di chi apre, se noto), `sponsororg` (promotore, se noto). Se uno degli attributi nuovi non esiste su Zammad → 503 «installazione incompleta». Con `group_id` e senza `target_group_ids` il percorso resta quello di oggi, invariato.

- [ ] **Step 1: Test del servizio** (`TicketTargetsServiceTest`): promotore che apre → `SPONSOR`, solo `centre`; centro che apre con promotore ricavato → `CENTRE`, `centre` + `sponsor`; promotore non ricavabile → `CENTRE` con `sponsor` vuoto; centro del paziente coincidente col promotore → nessun doppione; chiamante senza gruppo attivo → mai `SPONSOR`.
- [ ] **Step 2: Test di creazione** (`ZammadTicketServiceHttpTest`, stile dei test esistenti): selezione valida a due gruppi → il body inoltrato a Zammad ha `group_id` primario, `targetgroups = "|a|b|"`, `openedby`, `opengroup`; gruppo fuori elenco → 403 e nessuna chiamata di creazione; selezione vuota → 422; attributo mancante su Zammad → 503; senza `target_group_ids` il body inoltrato è identico a prima (regressione); `TicketGuardCreateTest.attributiGestitiDalServerRifiutatiDalClient` per `targetgroups`/`openedby`/`opengroup`/`sponsororg`.
- [ ] **Step 3: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='TicketTargetsServiceTest,TicketGuardCreateTest,ZammadTicketServiceHttpTest'`.
- [ ] **Step 4: Implementare** `TicketTargetsService`, l'endpoint, le validazioni di `TicketGuard`, `hasTicketAttribute` e il percorso a più gruppi in `createTicket` (dopo visibilità e prima di `forwardPost`).
- [ ] **Step 5: Eseguire e vedere passare**, poi `mvn -q -o test`.
- [ ] **Step 6: Commit** (solo su richiesta): `feat(zammad): creazione di ticket a più gruppi e endpoint ticket-targets`.

---

### Task 4: Visibilità, scrittura e chiusura sui gruppi del ticket

**Files:**
- Modify: `.../service/TicketAccessPolicy.java` (`grants` sull'insieme dei gruppi del ticket)
- Create: `.../ticketgroups/TicketClosePolicy.java`
- Modify: `.../service/TicketThreadService.java` (righe che chiamano `closeAuthority.canClose()`: `canClose` nella conversazione, `close`, `reopen`, riga di elenco) e `.../service/ZammadTicketService.java` (`updateTicket` con `state_id` di chiusura)
- Test: `.../service/TicketAccessPolicyTest.java`, `.../ticketgroups/TicketClosePolicyTest.java`, `.../service/TicketThreadServiceTest.java`, `.../service/ZammadTicketServiceHttpTest.java`

**Interfaces:**
- Produces:
  - `TicketAccessPolicy.groupsOf(JsonNode ticket)` → `Set<Long>` = `{group_id} ∪ TicketTargets.decode(targetgroups)`; `canRead`/`canWrite`/`canSeeInternal` usano l'insieme (permessi `READ`/`WRITE` esistenti su uno qualunque dei gruppi); senza `targetgroups` il risultato è quello di oggi.
  - `public final class TicketClosePolicy { public static boolean canClose(boolean hasCapability, boolean canRead, String openedBy, boolean callerInSponsorOrg); }` — `true` solo se `hasCapability && canRead && (openedBy != "SPONSOR" || callerInSponsorOrg)`.
  - L'organizzazione del promotore del ticket è `sponsororg` del ticket; `callerInSponsorOrg` = `CallerOrganization.rootId()` uguale a `sponsororg`; `sponsororg` assente con `openedby = SPONSOR` = `false` (fail-closed).

- [ ] **Step 1: Test** — `TicketAccessPolicyTest`: ticket con `targetgroups "|5|7|"`, chiamante con `read` solo sul 7 → legge; con `create` sul 7 → non legge; `|112|` non è visibile a chi ha il gruppo 12; ticket senza `targetgroups` come prima. `TicketClosePolicyTest`: tabella completa (capability sì/no × visibilità sì/no × `SPONSOR`/`CENTRE`/assente × in-promotore sì/no): le righe richieste dal vincolo di chiusura, più `SPONSOR` con `sponsororg` mancante = `false`. `TicketThreadServiceTest`/`ZammadTicketServiceHttpTest`: chiusura di un ticket `SPONSOR` da un chiamante del centro con capability → 403; `CENTRE` chiuso da un chiamante del gruppo del promotore coinvolto con capability → 200; ticket vecchio chiuso con capability → 200 come oggi.
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='TicketAccessPolicyTest,TicketClosePolicyTest,TicketThreadServiceTest,ZammadTicketServiceHttpTest'`.
- [ ] **Step 3: Implementare** `groupsOf`, `TicketClosePolicy` e il collegamento nei punti indicati (la decisione sul singolo ticket sostituisce la sola `closeAuthority.canClose()`, che resta la fonte della capability).
- [ ] **Step 4: Eseguire e vedere passare**, poi `mvn -q -o test`.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): visibilità e chiusura dei ticket a più gruppi`.

---

### Task 5: Ricerca dei ticket e gruppi nelle risposte

**Files:**
- Modify: `.../service/ZammadTicketService.java` (`forwardGetMyTicket`, `listMine`)
- Modify: `.../service/TicketThreadService.java` (campo `groups` nella conversazione e nelle righe)
- Create: `.../ticketgroups/TicketGroupLabels.java`
- Test: `.../service/ZammadTicketServiceHttpTest.java`, `.../service/TicketThreadServiceTest.java`, `.../ticketgroups/TicketGroupLabelsTest.java`

**Interfaces:**
- `forwardGetMyTicket`: oltre a `customer_id`, `owner_id`, `group_id`, una condizione per ciascuno dei gruppi leggibili (massimo 40) `ticket.targetgroups` «contains» `"|<id>|"`; i risultati si uniscono senza doppioni (come già avviene) e poi passano da `filterReadable`.
- `public final class TicketGroupLabels { public static List<String> labels(JsonNode ticket, Map<Long,String> labelsById); }` — etichette dei gruppi coinvolti, nell'ordine di `targetgroups`; senza `targetgroups` il solo `group_id`; id sconosciuti saltati. Le mappe id→etichetta vengono da `ZammadClient.getGroups()` con `PatientCentreGroups.label`.
- Le righe di «I miei ticket» e la conversazione espongono `groups: ["<etichetta>", ...]` (aggiunta, nessun campo tolto).

- [ ] **Step 1: Test** — un ticket indirizzato a `|5|7|` compare nell'elenco di chi legge solo il gruppo 7 (la ricerca fittizia restituisce il ticket sulla condizione `targetgroups`); un ticket con soli `group_id` come prima; `TicketGroupLabelsTest` (ordine, ripiego su `group_id`, id sconosciuto); la conversazione riporta `groups`.
- [ ] **Step 2: Eseguire e vedere fallire** — `mvn -q -o test -Dtest='ZammadTicketServiceHttpTest,TicketThreadServiceTest,TicketGroupLabelsTest'`.
- [ ] **Step 3: Implementare** come da Interfaces.
- [ ] **Step 4: Eseguire e vedere passare**, poi `mvn -q -o test`.
- [ ] **Step 5: Commit** (solo su richiesta): `feat(zammad): ricerca per gruppi coinvolti e gruppi nelle risposte`.

---

### Task 6: Installazione Zammad e Keycloak, documentazione

**Files (repo `irccs-docker` e, con edit mirati, copia `git pascale/irccs-docker`):**
- Modify: `setup/install/install_zammad_attributes.sh` (4 attributi `Ticket`: `targetgroups` input 500, `openedby` input 20, `opengroup` input 20, `sponsororg` input 40; opzionali nella verifica; nascosti in modifica come `crfscope`)
- Modify: `keycloak-config/add-zammad-authz.py` (risorsa `TicketTargets <t> Resource` su `base + "/ticket-targets"`, GET, permesso `read`)
- Modify: `docs/modules/ROOT/pages/ticket-crf.adoc` (regole nuove, endpoint, attributi, chiusura per promotore/centro)

- [ ] **Step 1:** aggiungere i 4 attributi seguendo le righe `crea_attributo Ticket crfscope …`; `bash -n` pulito.
- [ ] **Step 2:** aggiungere risorsa e permesso nello stile di `Mine`; `python3 -I -m py_compile keycloak-config/add-zammad-authz.py`.
- [ ] **Step 3:** aggiornare `ticket-crf.adoc` (sezione Gruppo destinatario, tabella endpoint con `/ticket-targets`, attributi, regole di chiusura).
- [ ] **Step 4:** riportare gli stessi file nella copia di produzione con modifiche mirate (non toccare `.env` né altri file non correlati).
- [ ] **Step 5:** eseguire gli script due volte contro lo Zammad/Keycloak di prova locale (`pascale-local`): la seconda esecuzione non crea nulla di nuovo. Mai contro `pj-tk`.
- [ ] **Step 6: Commit** (solo su richiesta): `chore(zammad): attributi e autorizzazione dei ticket a più gruppi`.

---

### Task 7: Dashboard — scelta dei gruppi e visualizzazione

**Files:**
- Create: `irccs-react-dashboard/src/fhir/service/Ticket/ticketTargetsModel.ts`, `ticketTargetsModel.test.ts`, `irccs-react-dashboard/src/fhir/front-office/components/Crf/TicketTargetsSelect.tsx`
- Modify: `src/fhir/service/Ticket/TicketThreadService.ts` (tipo e client `listTicketTargets`), `src/fhir/front-office/components/Crf/NewTicketDialog.tsx`, `src/fhir/front-office/components/Crf/CrfTherapyRenderer.tsx` (stato e invio), il pannello/elenco dei ticket per mostrare i gruppi coinvolti (`TicketDrawer` e `MyTicketsPage`), `public/locales/{it,en,de,fr}/translation.json`

**Interfaces:**
- Produces:
  - `export interface TicketTargetOption { id: number; name: string; label: string }`, `export interface TicketTargets { openedBy: "SPONSOR" | "CENTRE"; centre: TicketTargetOption[]; sponsor: TicketTargetOption[] }`; `export async function listTicketTargets(patientId: string, studyId: string): Promise<TicketTargets>` su `GET zammad/tickets/ticket-targets`.
  - Modello puro in `ticketTargetsModel.ts`: `selectedIds(sel: Set<number>, t: TicketTargets): number[]` (ordine canonico centro poi promotore), `toggleAll(sel, options, on: boolean): Set<number>`, `allSelected(sel, options): boolean`, `canSend(sel): boolean` (almeno uno).
  - `TicketTargetsSelect` — spunte con «Tutti i gruppi del centro» in testa alla sezione del centro (scorciatoia); la sezione «Gruppi del promotore» compare solo se `sponsor` non è vuota; props `{ patientId, studyId, value: Set<number>, onChange(next: Set<number>): void, disabled?: boolean }`; se esiste un solo gruppo è già selezionato.
  - Il corpo di creazione manda `target_group_ids` (da `selectedIds`) e `study` (id del `ResearchStudy` del percorso paziente già noto alla pagina) **al posto** di `group_id`; il resto invariato.
- Test del modello (vitest): `selectedIds` in ordine canonico; `toggleAll` accende/spegne tutto il centro senza toccare il promotore; `allSelected` vero solo con tutti; `canSend` falso a vuoto.

- [ ] **Step 1: Test** `ticketTargetsModel.test.ts` come sopra.
- [ ] **Step 2: Eseguire e vedere fallire** — `cd irccs-react-dashboard && npx vitest run src/fhir/service/Ticket/ticketTargetsModel.test.ts`.
- [ ] **Step 3: Implementare** modello, servizio, `TicketTargetsSelect`, `NewTicketDialog` e `CrfTherapyRenderer` (stato `Set<number>` al posto di `ticketGroupOwner`; `canSend` richiede almeno un gruppo).
- [ ] **Step 4:** mostrare i `groups` (chip con le etichette) nella conversazione e in «I miei ticket»; aggiungere le chiavi in 4 lingue; JSON valido (`node -e "JSON.parse(require('fs').readFileSync('public/locales/it/translation.json','utf8'))"` per ciascuna).
- [ ] **Step 5: Eseguire e vedere passare** — `npx vitest run src/fhir/service/Ticket src/pages` e `npx tsc --noEmit -p . 2>&1 | grep -E "Ticket|MyTickets|CrfTherapyRenderer"` senza nuovi errori (gli errori già esistenti non contano).
- [ ] **Step 6: Commit** (solo su richiesta): `feat(ticket): scelta di più gruppi destinatari nel nuovo ticket`.

---

### Task 8: Prova end-to-end e verifica su staging

**Files:**
- Create: `irccs-docker/setup/test/e2e_ticket_multigroup.py` (stile di `e2e_ticket_roles.py`; accanto agli altri `e2e_ticket_*.py`)

- [ ] **Step 1:** lo script (variabili `E2E_*` come gli altri) verifica sul server: promotore apre a tutti i gruppi del centro → il ticket compare ai membri di ciascun gruppo e a nessun altro; centro non promotore apre al proprio gruppo e a un gruppo del promotore → idem; gruppo non ammesso → 403; selezione vuota → 422; chiusura: `SPONSOR` chiuso dal centro con capability → 403, dal promotore con capability → 200; `CENTRE` chiuso da un gruppo del promotore coinvolto con capability → 200; ticket vecchio a un gruppo invariato.
- [ ] **Step 2: Installazione su staging** (solo con l'OK esplicito dell'utente): attributi (Task 6), Keycloak (`add-zammad-authz.py`), microservizio e dashboard come nella procedura di staging delle note di progetto; tag di rollback prima di ricreare i container, uno alla volta.
- [ ] **Step 3: Verifica del legame paziente-studio sui dati reali** (Task 2, Step 1): se `ResearchSubject` non è il modello in uso, correggere `StudySponsorResolver` prima di dare il lavoro per concluso; senza promotore ricavato la funzione degrada a «solo centro» senza errori, quindi **va verificata esplicitamente** con un paziente di un centro non promotore.
- [ ] **Step 4:** riportare nel documento di progetto («Stato») l'esito, i comandi eseguiti e i tag di rollback; committare e fare PR solo se l'utente lo chiede.
