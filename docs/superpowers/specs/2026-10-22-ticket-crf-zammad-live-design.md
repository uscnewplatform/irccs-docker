# Ticket CRF "tutto a Zammad" — design

Data: 2026-10-22. Stato: **da approvare**. Sostituisce, se approvato, la versione con copia dei ticket in HAPI
(branch `feature/PASTRL-720/ticket-crf-gate`, che resta intatto come alternativa).

## 1. Perche'

La versione attuale copia lo stato di ogni ticket in HAPI (`Task ticket-ref`), lo tiene allineato con un webhook e con
una riconciliazione ogni 5 minuti, e registra un heartbeat. Funziona, ma costa installazione (webhook, segreto,
configurazione montata, script di allineamento) e manutenzione. Si vuole una versione piu' leggera in cui **Zammad e'
l'unica fonte**: il blocco della conferma CRF chiede a Zammad, al momento, se ci sono ticket non chiusi.

## 2. Obiettivi, non obiettivi

Obiettivi
- Stesso comportamento per l'utente: "Conferma CRF" bloccata se la CRF ha ticket non chiusi; elenco dei ticket aperti
  in home paziente; icone sui cicli, passi e schede.
- Nessuna copia dei ticket in HAPI, nessun webhook, nessuna riconciliazione, nessun heartbeat.
- Meno passi di installazione.

Non obiettivi
- Non cambia il pannello ticket (lettura, risposta, chiusura, riapertura), la visibilita' per paziente, le capability
  (`internal:confirm:crf`, `internal:close:ticket`, `internal:override:ticket-gate`) ne' la deroga con audit sincrono.
- Flag del blocco resta globale (non per studio), spento di default.
- Nessuna notifica, nessun allegato scaricabile (invariati).

Anti-obiettivo: se Zammad non risponde, **mai** lasciar confermare "per sicurezza di disponibilita'".

## 3. Decisioni dell'utente

- Zammad e' l'unica fonte dello stato dei ticket.
- Zammad non raggiungibile o lento: **errore e conferma impossibile** (fail-closed).
- Messaggio mostrato al medico: «Sistema di ticket in manutenzione. Riprovare o contattare l'assistenza».
- Con il sistema ticket in manutenzione **nessuna deroga** alla conferma: la deroga con capability vale solo quando
  Zammad risponde e ci sono ticket aperti, mai quando lo stato non e' verificabile. La regola e' **attivabile a
  richiesta** con la proprieta' `crf.confirm.override-when-unverifiable` (default `false`): se messa a `true`, la
  deroga vale anche con stato non verificabile (comportamento della versione precedente).

## 4. Verifica tecnica gia' fatta (Zammad locale, Elasticsearch spento)

- `GET /tickets/search?query=patient:X` restituisce 0 senza Elasticsearch: **non usabile**.
- `POST /api/v1/tickets/search` con `condition` sui campi custom funziona senza Elasticsearch, con confronto esatto
  lato server (`383` non trova `8383`). Esempio:

```json
{"condition":{
  "ticket.patient":{"operator":"is","value":"8383"},
  "ticket.careplan":{"operator":"is","value":"8971"},
  "ticket.crf":{"operator":"is","value":"5775"},
  "ticket.state_id":{"operator":"is not","value":["4","5"]}}}
```

- Con paziente + percorso + CRF su 52 ticket di prova ne ha trovati 16; escludendo chiusi e uniti, 13.

## 5. Architettura

```
Dashboard ─┐
studio-clinico ──► ms zammad ──► Zammad (POST /tickets/search con condition)
└─ 1 sola chiamata, nessuna copia
```

- **Solo il ms zammad parla con Zammad** (il token resta li'). Studio-clinico non riceve mai il
  token: il gate in `irccs-common` chiama un endpoint interno del ms zammad.
- Nuovo endpoint del ms zammad: ticket non chiusi di una CRF (paziente + percorso + questionario), di un paziente,
  e conteggio. Risposta: elenco di `{ticketId, state}` oppure errore.
- Il ms zammad classifica lo stato per `state_type` di Zammad (come oggi): new, open, pending reminder, pending action
  bloccano; closed e merged no; tipo sconosciuto blocca. La mappa stato -> tipo si legge da `GET /ticket_states`.
  Le condizioni di ricerca usano gli id degli stati *non* bloccanti, calcolati dalla mappa.
- Il gate (`CrfTicketGate` in `irccs-common`) cambia sorgente: invece di cercare `Task` su HAPI chiama il ms zammad.
  Gli esiti restano CLEAR / BLOCKED (409 `CRF_OPEN_TICKETS`) / INDETERMINATE (503 `CRF_TICKET_STATE_UNVERIFIABLE`).
  INDETERMINATE ora significa "Zammad non risponde, e' lento o ha risposto in modo non valido".
- La conferma CRF, la deroga (header `X-Ticket-Gate-Override-Reason` + capability + audit sincrono) e `/certify`
  (blocca su qualunque CRF del paziente, senza deroga) non cambiano come regole, cambia solo da dove arriva la risposta.
- La deroga **non** copre il caso "sistema in manutenzione": se non si puo' verificare, non si conferma neanche con
  deroga (decisione dell'utente, sezione 3).

## 6. Cosa si toglie

| Dove | Cosa |
|---|---|
| ms zammad | pacchetto `ticketref` (scrittura Task, riconciliazione, heartbeat), endpoint webhook, verifica HMAC |
| irccs-common | lettura Task e heartbeat nel gate, `TicketRefConstants`, `TicketStateMapper` (la classificazione passa al ms zammad), `CrfKey` resta |
| irccs-docker (+ prod) | `install_zammad_webhook.sh`, `paths.7` del webhook, variabili `ZAMMAD_TICKET_REF_ENABLED`, `ZAMMAD_INSTANCE_ID`, `ZAMMAD_WEBHOOK_SECRET`, `CRF_CONFIRM_TICKET_SYNC_MAX_AGE`; passi 5 e 7 dello script di allineamento |
| docs | guida di produzione e pagina `ticket-crf.adoc` da riscrivere (parte sincronizzazione) |

Restano: attributi Zammad (`crfscope`, `qrid`, `patient`, `careplan`, `crf`), script Keycloak (ruoli, risorse authz con
`ByPatient`), `PatientVisibility`, pannello ticket, capability.

## 7. Dashboard

- Messaggio per `CRF_TICKET_STATE_UNVERIFIABLE`: chiave i18n in it/en/de/fr con il testo dell'utente in italiano:
  «Sistema di ticket in manutenzione. Riprovare o contattare l'assistenza».
- Elenco ticket aperti in home paziente e icone: stessi componenti, la sorgente e' l'endpoint live. Se Zammad non
  risponde, la home non si rompe: il riquadro mostra lo stesso messaggio di manutenzione.
- Le icone (indice per ciclo e per CRF) arrivano da una sola chiamata per paziente, come oggi.

## 8. Cose che cambiano nel comportamento (da sapere)

- Ogni conferma CRF fa una chiamata a Zammad (prima leggeva HAPI). Con il flag spento nessuna chiamata.
- Se Zammad e' giu', **nessuno** conferma le CRF (con il flag acceso). E' la conseguenza voluta.
- Stato dei ticket sempre aggiornato (niente ritardo di 5 minuti, niente heartbeat da monitorare).
- Un ticket cancellato in Zammad smette di bloccare subito (prima serviva la riconciliazione).
- Patient link (compilazione del paziente): resta come oggi, blocca solo se sa con certezza che ci sono ticket aperti;
  un errore di Zammad non ferma il paziente (non e' lui a poter sistemare Zammad), resta tracciato nei log.

## 9. Scelte del costruttore (da rivedere)

- **Timeout** della chiamata a Zammad: 3 secondi, configurabile (`zammad.ticket-lookup.timeout`). Oltre: INDETERMINATE.
- **Paginazione**: si chiede una pagina da 200; se ne tornano 200 si continua a paginare fino a esaurire; oltre 1000
  risultati per paziente: INDETERMINATE e log.
- **Cache**: nessuna cache dello stato dei ticket (sarebbe di nuovo uno stato da tenere allineato). Si memorizza solo
  la mappa stati -> tipo (rinfrescata ogni 10 minuti).
- **Nuovo branch** per repo, da quello attuale: `feature/PASTRL-720/ticket-crf-zammad-live`. Quello vecchio non si tocca.

## 10. Rischi e da verificare in produzione (sola lettura)

- Stato personalizzato 7 di Zammad: capire il suo `state_type` (se sconosciuto, blocca).
- Permessi del token del servizio: deve poter cercare in tutti i gruppi di ticket.
- Carico: una ricerca per conferma; verificare i tempi su dati reali (decide se 3 s bastano).
- Ticket creati direttamente in Zammad senza i campi `patient`/`careplan`/`crf` non sono visti dal blocco (invariato).
- Il token Zammad in chiaro nel repo va ruotato prima del go-live (invariato).

## 11. Verifica

- Test unitari del gate con un Zammad finto: CLEAR, BLOCKED, timeout, errore 5xx, risposta malformata, paginazione piena.
- Test del ms zammad sulla costruzione della condizione e sulla classificazione degli stati.
- E2E su `pascale-local` + Zammad di prova: ticket aperto -> 409; chiuso -> ok; Zammad fermo -> 503 con il messaggio;
  deroga con capability su ticket aperto -> ok + audit; home paziente e icone.
- Il Zammad di prova locale ha Elasticsearch spento: e' lo scenario peggiore, quindi una buona prova.


## Aggiornamento 22/10 (sera)

Decisione del cliente: `patient-interview` e le compilazioni del paziente (link con token) sono fuori dal blocco dei ticket. Il blocco resta sulla conferma del medico (`QuestionnaireResponseFlow`) e sulla certificazione.
