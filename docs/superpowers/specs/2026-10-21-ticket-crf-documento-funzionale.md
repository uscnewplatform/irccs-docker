# Documento funzionale: ticket Zammad per CRF e blocco "Conferma CRF"

Data: 2026-10-21. Stato: approvato dall'utente (decisioni 1-8 del piano v2 accettate). Piano di riferimento: `docs/superpowers/plans/2026-10-21-ticket-drawer-crf-piano.md`.
Questo documento descrive **cosa fare, passo per passo**, dalla Fase 0 al rilascio. Non contiene codice.

> **v1.1 (2026-10-21):** recepita la revisione tecnica esterna. La sezione **12** integra e, dove in conflitto, **prevale** sulle sezioni 1-11 (consistenza Zammad/HAPI, chiave CRF canonica, mapping stati, override, inventario scrittori `completed`, criteri di go-live).

---

## 1. Obiettivo e regole di business

1. Data manager e sperimentatori aprono ticket (Zammad) su una CRF compilata.
2. **Una CRF non si puo' confermare se ha ticket non chiusi.** Il blocco e' applicato dal server, non solo dal bottone.
3. Gli utenti leggono e rispondono ai ticket di una CRF in un pannello dentro la piattaforma, senza passare da Zammad.
4. I ticket di studio (annunci) restano gestibili ma non bloccano mai nessuna conferma.

### Regole fissate
| Regola | Valore |
|---|---|
| Stati che bloccano | new, open, pending reminder, pending close |
| Stati che sbloccano | closed, merged |
| Granularita' | singola CRF, identificata da Questionnaire + CarePlan + Paziente (e `QuestionnaireResponse` quando esiste). Un ticket su una ripetizione di gruppo blocca la CRF intera |
| Ticket di studio | `crfscope=STUDY`, mai bloccanti |
| Zammad non raggiungibile | il blocco non ne dipende (legge HAPI) |
| HAPI non raggiungibile / esito indeterminato | la conferma fallisce (fail-closed) |
| Override | ruolo dedicato, motivazione obbligatoria, registrato in audit |
| Chi chiude un ticket | chi l'ha aperto, il DM del centro, il responsabile. Chi risponde non lo chiude da solo |
| Chi riapre | chi l'ha aperto e il DM |
| CRF gia' confermata + nuovo ticket | il ticket si puo' aprire, **non** riapre la CRF; evento di audit "ticket dopo conferma"; segnalato nel pannello |
| SAE | escluse dal blocco ticket (hanno il loro lock con `sae-query`) |
| `/certify` | da valutare in Fase 1 (vedi passo 1.9) |
| Rilascio | flag spento, attivazione per studio |

---

## 2. Attori e ruoli

- **Sperimentatore / Data manager (DM):** apre, legge, risponde, chiude secondo le regole sopra.
- **DM responsabile:** ruolo con diritto di chiusura forzata e di override del blocco (`internal:override:ticket-gate`).
- **Utente con `internal:confirm:crf`:** puo' premere "Conferma CRF" (se non ci sono ticket bloccanti).
- **Agent Zammad:** continua a lavorare dall'interfaccia Zammad; i suoi cambi arrivano alla piattaforma via webhook.
- **Servizio:** ms Zammad (unico che parla con Zammad e scrive i `Task` ticket-ref), `irccs-common` (blocco), dashboard.

---

## 3. Architettura in una pagina

```
Dashboard ──► ms zammad ──► Zammad (contenuti, messaggi, allegati)
                 │   ▲
                 │   └── webhook (HMAC) + riconciliazione periodica
                 ▼
         HAPI: Task "ticket-ref" (SOLO stato, nessun testo)
                 ▲
   irccs-common: enforceCrfConfirmation ─ cerca Task aperti per la CRF ─► 409 / ok
```

- Il browser **non parla mai con Zammad**.
- Il testo dei ticket e gli allegati restano **solo in Zammad**.
- In HAPI c'e' un `Task` per ticket collegato a una CRF, con solo identificativo e stato.

---

## 4. Prerequisiti (prima della Fase 0)

| # | Azione | Output |
|---|---|---|
| P1 | Mettere in sicurezza i lavori non committati su branch: `crf-query` (zammad), `crf-check-query` (common). Verificare anche `sae-dm-confirm-*` (gia' committati) e `rework-manuale` (dashboard). **Un branch per repo, nessun push senza richiesta** | branch locali con il lavoro |
| P2 | Decidere l'**ordine di merge** su `QuestionnaireResponseFlow.enforceCrfConfirmation` tra `sae-dm-confirm`, crf-check e questo lavoro. Proposta: sae-dm-confirm -> crf-check -> blocco ticket; rebase di `crf-check-query` su develop | ordine scritto nel ledger |
| P3 | Spike (0,5 gg) su **Zammad 7.2.2 locale** (pascale-local): come configurare webhook con HMAC, quali trigger su create/update/close, payload con attributi custom (`crf`, `careplan`, `patient`), ricerca per attributi custom. **Mai sul Zammad infocube reale** | nota con esiti e payload d'esempio |
| P4 | Ricostruire le spec A/B/C del 12/10 (oggi mancanti) dai ledger `.superpowers/sdd/...` e dalla memoria | file in `docs/superpowers/specs` |
| P5 | Checklist di regressione scritta (sez. 9) prima di toccare i flussi esistenti | checklist |

---

## 5. Fase 0 — Messa in sicurezza del ms Zammad (4-6 gg)

Obiettivo: nessun nuovo endpoint finche' i ticket non sono protetti.

| Passo | Cosa fare | Verifica |
|---|---|---|
| 0.1 | Partire dal worktree `crf-query`. Rileggere `TicketAccessPolicy`, `TicketGuard`, `ZammadCallerService` e riportarli sul branch `develop` corrente (rebase) | build verde |
| 0.2 | **Identita' stabile dell'utente.** Il chiamante Zammad si risolve dal JWT con un identificativo stabile (subject Keycloak salvato sull'utente Zammad o `login`), non dall'email. Se l'utente non esiste in Zammad: 403, mai fallback al token di servizio | test: email riusata/non verificata non impersona |
| 0.3 | Nessun header del client inoltrato a Zammad (ne' POST ne' PUT). `X-On-Behalf-Of` si costruisce solo lato server dall'identita' del punto 0.2 | test HTTP mock sugli header in uscita |
| 0.4 | Autorizzazione per ticket: lettura/scrittura solo come parte in causa (customer/owner) o con permesso `read`/`change`/`full` sul gruppo Zammad del ticket. Permessi vuoti = nessun accesso (fail-closed). `overview`/`create` da soli non danno lettura | test policy |
| 0.5 | `PUT` ticket con whitelist campi (`state_id`, `priority_id`, `pending_time`) e transizioni di stato ammesse; `DELETE` ticket solo per ruoli amministrativi o rimosso | test guard |
| 0.6 | `GET /tickets` (tutti) e `GET /tickets/search` chiusi (403). Il dashboard non li usa | grep FE: nessuna chiamata |
| 0.7 | `myTicket`: l'`userId` nel path deve coincidere con l'utente chiamante; risultato filtrato dalla policy; **stesso formato di risposta di oggi** (conteggi NavBar e annunci non devono cambiare) | confronto prima/dopo su pascale-local |
| 0.8 | Errori: niente `e.getMessage()` nelle risposte 500, niente query/token nei log, log a livello corretto (regola progetto: loggare successo e servizio, mai token/risposte/nomi/email) | review log |
| 0.9 | Test: policy, guard, caller, forward HTTP con server mock; copertura dei casi negativi | `mvn test` verde |
| 0.10 | Regressione manuale su pascale-local con Zammad 7.2.2: creazione ticket da CRF, creazione ticket di studio (annuncio), conteggi NavBar/Dashboard, link SSO | checklist sez. 9 |
| 0.11 | Token Zammad in chiaro: decisione dell'utente = lasciare com'e'; annotare nel registro rischi e nella doc che per produzione si consiglia rotazione e secret | nota nel registro |

Uscita Fase 0: PR (su richiesta) del ms zammad; nessuna funzionalita' nuova per l'utente.

---

## 6. Fase 1 — Blocco della conferma (8-10 gg)

### 6.1 Dati e collegamento ticket <-> CRF
| Passo | Cosa fare |
|---|---|
| 1.1 | In Zammad aggiungere gli attributi Ticket `crfscope` (CRF/STUDY) e `qrid` (opzionale). Estendere `install_zammad_attributes.sh` e `ZammadAttributeService.REQUIRED_TICKET_ATTRIBUTES`. Gli attributi esistenti restano (`crf`, `careplan`, `patient`, `patientjourneydisplay`, `directlink`) |
| 1.2 | Dashboard: alla creazione impostare `crfscope=CRF` (dialog CRF, `CrfTherapyRenderer`) o `crfscope=STUDY` (form studio, `PatientJourneyCrudFormNew`); passare `qrid` se la QR esiste |
| 1.3 | **Backfill** dei ticket esistenti: script che per ogni ticket senza `crfscope` deduce `crfscope` (`crf='00000'` o stato 7 -> STUDY) e risolve la QR da `crf+careplan+patient`. Produce un **report** dei ticket ambigui/non agganciabili. **Mai trattati come "non bloccano"**: restano in elenco da bonificare a mano |

### 6.2 Task `ticket-ref` e sincronizzazione
| Passo | Cosa fare |
|---|---|
| 1.4 | Definire il `Task` FHIR `ticket-ref` (stile `sae-query`): `identifier` = id ticket Zammad; `focus` = QuestionnaireResponse (se esiste); chiave logica (Paziente in `for`, Questionnaire e CarePlan in `input`); `status` e `businessStatus` riflettono lo stato Zammad; `input` con URL del ticket. **Nessun testo, nessun allegato** |
| 1.5 | Il ms zammad e' l'unico scrittore del Task: lo crea alla creazione del ticket via piattaforma e lo aggiorna ai cambi di stato |
| 1.6 | **Webhook** Zammad -> ms (endpoint non autenticato JWT ma con firma HMAC obbligatoria, confronto a tempo costante, protezione replay con id/timestamp evento, rate limit). Gestisce create/update/close da qualunque origine (anche Zammad UI) |
| 1.7 | **Riconciliazione periodica** (riuso `SyncScheduler`): confronta Zammad con i Task e corregge; tiene conto dei webhook persi. Ticket creati da Zammad UI senza attributi vanno nel report "non agganciabili" |
| 1.8 | Endpoint `GET /crf/{chiave}/tickets/summary`: conteggi aperti/pending/chiusi e elenco dei bloccanti (id, titolo, stato, owner, da quanto tempo, link) |

### 6.3 Blocco server-side
| Passo | Cosa fare |
|---|---|
| 1.9 | In `enforceCrfConfirmation` (e nel `create` gia' `completed`): cercare in HAPI i Task `ticket-ref` non chiusi per la chiave logica della CRF, escludendo `crfscope=STUDY`. Se ce ne sono: **409 `CRF_OPEN_TICKETS`** con conteggio e lista. Verificare se estendere a `/certify` e annotarne l'esito. SAE: invariato |
| 1.10 | **Override**: ruolo `internal:override:ticket-gate`; richiesta con motivazione obbligatoria (definire il trasporto, es. extension sulla QR o header, in fase di design); senza motivo = rifiuto; con motivo = conferma + evento di audit (BusinessEvent) con chi/perche'/quali ticket |
| 1.11 | **Indeterminato**: errore di ricerca HAPI -> la conferma fallisce con codice distinto (non confermare mai "per errore") |
| 1.12 | **Flag** `crf.confirm.require-closed-tickets`, **default OFF**, attivabile per studio. Con flag OFF il comportamento e' identico a oggi |
| 1.13 | **Audit post-conferma**: se un ticket si apre/riapre su una CRF gia' confermata, evento di audit "ticket dopo conferma"; nessun auto-unlock |
| 1.14 | Censire tutti gli scrittori di QR in stato `completed` (QuestionnaireExpiryService, QuestionnaireCompilationLifecycle, QuestionnaireResponseProvenanceService, PatientQuestionnaireResponseController, BundleController create, PATCH) e verificare che passino dal Flow o che vengano coperti (audit/alert) |
| 1.15 | Rilascio `irccs-common` (bump versione) e ricompilazione dei microservizi che lo usano |

### 6.4 Dashboard (Conferma CRF)
| Passo | Cosa fare |
|---|---|
| 1.16 | Hook `useCrfTicketSummary(chiave)` (TanStack Query, refetch al focus) |
| 1.17 | Chip "N ticket aperti" accanto a "Conferma CRF"; bottone disabilitato con tooltip; sotto, elenco dei bloccanti con stato, responsabile, **anzianita'** e link diretto a Zammad |
| 1.18 | Gestione del 409 `CRF_OPEN_TICKETS` (race): messaggio chiaro + aggiornamento elenco. Per chi ha il ruolo di override: azione "Conferma comunque" con campo motivazione |
| 1.19 | Vista per DM: elenco CRF bloccate da ticket per studio/centro (filtri) |
| 1.20 | i18n it/en in `public/locales` per ogni stringa nuova (regola progetto) |
| 1.21 | Tutto dietro lo stesso flag; con flag OFF nessuna differenza visibile |

### 6.5 Messa in esercizio
| Passo | Cosa fare |
|---|---|
| 1.22 | Deploy preprod con flag OFF; eseguire backfill + report ticket non agganciabili |
| 1.23 | Bonifica dei ticket del report con il cliente; fissare **data di entrata in vigore** |
| 1.24 | Attivare il flag **studio per studio**; monitorare 409 e override |
| 1.25 | Procedura di rollback: spegnere il flag |

---

## 7. Fase 2 — Pannello ticket nella CRF (6-8 gg)

| Passo | Cosa fare |
|---|---|
| 2.1 | ms: `GET /tickets/{id}` e `GET /tickets/{id}/articles` (thread) con policy; **articoli interni** esclusi lato server per chi non e' agent; HTML degli articoli **sanitizzato lato server** (allowlist) |
| 2.2 | ms: `POST /tickets/{id}/articles` (risposta) con identita' reale dell'utente; limite di lunghezza e rate limit |
| 2.3 | ms: `PUT /tickets/{id}/state` (chiudi/riapri) con regole sez. 1 e **motivazione obbligatoria alla chiusura**; il Task `ticket-ref` si aggiorna subito (senza attendere il webhook) |
| 2.4 | ms: lista ticket della CRF (`/crf/{chiave}/tickets`) filtrata dalla policy |
| 2.5 | Dashboard: `TicketDrawer` (MUI Drawer destro ~440px, a schermo intero su mobile): filtro Aperti/Tutti, thread stile chat, composer, chiudi/riapri, "Nuovo ticket" (riuso del dialog esistente), link "Apri in Zammad" |
| 2.6 | Il chip della Fase 1 apre il pannello; dopo chiusura dell'ultimo ticket il bottone "Conferma CRF" si abilita (invalidazione query) |
| 2.7 | Ticket di studio: apribili dal pannello della Dashboard studi ("newsTicket"), solo lettura/risposta, non bloccanti |
| 2.8 | Rendering sicuro: mai `dangerouslySetInnerHTML` su contenuti non sanitizzati; test XSS |
| 2.9 | Avviso nel composer: non inserire dati identificanti del paziente nel testo libero |
| 2.10 | Dietro feature flag proprio (`VITE_APP_TICKET_DRAWER`), rollback senza ridistribuire |
| 2.11 | Playwright: apertura pannello, risposta, chiusura, bottone che si sblocca |
| 2.12 | Allegati: nella v1 si apre Zammad dal link; allegati nel pannello in Fase 3 |

---

## 8. Fase 3 (dopo) e fuori scope

- **Fase 3:** allegati nel pannello (streaming dal ms, `Content-Disposition: attachment`, `nosniff`, limiti tipo/dimensione, antivirus), SSE, badge per domanda (`instance`/`linkId`), note interne, sostituzione del polling `myTicket` con il summary, notifiche a chi deve rispondere.
- **Fuori da questo impegno (da quotare a parte):** `TicketProvider` astratto, Implementation Guide FHIR, pacchetto FE riusabile, mapper R5.
- **Da definire con il DPO prima del go-live:** regole PHI/retention di ticket e allegati, registro dei trattamenti.

---

## 9. Checklist di regressione (scenari esistenti)

1. Creazione ticket da CRF (dialog, piu' gruppi destinatari): campi `crf/careplan/patient/directlink` corretti.
2. Creazione ticket di studio (annuncio, `state_id 7`): arriva ai gruppi, **non** blocca conferme.
3. Conteggi NavBar e "newsTicket" della Dashboard invariati (stesso formato `myTicket`).
4. Link Dashboard -> Zammad via `/auth/sso`.
5. Query SAE (`sae-query` + ticket Zammad): invariata; SAE non bloccate dai ticket.
6. Utente che risponde/chiude dall'interfaccia Zammad: lo stato arriva alla piattaforma (webhook/riconciliazione).
7. Ticket legacy senza `crfscope`/`qrid`: backfill e report.
8. Flag OFF: nessuna differenza rispetto a oggi.
9. Utente di un altro centro: non vede ne' risponde ai ticket altrui.
10. Audit: accessi ticket sempre tracciati (`ZammadTicketAuditFilter`), override e "ticket dopo conferma" presenti.

## 10. Criteri di accettazione per fase

- **Fase 0:** 403 sui ticket altrui; nessun header client inoltrato; test verdi; checklist 1-4 e 8 ok.
- **Fase 1:** con ticket aperto, `PUT QR -> completed` da API diretta restituisce 409; flag OFF identico a oggi; ticket di studio non bloccano; override senza motivo rifiutato e con motivo in audit; webhook perso recuperato dalla riconciliazione; HAPI giu' -> mai conferma; E2E su pascale-local.
- **Fase 2:** il pannello mostra solo ticket autorizzati; test XSS ok; regole di chiusura rispettate; Playwright verde.

## 11. Rischi residui accettati

- Controllo e scrittura non atomici: un ticket puo' essere riaperto tra il controllo e la PUT. Mitigazione: evento di audit "ticket dopo conferma".
- Stato in HAPI in ritardo rispetto a Zammad: coperto da webhook + riconciliazione; ticket chiuso da poco ma ancora "aperto" blocca (lato sicuro), ticket riaperto da poco ma ancora "chiuso" e' la finestra residua.
- Token Zammad in chiaro nel repository (decisione del committente).
- Tre feature sulla stessa funzione `enforceCrfConfirmation`: gestito con l'ordine di merge (P2).

---

## 12. Recepimento della revisione tecnica (v1.1) — prevale sulle sezioni 1-11

Giudizio della revisione: architettura confermata (Zammad = ticketing, HAPI = riferimento strutturato, `irccs-common` = regola). Non si riscrive nulla; si aggiungono invarianti e verifiche **prima** di sviluppare il gate. Punto chiave: il ticket non e' solo ticketing, e' un vincolo del workflow clinico, quindi la correttezza della sincronizzazione fa parte del controllo.

### 12.1 Inventario degli scrittori di `QuestionnaireResponse.status=completed` (analisi preliminare sul codice)

Fatto: la regola `enforceCrfConfirmation` vive in `QuestionnaireResponseFlow` (`irccs-common/i3-annotations`, righe ~626-665) ed e' invocata **solo** da `create()` (riga ~94) e `update()` (riga ~132). Il Flow non gestisce PATCH. Se la lettura della QR esistente fallisce, la richiesta e' trattata come nuova conferma (comportamento fail-closed, da mantenere). Il Flow stampa `confirmed-at` / `confirmed-by-subject` sulla QR: **in questa piattaforma `completed` + queste extension = "CRF confermata"**.

| # | Percorso | Imposta `completed`? | Passa dal Flow? | Gate ticket? | Da verificare |
|---|---|---|---|---|---|
| 1 | Dashboard -> `QuestionnaireResponseController` PUT/POST (conferma esplicita) | si | si (update/create) | **si** | - |
| 2 | `create` di QR gia' `completed` (`QuestionnaireResponseFlow.create`) | si | si | **si** (chiave logica: la QR non ha ancora id) | - |
| 3 | `BundleController.importPatientJourneyStudy` (create + seconda fase PUT di fix placeholder) | possibile (import di QR) | da verificare se i create passano dal Flow; la seconda fase e' PUT diretta | da decidere: import = migrazione, non conferma | tracciare se QR importate completed devono o no essere gated |
| 4 | `PatientQuestionnaireResponseController` (compilazione da parte del paziente, token) | `existing.setStatus(incoming.getStatus())` -> puo' scrivere `completed` | memoria: **senza interceptor** | distinguere: "paziente ha finito" != "CRF confermata dal DM" | verificare se il paziente puo' davvero chiudere a `completed`; se si, o si blocca o si definisce che non e' conferma |
| 5 | `patient-interview` (`InterviewService`, `QuestionnaireResource`) | create QR | memoria: senza interceptor | come sopra | leggere lo `status` scritto |
| 6 | `QuestionnaireExpiryService` | **no**: porta `INPROGRESS -> STOPPED` | n/a | no | - |
| 7 | `QuestionnaireResponseProvenanceService` | no (scrive Provenance) | n/a | no | - |
| 8 | `QuestionnaireCompilationLifecycle` | solo **legge** `COMPLETED` (riga 72) | n/a | no | - |
| 9 | `CrfCertificationService` / `/certify` | non scrive `completed` (Task, Provenance, OTP) | n/a | **si, se produce effetto equivalente a conferma**: valutare blocco della certificazione con ticket aperti | decisione funzionale |
| 10 | PATCH QR / accesso diretto a HAPI (service account, script, admin) | si | **no** | non coperto dal Flow | coprire con audit/alert; valutare interceptor HAPI per PATCH |
| 11 | SAE | si | si, ma escluso da `enforceCrfConfirmation` | no (lock `sae-query`) | invariato; il test di regressione SAE e' obbligatorio |

Conseguenza: il punto di enforcement e' centrale **solo per le chiamate che passano dal Flow**. Il gate va implementato come **regola componibile** nello stesso punto di `enforceCrfConfirmation` (non come seconda implementazione parallela), con test per ogni riga della tabella. Le righe 3, 4, 5, 9, 10 richiedono una decisione prima della Fase 1.

### 12.2 Contratto di consistenza Zammad <-> HAPI
- **Il webhook e' un trigger, non la fonte dello stato.** A ogni evento il ms **rilegge il ticket da Zammad** (attributi e stato) e scrive il Task. Cosi' eventi duplicati, fuori ordine o con timestamp inaffidabile convergono sullo stato reale e il payload non puo' decidere paziente/CRF.
- Idempotenza: chiave evento + id ticket; duplicati scartati; ordine garantito dalla rilettura, non dal timestamp.
- Retry con backoff degli aggiornamenti falliti; dead-letter visibile.
- Riconciliazione periodica con **metriche e allarmi** (non correzioni silenziose): ritardo evento->Task, differenze trovate, ticket non verificabili.
- **Indicatori di freschezza:** sul Task `lastEventAt`, `lastSyncedAt`, `syncError`; a livello servizio un "heartbeat" dell'ultima riconciliazione riuscita.
- **Sincronizzazione degradata** (webhook inattivo, riconciliazione fallita, ritardo oltre soglia, stato non verificabile, stato sconosciuto): il gate risponde **indeterminato -> conferma rifiutata** con codice distinto, superabile solo con override tracciato. Soglia configurabile (proposta iniziale 5 min, da tarare in preprod).
  - Effetto da dichiarare: se Zammad resta irraggiungibile oltre la soglia, le conferme si fermano (scelta conservativa della revisione). **Da confermare con l'utente** (sostituisce il "il blocco non dipende da Zammad" della sezione 1).
- **Requisito sulle race (documentato):** *minimo* — nessuna conferma autorizzata se al momento della decisione esistono ticket bloccanti noti. *Piu' forte* (nessuna CRF confermata se un ticket viene aperto durante la conferma) richiede coordinamento che i soli controlli server non danno, perche' l'operatore puo' riaprire direttamente in Zammad. Nell'MVP: si adotta il requisito minimo + audit "ticket dopo conferma"; il requisito forte va chiarito col responsabile clinico prima di investire in lock/versioning.

### 12.3 Chiave CRF canonica (un solo contratto)
- Tre identita' distinte: **CRF logica** (Questionnaire + CarePlan + Paziente), **compilazione** (QuestionnaireResponse), **ticket** (conversazione Zammad). Non intercambiabili.
- Una **sola** rappresentazione canonica della chiave, implementata **una volta** in `irccs-common` (classe condivisa) e riusata da: creazione ticket (dashboard/ms), backfill, webhook, query HAPI, gate. Vietato ricostruirla in piu' servizi.
- Da verificare nel codice prima di fissarla: una stessa terna Questionnaire+CarePlan+Paziente puo' avere piu' QR legittime (ripetizioni, rework, versioni)? Se si, la chiave logica da sola non basta e serve `qrid`.
- Casi da trattare esplicitamente: ticket creato prima della QR; compilazioni multiple; ripetizioni di gruppo (blocca la QR intera); legacy; ticket con associazioni ambigue (mai "non bloccano").

### 12.4 Modello `Task` ticket-ref: invarianti
- `identifier` con **namespace**: `system` = istanza Zammad (es. `urn:zammad:<istanza>`), `value` = id ticket. Vincolo di unicita' via create condizionale (`If-None-Exist`) per evitare Task duplicati da webhook/retry/riconciliazione.
- **Un'unica funzione di mapping** stato Zammad -> (`Task.status`, `Task.businessStatus`, classe) e una sola classificazione: *bloccante / non bloccante / sconosciuto*. **Sconosciuto = bloccante** (mai considerato chiuso).

| Stato Zammad | `Task.status` | `Task.businessStatus` | Classe |
|---|---|---|---|
| new | in-progress | new | bloccante |
| open | in-progress | open | bloccante |
| pending reminder | in-progress | pending-reminder | bloccante |
| pending close | in-progress | pending-close | bloccante |
| closed | completed | closed | non bloccante |
| merged | completed (riferimento al ticket di destinazione conservato) | merged | non bloccante |
| qualsiasi altro | in-progress | unknown | **bloccante** |

(Mapping di esempio da validare in revisione.)

### 12.5 Backfill: criteri di uscita
- Prima di applicare, produrre statistiche: quanti ticket hanno `crf='00000'` **e** stato 7, quanti solo una delle due, quanti dati mancanti/contraddittori, quanti rischiano misclassificazione. Non usare lo stato corrente come unico criterio per la natura originaria.
- Il report dei non agganciabili e' **criterio di uscita**: nessuno studio si attiva con ticket ambigui non risolti e documentati.

### 12.6 Sicurezza: precisazioni
- **Identita':** subject Keycloak come chiave primaria, mappatura esplicita verso l'utente Zammad; account disabilitati rifiutati; mappatura assente = 403; cambio email non impersona; mai fallback al token di servizio; verificare come la versione Zammad installata interpreta `X-On-Behalf-Of` e quali permessi mantiene il chiamante.
- **Autorizzazione clinica oltre ai gruppi Zammad:** il ms verifica anche il contesto (centro/studio/paziente) dell'utente, non solo il gruppo Zammad. Test negativi tra centri.
- **Summary autorizzazione-consapevole:** chi puo' confermare vede *se* la CRF e' bloccata e quanti ticket; titolo/dettagli solo per chi puo' leggere quei ticket. Il summary non e' un canale per ticket non accessibili.
- **Webhook:** rotazione del segreto HMAC; validazione di struttura e dimensione del payload; verifica che il ticket del payload corrisponda alla risorsa aggiornata; allarmi su firme non valide e fallimenti ripetuti.
- **Token Zammad in chiaro:** resta la decisione del committente di lasciarlo, ma e' registrato come **rischio aperto da chiudere prima del go-live in produzione** (rotazione, secret manager, rimozione dalla configurazione versionata; il segreto resta nella cronologia Git quindi va ruotato).

### 12.7 Specifica dell'override
- Permesso `internal:override:ticket-gate` verificato **sul server**, indipendente dal bottone.
- Motivazione obbligatoria: rifiutate stringhe vuote/solo spazi; lunghezza massima; caratteri di controllo rimossi; eventuale categoria.
- Audit (BusinessEvent) con: chi, quando, CRF, ticket bloccanti, motivazione, operazione autorizzata, versione della regola/configurazione. Tre eventi distinti: *override richiesto*, *override autorizzato*, *conferma completata*.
- **Se l'audit non e' scrivibile, l'override e' rifiutato** (la conferma non procede senza traccia).
- L'override scavalca **solo** il controllo ticket: nessun altro controllo (ruolo `internal:confirm:crf`, SAE) viene disattivato.
- Report periodico degli override per studio e centro.

### 12.8 Semantica di `completed`
Nella piattaforma `completed` + extension `confirmed-at/by-subject` indica "CRF confermata" (stampate dal backend). Non cambiare il modello per questa integrazione. Annotare pero' (riga 4/5 della tabella 12.1) che una chiusura lato paziente non va confusa con la conferma; se in futuro si aggiungono approvazione DM, firma, validazione clinica o nuove revisioni, distinguere esplicitamente "compilazione terminata" da "confermata".

### 12.9 Dashboard
- Tre esiti distinti nel riepilogo: **bloccata**, **indeterminato**, **confermabile**; se la query del summary fallisce il bottone **non** si abilita.
- La decisione finale e' del server; il frontend non reinterpreta gli stati Zammad e non duplica la logica.
- Rollback: spegnere il flag disabilita solo il nuovo vincolo; **non** cancella i Task, **non** ripristina lo stato dei ticket, **non** elimina audit, **non** annulla conferme gia' avvenute. Da scrivere nella procedura operativa.

### 12.10 Dati, GDPR, audit
Prima del go-live (requisito formale, non attivita' indeterminata): minimizzazione (niente identificativi non necessari in titolo/testo/notifiche), retention per ticket/articoli/allegati/audit/backup, accessi tracciati senza copiare contenuti sanitari nei log, ambienti locali/preprod con dati sintetici o anonimizzati, e chiarire se il ticket e' solo operativo o documentazione necessaria a ricostruire decisioni sui dati dello studio (influisce sulla retention). Definire l'impegno del DPO.

### 12.11 Criteri di go-live per studio (gate di rilascio)
| Controllo | Criterio di uscita |
|---|---|
| Ticket legacy | classificati o gestiti esplicitamente; nessun ambiguo non valutato |
| Chiave CRF | contratto canonico unico in uso da tutti i componenti |
| Sincronizzazione | test di errore su webhook (perso, duplicato, fuori ordine) e riconciliazione; stato degradato -> indeterminato verificato |
| Autorizzazioni | test negativi per utenti di altri centri |
| Conferma | matrice 12.1 chiusa: nessun percorso noto aggira il gate (o eccezione documentata) |
| SAE | regressione superata |
| Override | permessi, motivazione, audit (incl. fallimento audit) verificati |
| Monitoraggio | metriche e allarmi su ritardo sync, firme webhook non valide, override |
| Rollback | procedura verificata in preprod e semantica documentata (12.9) |
| DPO | regole di trattamento e retention approvate |

### 12.12 Priorita' riviste
- **P0 (prima del gate):** Fase 0 di sicurezza; baseline/mappa delle API Zammad usate (creazione, lettura, ricerca, modifica, identita', conteggi `myTicket`, SSO, SAE) con risposte attese ripetibili, sul codice e sul comportamento locale; chiusura matrice 12.1; chiave CRF canonica; mapping stati; contratto di consistenza e webhook; ordine di merge (sae-dm-confirm -> crf-check -> ticket) verificando che i controlli SAE restino intatti e senza chiamate duplicate.
- **P1:** attributi + backfill, Task e associazione, sync + riconciliazione, gate centralizzato, override + audit, summary, test integrazione/regressione, attivazione progressiva (flag non acceso finche' non coperti: stato sconosciuto, sync degradata, legacy non classificati).
- **P2:** pannello (thread, risposte, chiusura/riapertura, articoli interni, sanitizzazione, `TicketDrawer`, Playwright, accessibilita', mobile). Il pannello puo' slittare senza rinunciare al gate.

### 12.13 Stime
Le stime (18-24 gg) restano baseline tecnica per chi conosce il codice; **non** includono riserva per: ricostruzione spec, rebase dei branch, comportamento reale dei webhook Zammad 7.2.2, backfill storico, matrice scrittori, race, autorizzazioni tra centri, E2E/regressione, validazione del cliente, attivita' DPO. Aggiungere una riserva di integrazione/test/rilascio e **ristimare dopo** lo spike webhook e la chiusura della matrice 12.1 (che potrebbe ridurre il lavoro se il codice supporta gia' parte del comportamento).

### 12.14 Impatto sui passi delle sezioni 4-7
- **Prerequisiti:** aggiungere P6 *matrice scrittori chiusa*, P7 *chiave CRF canonica*, P8 *mapping stati*, P9 *contratto webhook/sync*.
- **Passo 1.6-1.7:** webhook = trigger + rilettura da Zammad; metriche/allarmi; freschezza (12.2).
- **Passo 1.9:** gate come regola componibile in `enforceCrfConfirmation`, esiti *bloccata / indeterminato / ok*; coprire righe 2, 3, 4, 5, 9, 10 della tabella 12.1 secondo decisione.
- **Passo 1.10:** override secondo 12.7.
- **Passo 1.22-1.24:** attivazione solo con i criteri 12.11.
- **Passo 2.1/2.2:** autorizzazione clinica oltre ai gruppi (12.6).

### 12.15 Decisioni nuove da prendere con l'utente
1. **Sync degradata = conferma bloccata** (anche se Zammad e' giu' oltre la soglia): confermi la scelta conservativa e la soglia iniziale?
2. Righe 3/4/5 (import bundle, compilazione paziente, patient-interview): sono "conferma" da gated, oppure no?
3. Estendere il gate a `/certify` (riga 9).
4. Requisito sulle race: minimo (MVP) o forte? Serve il parere del responsabile clinico.
5. Copertura PATCH/accesso diretto HAPI (riga 10): solo audit/alert o interceptor HAPI?

### 12.16 Decisioni 12.15 (raccomandate, adottate su delega dell'utente 2026-10-21)
1. **Sync degradata = conferma bloccata**, solo per gli studi con flag attivo. Soglia iniziale 10 min (taratura in preprod), allarme a meta' soglia. Il controllo legge l'"heartbeat" di riconciliazione in HAPI, non chiama Zammad a ogni conferma: brevi indisponibilita' di Zammad non bloccano nulla; oltre soglia si ferma e si sblocca con override tracciato.
2. **Gate su ogni percorso che porta a `completed` una CRF non SAE**, tramite un **componente condiviso** `CrfTicketGate` in `irccs-common` chiamato da: `QuestionnaireResponseFlow` (create/update), `PatientQuestionnaireResponseController`, `patient-interview`. Il controllo del ruolo `internal:confirm:crf` resta solo sulla conferma del DM. Import bundle: esentato (migrazione di dati storici, nessun ticket esiste) ma con audit e test che lo documenta.
3. **`/certify` incluso**, dopo il nucleo di Fase 1 e dietro lo stesso flag: la firma con query aperte e' equivalente a una conferma. Stesso override.
4. **Race: requisito minimo nell'MVP** + due mitigazioni a basso costo: (a) controllo immediatamente prima della scrittura; (b) verifica **dopo** la scrittura: se nel frattempo e' comparso un ticket bloccante, evento di audit "conferma con ticket concorrente" e notifica al DM, senza riaprire la CRF. Il requisito forte (lock/versioning) solo se lo chiede il responsabile clinico.
5. **PATCH e accesso diretto a HAPI:** subito, negare PATCH su `QuestionnaireResponse` a livello di microservizi/proxy (solo service account tecnici) e allarme sull'audit esistente per scritture dirette di `completed`; interceptor HAPI rimandato a una fase successiva se l'allarme rivela abusi.

### 12.17 Matrice scrittori: esito verificato sul codice (2026-10-21)
- Il `QuestionnaireResponseFlow` NON e' un filtro di rete: e' un interceptor CDI (`AuthFlowInterceptor`, binding `@SyncAuthFlow`) applicato ai **controller annotati** che estendono `GenericController`. Per le QR sono due: `studio-clinico/QuestionnaireResponseController` e `anagrafica-pazienti/QuestionnaireResponseController`. Il gate in `irccs-common` copre quindi entrambi, ma richiede la ricompilazione di **entrambi** i microservizi.
- **Fuori dal Flow** (nessun `@SyncAuthFlow`, scrivono direttamente via `FhirClient`): `PatientQuestionnaireResponseController` (studio-clinico, `existing.setStatus(incoming.getStatus())` con `update(existing, null)`), `patient-interview` (`InterviewService`, `QuestionnaireResource`), `BundleController`, `QuestionnaireExpiryService` (solo `INPROGRESS->STOPPED`), `CrfCertificationService`. Confermato quindi che il componente condiviso `CrfTicketGate` (12.16 punto 2) va chiamato esplicitamente da `PatientQuestionnaireResponseController` e `patient-interview`: il solo gate nel Flow non li copre.
- Nessun altro microservizio scrive QR (auth/webpush le citano solo come DTO/notifica).

### 12.18 Esiti dello spike webhook (vedi `2026-10-21-spike-webhook-zammad.md`)
Correzioni al documento: attributi nuovi `crfscope` e `qrid` (Zammad vieta `scope` e i nomi `*_id`); classificazione degli stati per **state_type** (lo stato 7 degli annunci e' custom, non di default); webhook = solo notifica con rilettura del ticket (payload = snapshot alla consegna, duplicati, nessun evento su cancellazione); riconciliazione con scansione `GET /tickets` (la ricerca Zammad non e' affidabile senza Elasticsearch) che segnala anche i ticket cancellati; merge Zammad solo per numero ticket; HMAC e' SHA-1 (`X-Hub-Signature`). Spike P3 **chiuso**.

---

## 13. Stato di implementazione (2026-10-22) e guida all'attivazione

Tutto e' in **commit locali su branch separati da develop, senza push ne' PR**. Il blocco e' **spento di default**: con i flag spenti nessun percorso cambia comportamento.

### 13.1 Branch e contenuto
| Repo | Branch | Cosa contiene |
|---|---|---|
| `irccs-common` | `feature/ticket-gate-common` | `CrfKey` (chiave canonica), `TicketStateMapper` (per tipo di stato, sconosciuto = bloccante), `CrfTicketGate` (CLEAR/BLOCKED/INDETERMINATE + battito), `TicketGatePolicy` (override), integrazione in `QuestionnaireResponseFlow.enforceCrfConfirmation`, `FhirClient.auditRequired` (audit sincrono e obbligatorio) |
| `irccs-microservice-zammad` | `feature/ticket-ref-sync` (impilato su `feature/crf-query`) | Fase 0 (identita' per `keycloak_ref`, policy per ticket, guard creazione/PUT, admin endpoints chiusi, `users/search` solo proprio record) + sincronizzazione `Task ticket-ref` (webhook HMAC, riconciliazione, battito) + `GET /tickets/crf-summary` + `GET /tickets/ticket-ref-report` |
| `irccs-microservice-studio-clinico` | `feature/ticket-gate-patient` | blocco sulla PUT del paziente (link con token) e sulla certificazione CRF |
| `irccs-microservice-patient-interview` | `feature/ticket-gate-patient` | blocco sulla creazione di QR gia' completed da parte del paziente |
| `irccs-react-dashboard` | `feature/ticket-gate-ui` | `CrfConfirmButton` (chip ticket aperti, bottone disabilitato, finestra di override), servizio/hook riepilogo, `crfscope`/`qrid` sui nuovi ticket, stringhe it/en |
| `irccs-docker` | `feature/ticket-ref-install` | `install_zammad_webhook.sh`, attributi `crfscope`/`qrid`, risorse Keycloak (`CrfSummary`, `TicketRefReport`) |

### 13.2 Verifiche eseguite
- Unit/HTTP: common 300 test, ms Zammad 115, studio-clinico (certificazione 21; paziente 28 con 2 fallimenti **gia' presenti su develop**: 400 vs 401 sui token), dashboard `tsc` pulito.
- End-to-end su `pascale-local` (Keycloak reale + policy enforcer + HAPI + ms + Zammad 7.2.2 locale): Fase 0 **21/21**; blocco in `QuestionnaireResponseFlow` **11/11** (409 con ticket aperto, pending blocca, ticket di studio non blocca, chiusura sblocca e stampa `confirmed-at`, motivo override corto = 422); override valido con audit attivo = 200 con evento `ticket-gate-override` (motivo, esito, ticket, utente); **override con store di audit giu' = rifiutato (503)**; sincronizzazione ferma oltre soglia = 503 `CRF_TICKET_STATE_UNVERIFIABLE`; riepilogo dashboard attraverso Keycloak; webhook firmato che aggiorna il Task in pochi secondi; script di installazione idempotente.
- **Non verificato**: browser (dashboard solo `tsc`), percorso del paziente end-to-end (solo test unitari), `patient-interview` (compila, senza test), Zammad di produzione (non raggiungibile), Zammad con Elasticsearch attivo.

### 13.3 Difetti trovati dai test (e corretti)
1. `auditRequired` era asincrono/best-effort: con audit giu' l'override passava (ora sincrono e propaga).
2. HAPI rifiuta un `Task` che punta a un paziente inesistente: un ticket anomalo fermava tutta la riconciliazione (ora salvato senza riferimento al paziente; se qualche ticket resta non allineato il battito non si aggiorna).
3. La ricerca utenti per campo dipende dall'indice di Zammad (senza ES nessuno veniva riconosciuto): ora ripiego su ricerca libera per email con prova dell'identita' dal `keycloak_ref` del record.
4. `POST /fhir/zammad/users` permetteva di creare utenti Admin: ora chiuso.

### 13.4 Differenze rispetto al piano (da conoscere)
- **Flag globale, non per studio**: `crf.confirm.require-closed-tickets` vale per l'intero microservizio. Il legame QR -> studio non e' immediato; l'attivazione per studio richiede di decidere come dedurlo (aperto).
- **Paziente**: i percorsi di compilazione del paziente bloccano solo con ticket aperti **noti**; uno stato non verificabile non li ferma (il paziente non puo' sistemare Zammad). Nessun override.
- **Certificazione**: blocca con ticket aperti su **qualunque** CRF del paziente; nessun override (si chiudono i ticket e si riprova).
- **SAE**: escluse (il Flow non applica il blocco alle SAE), come deciso.
- **Import bundle, PATCH QR, scritture dirette su HAPI**: non coperti (decisioni 12.16: PATCH da negare a livello proxy e allarme audit, da fare).
- **Drawer di lettura/risposta ai ticket (Fase 2)**: non iniziato. La dashboard mostra chip e blocco; il link porta a Zammad.
- Il rapporto `ticket-ref-report` segnala i ticket CRF senza chiave; non esiste ancora uno script di "bonifica" che li sistemi: si correggono in Zammad (attributi) e la riconciliazione li riallinea.

### 13.5 Come si attiva (ordine)
1. Rilasciare `irccs-common` (bump versione) e ricompilare i ms che lo usano (studio-clinico, anagrafica-pazienti, patient-interview, zammad).
2. Su Zammad: `install_zammad_attributes.sh` (crea `crfscope` e `qrid`), poi `install_zammad_webhook.sh <ZAMMAD_URL> <URL interno del ms>/fhir/zammad/webhook` con `WEBHOOK_SECRET`.
3. Keycloak: rieseguire `add-zammad-authz.py` (nuove risorse `CrfSummary` e `TicketRefReport`); creare il ruolo `internal:override:ticket-gate` e assegnarlo al gruppo dei responsabili.
4. ms Zammad: `ZAMMAD_TICKET_REF_ENABLED=true`, `ZAMMAD_WEBHOOK_SECRET=<segreto>`, `ZAMMAD_INSTANCE_ID` (facoltativo). Attendere la prima riconciliazione (5 min) e leggere `GET /fhir/zammad/tickets/ticket-ref-report` (richiede `zammad.admin-endpoints.enabled=true`): `ready=true` e nessun ticket CRF senza chiave o errore.
5. Solo allora, sui ms clinici: `CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=true` (soglia di sincronizzazione `CRF_CONFIRM_TICKET_SYNC_MAX_AGE`, default `PT10M`) e nel ms Zammad le stesse due variabili (la dashboard le legge da li').
6. Rollback: rimettere `CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=false`. Non cancella i Task ne' l'audit (12.9).
7. Prerequisiti ancora aperti: `keycloak_ref` popolato per tutti gli utenti (altrimenti 403 su creazione ticket/badge), lettura degli stati personalizzati in produzione (lo stato 7 degli annunci), PHI/retention con il DPO, rotazione del token Zammad.

### 13.6 Prova completa su pascale-local con ruoli e browser (2026-10-22)
Branch pubblicati su origin (`infocube-it` per irccs-docker). Stack completo `pascale-local` con immagini costruite dai branch (ms Zammad, studio-clinico, dashboard) + Zammad 7.2.2 locale **senza Elasticsearch**. Script: `specs/spike-zammad-webhook/` (`e2e_roles.py`, `e2e-full.yml`, `ui/*.cjs`).

**Modello dei ruoli (scoperta):** le capability `internal:*` non stanno nel token ne' sull'utente: vengono dai **gruppi** (membership letta dal vivo) e valgono nel contesto attivo (`X-Context-Token` emesso da `POST /auth/users/context`, che ne contiene le capability). Quindi `internal:override:ticket-gate` si assegna al **gruppo** (form "Gruppi utenti", sezione CRF: casella aggiunta) e dopo l'assegnazione serve un nuovo login/contesto. Ruoli creati con `keycloak-config/add-ticket-gate-roles.py` (idempotente): `internal:confirm:crf`, `internal:override:ticket-gate`; risorse Zammad con `add-zammad-authz.py`.

**API con utente reale del dump** (alessandra.molaro, gruppo Sperimentatori, paziente 8383, CRF reali) **16/16**: ticket creato dalla piattaforma, Task su HAPI, riepilogo BLOCKED, 409 alla conferma, override senza ruolo 403, chiusura ticket e conferma con `confirmed-by` corretto, override col ruolo sul gruppo (409 senza motivo, 422 motivo corto, 200 con motivo), audit con motivo/ticket/utente, ticket di studio che non blocca.

**Browser reale (Chrome headless, dashboard del branch), 8/8:** login, pagina CRF della linea 2 del paziente 28: chip "N open tickets" e **Confirm CRF disabilitato** senza override; dopo aver dato la capability al gruppo e rifatto il login il bottone e' cliccabile, si apre la finestra di override, "Confirm anyway" resta disabilitato finche' la motivazione non e' valida, la CRF risulta `completed` e l'audit contiene motivo e ticket. Creazione ticket dal dialogo "New Ticket": POST 201 con `crfscope=CRF`, `crf`/`careplan`/`patient` corretti, `qrid` vuoto (CRF non ancora salvata).

**Limiti di questa prova:** la ricerca utenti/gruppi di Zammad per campo restituisce sempre vuoto senza Elasticsearch (rischio R4): nel solo test del dialogo "New Ticket" quelle due risposte sono simulate nel browser; la casella dell'override nel form dei gruppi e' verificata solo da `tsc` (la pagina non e' raggiungibile dall'utente di prova); certificazione e percorso del paziente (link con token) solo unit test. I dati di prova (alcune QR del paziente 8383 ora `completed`, ticket 24-32 su Zammad locale) restano nel dump locale.
**CI:** i branch dei microservizi usano le nuove classi di `irccs-common` (`CrfKey`, `CrfTicketGate`...) con `i3.common.version=27.0.0`: la build Jenkins fallira' finche' `irccs-common` non e' rilasciato e le versioni non sono aggiornate.

### 13.7 Gestione dei ticket dentro la piattaforma (Fase 2, 2026-10-22)
Branch `feature/ticket-drawer` (microservizio Zammad, impilato su `feature/ticket-ref-sync`; dashboard impilato su `feature/ticket-gate-ui`) + risorse Keycloak in `feature/ticket-ref-install`.

**Cosa c'e'**
- **Elenco** dei ticket della CRF (`GET /fhir/zammad/tickets/by-crf?patient&careplan&questionnaire&all`): gli id vengono dai `Task ticket-ref` su HAPI (non dalla ricerca di Zammad, che senza indice non trova nulla), poi ogni ticket e' filtrato per permessi su Zammad. Di default solo i non chiusi.
- **Conversazione** (`GET /{id}/articles`): solo testo (HTML, script e handler tolti lato server), mai indirizzi email dei mittenti, allegati solo come nome/dimensione, note interne solo a chi ha permesso di scrittura.
- **Risposta** (`POST /{id}/articles {body}`): nota pubblica a nome dell'utente reale (X-On-Behalf-Of impostato solo lato server dal login dell'utente, mai dal client), testo non vuoto, massimo 20000 caratteri.
- **Chiusura** (`POST /{id}/close {reason}`): motivazione obbligatoria (>= 5 caratteri), scritta prima come articolo nella storia e poi cambio stato; **riapertura** (`POST /{id}/reopen`, motivo facoltativo). Stato aggiornato subito sul `Task` (senza attendere il webhook).
- **Dashboard:** bottone **Tickets** accanto a New Ticket e chip "N open tickets" della conferma aprono un pannello laterale (aperti/tutti, conversazione a fumetti, risposta, chiusura con motivo, riapertura, "New ticket"). Si aggiornano chip, bottone di conferma e conteggi. Stringhe it/en.
- Risorse Keycloak: `ByCrf`, `Articles` (GET lettura / POST aggiornamento), `StateChange` (`add-zammad-authz.py`).

**Verifiche:** ms Zammad 132 test; `tsc` pulito. Sul vivo (pascale-local, utente reale `alessandra.molaro`): API **23/23** (elenco, conversazione pulita da HTML/script/email, nota interna visibile a chi puo' scrivere, risposta attribuita all'utente reale su Zammad, risposta vuota e chiusura senza motivo rifiutate, chiusura con motivo scritta nella storia, Task `closed`, riapertura, e 403 su conversazione/risposta/chiusura di un ticket di un gruppo non autorizzato che inoltre non compare nell'elenco); browser **9/9** (apertura pannello, elenco, conversazione senza HTML, risposta, chiusura con motivo obbligatorio, riapertura disponibile, e dopo la chiusura del solo ticket aperto chip sparito e Confirm CRF abilitato).

**Limiti / non fatto:** allegati non scaricabili ne' caricabili dal pannello (si vedono solo i nomi; per i file resta Zammad); nessuna regola su "chi puo' chiudere" oltre al permesso di scrittura sul ticket (la regola "chi risponde non chiude da solo" non e' implementata); nessuna notifica a chi deve rispondere (restano le email di Zammad); niente aggiornamento in tempo reale oltre al refresh ogni 20 secondi e al ritorno sulla finestra; nessun pannello per i ticket di studio; non provato con piu' utenti in conversazione contemporanea. Con Zammad senza Elasticsearch il dialogo "New Ticket" non offre i gruppi (ricerche per campo vuote, R4).

### 13.8 Visibilita' dei ticket = visibilita' dell'applicazione (2026-10-22)
Branch `feature/ticket-visibility` (microservizio Zammad, impilato su `feature/ticket-drawer`). **Sostituisce** la regola di 13.7 basata sui permessi dei gruppi Zammad.

**Regola.** Un ticket di CRF e' visibile (e utilizzabile) da chi vede il **paziente** a cui si riferisce nell'applicazione, con gli stessi scope e contesto: organizzazione/gruppo attivo (`X-Context-Token`/`X-Active-Group`), studio, superadmin. La regola **non e' riscritta** nel microservizio Zammad: `PatientVisibility` legge `GET /fhir/Patient/{id}` dell'applicazione (anagrafica-pazienti) con le credenziali e le intestazioni di contesto dell'utente; **200 = visibile**, qualunque altro esito o errore di rete = non visibile (fail-closed). Risposte in cache 30 s per (utente, contesto, paziente). Ogni evoluzione della visibilita' dell'applicazione vale quindi subito anche per i ticket, e ogni verifica lascia la traccia di audit di lettura del paziente.

| Operazione | Condizione |
|---|---|
| Elenco / conversazione / riepilogo della CRF | paziente visibile nel contesto attivo |
| Rispondere, chiudere, riaprire | paziente visibile + ruolo Keycloak `zammadticket:update` (gia' imposto dal policy enforcer) |
| Aprire un ticket di CRF | paziente indicato **obbligatorio** e visibile; i ticket di studio (annunci) non hanno un paziente da verificare |
| Senza contesto attivo (non superadmin) | 403, come nell'applicazione |
| Note interne | solo chi ha `change`/`full` sul gruppo Zammad del ticket o ne e' l'assegnatario (chi ha solo aperto il ticket non le vede) |

**Esecuzione su Zammad.** L'utente deve comunque avere un utente Zammad collegato (`keycloak_ref`) per l'identita'. Se Zammad nega all'utente (nessun permesso sul gruppo Zammad) ma l'applicazione gli consente il ticket, la scrittura parte con l'identita' di servizio e il nome dell'utente in testa al messaggio (`[Nome - via piattaforma]`: Zammad ignora `from` per gli agenti).

**Configurazione.** `zammad.visibility.enforce` (default `true`; `false` solo per sviluppo), `zammad.visibility.patient-url` (default `http://irccs-anagrafica-pazienti:8080/fhir/Patient`; adattare al nome del servizio dell'ambiente).

**Verifiche (pascale-local, utenti reali di due organizzazioni):** test unitari ms Zammad 146; `e2e_visibility.py` **14/14** — `alessandra.molaro` (IRCCS Sperimentatori) vede, risponde e apre ticket sul paziente 8383; `b.daniele` (ASL Napoli 1 Centro, con permessi Zammad **pieni**) riceve 403 su elenco, conversazione, risposta, chiusura, apertura e riepilogo, esattamente come l'applicazione (`GET Patient/8383` -> 403 per lui); senza contesto attivo 403; con soli permessi `create` su Zammad molaro vede e risponde comunque. Regressione: pannello API **23/23**, browser **9/9**. (I test `e2e_roles.py` di conferma/override non sono ripetibili sugli stessi dati: le CRF sono gia' `completed`.)

**Resta fuori da questa regola (ancora sui permessi dei gruppi Zammad):** `GET /tickets/{userId}/myTicket` (badge della barra), `PUT /tickets/{id}`, gli annunci di studio e la ricerca di utenti/gruppi. **Chip e pannello** possono differire solo se un ticket e' di un altro paziente con la stessa chiave: non avviene, perche' la chiave contiene il paziente.

### 13.9 Chiusura e riapertura dei ticket: solo con la capability del gruppo (2026-10-22)
Branch `feature/ticket-close-capability` (microservizio Zammad su `feature/ticket-drawer`; dashboard su `feature/ticket-drawer`; ruolo in `feature/ticket-ref-install`). Variante concordata con l'utente ("B").

**Regola.** Chiudere e riaprire un ticket e' consentito **solo a chi ha la capability `internal:close:ticket` nel gruppo attivo** (spuntata sul gruppo dal form "Gruppi utenti", sezione CRF) o e' superadmin senza contesto selezionato. Chi ha **aperto** il ticket o vi ha risposto **non puo' chiuderlo da solo**. Rispondere resta consentito a chi vede il paziente (13.8). La capability si legge dal contesto attivo con `CallerScope`, come nell'applicazione; qualunque errore di lettura = non puo' chiudere.
- La regola vale anche per `PUT /tickets/{id}` con lo stato di chiusura (`zammad.ticket.closed-state-id`, default 4): nessuna scorciatoia dal pannello.
- La conversazione espone `canClose`; il pannello mostra "Close ticket"/"Reopen ticket" solo se `true`, altrimenti scrive "Closing is reserved to authorised groups."
- La motivazione resta obbligatoria alla chiusura (>= 5 caratteri), scritta prima nella conversazione.
- **Fuori dal nostro controllo:** gli agenti Zammad che chiudono dall'interfaccia di Zammad seguono le regole di Zammad.

**Ruolo:** `keycloak-config/add-ticket-gate-roles.py` crea ora anche `internal:close:ticket`. Script per le prove locali: `specs/spike-zammad-webhook/capability-gruppo.sh on|off close|override|confirm`.

**Verifiche (pascale-local, utente reale molaro, gruppo Sperimentatori):** ms Zammad 154 test (anche con token di contesto firmato, firmato con altra chiave e senza contesto); `e2e_close.py` **15/15** — senza capability chi ha aperto il ticket legge e risponde ma non chiude (403 dal pannello e dal PUT, ticket e Task restano aperti, CRF resta bloccata); col gruppo abilitato chiude, riapre, anche dal PUT; tolta la capability non puo' piu' riaprire; pannello API **23/23**; browser **12/12** (senza capability il pulsante non c'e' e il pannello spiega il motivo, ma si puo' rispondere; con la capability e un nuovo login chiusura con motivo, riapertura, chip che sparisce).
