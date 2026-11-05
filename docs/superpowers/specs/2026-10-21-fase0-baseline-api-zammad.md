# Fase 0 — Baseline delle API Zammad usate e cambi di comportamento (2026-10-21)

Codice: worktree `irccs-microservice-zammad/.claude/worktrees/crf-query` (branch `feature/crf-query`, sopra develop `48420a7`). Stato: modifiche **non committate** oltre al commit `a8a9d46`.

## 1. Chi chiama cosa (dashboard, grep su `src/`)

| Chiamata dashboard | Dove | Endpoint ms | Prima | Dopo la Fase 0 |
|---|---|---|---|---|
| ricerca utente per email | `AuthContext`, `TicketContext`, `useTicketService` | `GET /fhir/zammad/users/search?query=email:..` | passthrough, qualunque query | **invariato** (vedi rischio R1) |
| ricerca utente per id | `CrfTherapyRenderer:226` | `GET .../users/search?query=id:..` | passthrough | **invariato** (R1) |
| ricerca gruppi destinatari | `CrfTherapyRenderer:231`, `PatientJourneyCrudFormNew:442` | `GET .../groups/search?query=..` | passthrough | **invariato** (R1) |
| conteggi ticket (NavBar, Dashboard, annunci) | `TicketContext:53`, `useTicketService:40` | `GET .../tickets/{userId}/myTicket` | qualunque `userId`, nessun filtro sul risultato | `userId` deve essere il chiamante (403 altrimenti); risultato filtrato per policy; **stesso formato** (array di ticket) |
| crea ticket CRF / query | `CrfTherapyRenderer:257` | `POST .../tickets` | body inoltrato in blocco a Zammad | validato (vedi §2) |
| crea ticket di studio / annuncio | `PatientJourneyCrudFormNew:470` | `POST .../tickets` | body inoltrato in blocco | validato (vedi §2) |
| — non usati dalla dashboard — | | `GET .../tickets`, `GET .../tickets/search`, `PUT .../tickets/{id}`, `DELETE .../tickets/{id}` | aperti | list/search/DELETE → 403; PUT solo `state_id`/`priority_id`/`pending_time` con permesso `change`/`full` o parte in causa |

## 2. Cambi di comportamento da verificare nel collaudo (rischio regressione)

1. **Identita'.** Il chiamante si risolve per `keycloak_ref` = `sub` del JWT (valorizzato dalla sincronizzazione `ZammadSyncService`). Un utente Zammad **non ancora collegato** riceve 403 su `myTicket` e creazione: i badge restano a 0 e il "nuovo ticket" fallisce. Mitigazione: eseguire la sincronizzazione utenti prima del rilascio (`/sync`); ripiego temporaneo `zammad.caller.email-fallback=true` (solo utenti senza `keycloak_ref`, email verificata). **Da verificare in preprod** che tutti gli utenti abilitati siano collegati.
2. **Utenti disattivati o con `keycloak_ref` duplicato** → 403.
3. **myTicket**: il permesso sul gruppo e' ora letto come elenco esatto (`read`/`change`/`full`; `overview` e `create` da soli non danno lettura). Prima contava `full`/`4` e la stringa `[READ, OVERVIEW]`. Possibili differenze nei conteggi per i gruppi `annunci_*`: confrontare i conteggi prima/dopo su preprod.
4. **Creazione ticket**:
   - `customer_id` deve coincidere con il chiamante (la dashboard gia' invia `zammadUserId`); se assente viene impostato.
   - Campi ammessi: `title, group_id, customer_id, state_id, pending_time, crf, crfdisplay, careplan, careplandisplay, patient, patientdisplay, patientjourneydisplay, directlink, crfscope, qrid, tags, article{body,subject}`. Altri campi (`owner_id`, `priority_id`, ...) → 422.
   - `state_id` ammesso: `zammad.ticket.creatable-state-ids` (default `1,2,7`; 7 = stato custom degli annunci). **Verificare che il valore 7 coincida con lo stato custom sulla nostra istanza.**
   - `article`: sempre `type=note`, `internal=false`; `internal`, `type`, `sender`, allegati non impostabili. `pending_time` vuoto (`""`, come invia il form di studio) viene scartato.
   - Limiti di lunghezza: titolo 250, attributi 255, `directlink` 2000, testo articolo 20000.
5. **Errori 5xx** non contengono piu' `e.getMessage()` ne' query; header del client mai inoltrati (incl. `X-On-Behalf-Of`, `Cookie`).

## 3. Rischi residui trovati (fuori dal perimetro dei ticket)

- **R1 — users/groups/organizations non delimitati.** `/fhir/zammad/{users,groups,organizations}` sono passthrough con il token di servizio: la protezione e' solo il ruolo Keycloak (`zammad<entita'>:<azione>` creati da `keycloak-config/add-zammad-authz.py`). Un utente con `zammadusers:search` puo' cercare **qualunque** utente (email, telefono, gruppi) e, se ha `create/update/delete`, modificarli. La dashboard usa solo `users/search` (propria email/id) e `groups/search`. Proposta: restringere `users/search` al solo chiamante e chiudere create/update/delete lato ms. Da decidere (impatto: ruoli e altri consumatori).
- **R2 — gruppo di destinazione libero.** Alla creazione `group_id` non e' vincolato ai gruppi ammessi: chi ha il permesso puo' aprire ticket in qualunque gruppo (non puo' pero' leggere quelli altrui). Da vincolare quando sara' definito il legame gruppo Zammad <-> centro/studio.
- **R3 — stato 7.** Gli stati di default Zammad 7.2.2 hanno id diversi (vedi report spike); la configurazione `updatable-state-ids` (`1,2,3,4,6`) e `creatable-state-ids` (`1,2,7`) assume gli id della nostra istanza. Da confrontare con `GET /ticket_states` in produzione (sola lettura, con tuo OK).
- **R4 — risoluzione utente dipende dalla ricerca Zammad.** `keycloak_ref:"<sub>"` usa `users/search`; con Elasticsearch spento la ricerca restituisce vuoto (spike) e tutti riceverebbero 403. In produzione la ricerca per email gia' funziona (e' usata dalla dashboard), quindi presumibilmente ES e' attivo: **da confermare** prima del rilascio.
- **R5 — token di servizio in chiaro** nel repo (decisione del committente): da ruotare e spostare in secret prima del go-live.

## 4. Verifiche eseguite / da eseguire

| Passo | Esito |
|---|---|
| Test unitari + HTTP con Zammad finto | 75 test verdi (identita' per `keycloak_ref`, fallback, utente disattivato/duplicato, policy, guard PUT, guard creazione, forward senza header client) |
| Regressione end-to-end su stack locale con Keycloak + ms + dashboard | **non eseguita** (richiede lo stack `pascale-local` completo e utenti Zammad collegati); da fare prima del merge, con la checklist del documento funzionale §9 |
| Confronto conteggi `myTicket` prima/dopo | da fare in preprod |

## 5. Esito della regressione E2E (2026-10-22)

Ambiente: `pascale-local` (Keycloak 26 + microservizio Zammad costruito dal branch `feature/crf-query`) + Zammad 7.2.2 locale **senza Elasticsearch**. Script: `specs/spike-zammad-webhook/e2e_fase0.py` + `e2e-override.yml`. Utente reale Keycloak collegato a un utente Zammad via `keycloak_ref`.

Risultato: **21/21** casi superati (token Keycloak vero, policy enforcer attivo): ricerca utenti ridotta al solo chiamante, GET/POST users e POST groups, ricerca organizzazioni e ruoli = 403, `groups/search` = 200, `myTicket` proprio 200 e di altro id 403, lista/search/DELETE ticket = 403, creazione valida 201 (customer, attributi custom e articolo `note` pubblico verificati su Zammad), creazione a nome di altri 403, con `owner_id` o articolo interno 422, PUT sul proprio ticket e su gruppo con `change` 200, su gruppo riservato 403, campo non ammesso 422. Un utente Keycloak non collegato a Zammad riceve 403 su tutto.

Trovato durante il test e corretto: la ricerca `keycloak_ref:"<sub>"` dipende dall'indice di Zammad (senza ES restituisce sempre vuoto) e avrebbe respinto tutti. Ora, se la ricerca per campo non trova nessuno, si cercano i candidati con ricerca libera per email e l'identita' si prova dal `keycloak_ref` del record (deve coincidere col subject). Il rischio R4 resta per le **query per campo** (`email:`, `id:`) della ricerca utenti con ES spento, usate dalla dashboard.

Limiti: `myTicket` e' stato verificato solo come contratto (200, array) perche' senza ES la ricerca ticket di Zammad e' vuota: il filtro per policy e' coperto dai test unitari/HTTP, non dall'E2E. Nel Keycloak locale: aggiunto admin `e2eadmin` (master), eseguito `add-zammad-authz.py`, assegnati ruoli `zammad*:*` e password di prova a due utenti (`a.gimigliano@test.it`, `b.daniele@test.it`): solo ambiente locale. Le credenziali admin del `.env` locale non funzionano piu' sul Keycloak (dump ripristinato il 29/09), per cui anche la sincronizzazione utenti Keycloak->Zammad del ms fallisce con 401 in locale.
