# Piano v2: ticket Zammad in-piattaforma + gate "Conferma CRF"

Data: 2026-10-21. Stato: v2 dopo revisione cliente / PM / architect FHIR (mediata). Da approvare dall'utente prima di iniziare.

## 1. Stato attuale (verificato)
- ms zammad (`develop`): proxy trasparente col token di servizio, nessuna authz per ticket, inoltra header client (incl. X-On-Behalf-Of), `/search` e GET-all aperti, 500 con `e.getMessage()`, nessun endpoint articoli/allegati/webhook, test quasi assenti.
- Worktree `irccs-microservice-zammad/.claude/worktrees/crf-query` (snapshot dangling, 10 file non committati): `TicketAccessPolicy`, `TicketGuard`, `ZammadCallerService` (identita' da email JWT), header non inoltrati, `/search`->403, `myTicket` filtrato.
- Conferma CRF: il FE salva la `QuestionnaireResponse` con `status=completed` (`CrfTherapyRenderer.tsx:704`, bottone `:1293`). Unico choke point server-side: `irccs-common/.../QuestionnaireResponseFlow.enforceCrfConfirmation` (~626-665), che **esclude le SAE** e scatta anche su `create` gia' completed. `CrfCertificationService` NON e' un punto di conferma.
- Ticket CRF creati con attributi `crf` (= id Questionnaire), `careplan`, `patient` (`CrfTherapyRenderer.tsx:244-269`): non c'e' `qrid`. Ticket di studio: `state_id 7`, `crf='00000'`.
- Altri lavori sulla stessa funzione `enforceCrfConfirmation`: `sae-dm-confirm` (worktree committato) e crf-check (worktree non committato). Rischio conflitti.
- Spec/piani A-B-C del 12/10 non piu' presenti in `docs/superpowers/{specs,plans}`.

## 2. Esito della mediazione (decisioni proposte)

| Tema | Cliente | PM | Architect | **Decisione proposta** |
|---|---|---|---|---|
| Ordine consegna | gate e sicurezza prima del drawer | MVP piccolo, flag OFF | hardening prima di tutto | **F0 hardening -> F1 gate -> F2 drawer** |
| Dove vive lo stato per il gate | Zammad (stato reale) | REST a Zammad | Task FHIR sottile | **Task FHIR `ticket-ref` solo stato (no testo/allegati), scritto solo dal ms zammad; gate = search HAPI** |
| Zammad giu' | fail-closed + override | fail-open + allarme | fail-closed + override | **Con il Task il gate non dipende da Zammad: l'unico "indeterminato" e' HAPI giu' (la PUT QR fallirebbe comunque) -> fail-closed + override tracciato** |
| Stati bloccanti | new/open/pending reminder/pending close | da chiedere | pending blocca (da confermare) | **tutto tranne closed/merged blocca**; pending sempre mostrato con scadenza/responsabile |
| Granularita' | per singola CRF | da chiedere | per istanza + ciclo opz. | **per CRF = chiave logica (Questionnaire+CarePlan+Patient), `qrid` quando esiste; ticket su ripetizione blocca la QR intera; `instance/linkId` rimandati (servono solo ai badge)** |
| Flag | - | default OFF, per studio | - | **`crf.confirm.require-closed-tickets` default OFF; attivazione per studio dopo backfill + report ticket non agganciabili + data di entrata in vigore** |
| Override | si, motivato e tracciato | - | si, BusinessEvent | **ruolo dedicato `internal:override:ticket-gate`, motivazione obbligatoria, audit BusinessEvent** |
| Ticket di studio | nel drawer, non bloccano | - | esclusione per `crfscope`, non per magic value | **attributo `crfscope` (CRF/STUDY); STUDY mai bloccante** |
| Chi chiude / riapre | opener, DM centro, responsabile; il rispondente non chiude da solo | - | - | **enforcement nel `TicketGuard` del ms** |
| Scadenza perimetro 12/10 | riconferma lui | chiede ok formale | limitare a stato, non messaggi | **estensione: stato in FHIR (Task), messaggi restano in Zammad; da scrivere nella spec** |

Residuo accettato e documentato: check-then-act senza lock (ticket riaperto tra check e PUT). Mitigazione: evento di audit "ticket aperto dopo conferma"; nessun auto-unlock.

## 3. Architettura finale

### 3.1 Dati
- Zammad: fonte di contenuti/messaggi/allegati/PHI. Nuovi attributi Ticket: `crfscope`, `qrid` (opz.). Backfill dei legacy con script che risolve la QR; report degli ambigui/non agganciabili (mai trattati come "non bloccano").
- HAPI: `Task` code `ticket-ref` (stile `sae-query`): `focus`=QuestionnaireResponse (se c'e'), altrimenti chiave logica in `for`(Patient)/`input`(Questionnaire, CarePlan); `identifier`=id Zammad; `status` riflesso; `businessStatus`=stato Zammad; `input` URL. Nessun testo.
- Sync: webhook Zammad (HMAC, anti-replay) -> ms -> Task; riconciliazione periodica (`SyncScheduler` esistente) per webhook persi. Zammad creato da UI senza attributi => segnalato nel report.

### 3.2 ms zammad (anti-corruption layer, unico accessore di Zammad)
- F0: finire/mergiare `crf-query`; identita' stabile per X-On-Behalf-Of (subject Keycloak / login, non email); niente `e.getMessage()` nelle 500; test (policy, guard, HTTP mock).
- F1: webhook + scrittura Task `ticket-ref`; `GET /crf/{key}/tickets/summary` (+ elenco bloccanti con owner/eta').
- F2: lista/thread/articoli/reply/state/allegati con policy su ticket, articoli, allegati; articoli interni filtrati lato server; HTML sanitizzato lato server; allegati in streaming con Content-Disposition attachment + nosniff, limiti tipo/dimensione.
- Interfaccia `TicketProvider` e IG solo in F4.

### 3.3 Gate (common)
- In `enforceCrfConfirmation` (e nel `create` gia' completed): search HAPI Task `ticket-ref` aperti per chiave logica, escluso `crfscope=STUDY`. 409 `CRF_OPEN_TICKETS` con conteggio/lista. Override con ruolo+motivo (come trasportarlo: header/extension, da definire in design). Da decidere se estendere a `/certify`.
- SAE: oggi esclusa da `enforceCrfConfirmation`; fuori scope MVP (decisione cliente).
- Verificare che nessun altro writer (QuestionnaireExpiryService, QuestionnaireCompilationLifecycle, PatientQuestionnaireResponseController, BundleController create) scriva `completed` aggirando il Flow; PATCH da verificare.

### 3.4 Dashboard
- F1: chip "N ticket aperti" accanto a "Conferma CRF", bottone disabilitato con tooltip e lista dei ticket bloccanti (link diretto a Zammad); gestione 409; vista DM "CRF bloccate" per studio/centro; i18n it/en.
- F2: `TicketDrawer` (MUI, destro, full-screen mobile): lista, thread, reply, chiudi/riapri con motivazione, "Nuovo ticket"; ticket di studio nel drawer (non bloccanti). Dietro feature flag.
- Rimandati: SSE, badge per domanda, note interne, sostituzione polling `myTicket` (rischio regressione conteggi NavBar/annunci), allegati nel drawer (v1: link a Zammad).

## 4. Sequenza e stime
0. **Pre-requisiti** (con tuo OK esplicito, regola no-auto-commit): mettere al sicuro su branch `crf-query` (zammad), `crf-check-query` (common); decidere ordine merge su `enforceCrfConfirmation` con `sae-dm-confirm` e crf-check; ricostruire spec A/B/C; spike 0,5 gg su webhook/trigger Zammad 7.2.2 locale (mai sul Zammad infocube reale).
1. **F0** hardening ms (4-6 gg).
2. **F1** Task `ticket-ref` + sync + summary + gate 409 + override + chip + report/backfill (8-10 gg).
3. **F2** drawer lettura/risposta/stato (6-8 gg).
4. **F3** allegati, SSE, badge, polling (10-14 gg), **F4** provider astratto/IG/R5 (fuori da questo impegno, da quotare a parte).
MVP rilasciabile = F0+F1 con flag OFF, poi attivazione per studio.

## 5. Accettazione
- F0: utente senza permessi -> 403 sui ticket altrui; header client non inoltrati; test verdi; checklist regressione (creazione ticket CRF/studio, annunci, conteggi, SSO).
- F1: con ticket aperto, PUT diretto QR->completed da API restituisce 409; con flag OFF comportamento identico a oggi; ticket di studio non bloccano; override senza motivo rifiutato e con motivo in audit; webhook perso recuperato dalla riconciliazione; HAPI giu' -> errore, non conferma; E2E su pascale-local.
- F2: drawer mostra solo ticket autorizzati; XSS test sugli articoli; chiusura secondo regole ruolo; Playwright.

## 6. Decisioni da prendere con l'utente
1. Ok al Task `ticket-ref` solo-stato (estensione della decisione 12/10)?
2. Pending blocca (cliente si')? 
3. CRF gia' confermata + nuovo ticket: solo avviso+audit, o procedura di riapertura/unlock?
4. Estendere il gate a `/certify`? SAE confermate: esclusa o con gate?
5. Chi ha il ruolo override.
6. Messa in sicurezza dei worktree (commit su branch) e ordine di merge su `enforceCrfConfirmation`.
7. Token Zammad in chiaro: confermi di lasciarlo (architect consiglia rotazione/secret in prod)?
8. Regole PHI/retention dei ticket e allegati (DPO) prima del go-live.
