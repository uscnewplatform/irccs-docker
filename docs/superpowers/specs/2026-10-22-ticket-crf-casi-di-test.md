# Ticket CRF — casi di test funzionali e di accettazione

Data: 2026-10-22. Versione "tutto a Zammad" (branch `feature/PASTRL-720/ticket-crf-zammad-live`). Riferimenti: design `2026-10-22-ticket-crf-zammad-live-design.md`, guida `2026-10-22-guida-installazione-produzione-ticket-crf.md`.

Colonna **Copertura**: *Unit* = test automatico nel repo; *E2E locale* = provato su pascale-local con Zammad di prova (script non versionati: contengono credenziali locali); *Da provare* = non ancora provato (staging/prod).

## A. Blocco della conferma CRF (flag acceso)

| ID | Scenario | Passi | Atteso | Copertura |
|---|---|---|---|---|
| A1 | CRF senza ticket | Conferma una CRF senza ticket | 200, CRF confermata | Unit + E2E locale |
| A2 | CRF con ticket aperto | Apri un ticket sulla CRF, conferma | 409 `CRF_OPEN_TICKETS`, CRF non confermata | Unit + E2E locale |
| A3 | Ticket chiuso | Chiudi il ticket (anche direttamente in Zammad), conferma | 200 subito, senza attese | E2E locale |
| A4 | Ticket unito (merged) | Unisci il ticket a un altro chiuso, conferma | Non blocca | Unit (classificazione) |
| A5 | Ticket in attesa (pending reminder / pending action) | Metti il ticket in attesa, conferma | Blocca | Unit (classificazione) |
| A6 | Stato personalizzato di Zammad | Ticket in uno stato custom di tipo sconosciuto | Blocca (mai considerato chiuso) | Unit |
| A7 | Ticket di un'altra CRF dello stesso paziente | Ticket su un altro ciclo/questionario | Non blocca questa CRF | Unit |
| A8 | Ticket di studio (`crfscope=STUDY`) | Ticket di ambito studio | Non blocca mai | Unit |
| A9 | Ticket creato direttamente in Zammad, senza paziente/ciclo/CRF | Crea il ticket in Zammad | Non è visto dal blocco (limite noto) | Unit |
| A10 | Flag spento | Conferma con ticket aperti, flag a `false` | Comportamento invariato (200) e nessuna chiamata a Zammad | Unit |

## B. Deroga

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| B1 | Ticket aperti + capability `internal:override:ticket-gate` + motivo 10–500 caratteri | 200, evento audit `ticket-gate-override` scritto prima | E2E locale (200); audit da riverificare |
| B2 | Ticket aperti + motivo valido senza capability | 403 | Unit |
| B3 | Motivo troppo corto/lungo/solo caratteri di controllo | 422 `CRF_OVERRIDE_REASON_INVALID` | Unit + E2E locale |
| B4 | Audit non scrivibile durante la deroga | 503, CRF non confermata | Da provare |
| B5 | Deroga richiesta ma nessun ticket aperto | 200, nessun evento di deroga | Unit |

## C. Sistema di ticket in manutenzione (Zammad non risponde)

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| C1 | Zammad spento, conferma | 503 `CRF_TICKET_STATE_UNVERIFIABLE`, CRF non confermata | E2E locale |
| C2 | Zammad spento, conferma con deroga valida (regola default) | Ancora 503: nessuna deroga | Unit (tabella) + E2E locale |
| C3 | Zammad spento, regola `crf.confirm.override-when-unverifiable=true`, deroga valida | 200 + audit; senza capability 403; motivo corto 422 | Unit + E2E locale |
| C4 | Zammad lento (oltre 3 s) | Come C1 | Unit |
| C5 | Zammad risponde con corpo non valido / HTTP 5xx / più di 1000 ticket per paziente | Come C1, mai "via libera" | Unit |
| C6 | Zammad torna disponibile | Conferma di nuovo possibile, senza interventi | E2E locale |
| C7 | Messaggio al medico | «Sistema di ticket in manutenzione. Riprovare o contattare l'assistenza» in it/en/de/fr | Browser locale (en) |
| C8 | Percorso del paziente (link con token) con Zammad giù | Il paziente NON viene fermato; evento tracciato nei log | Unit |
| C9 | Certificazione (`/certify`) con Zammad giù | 503, nessun OTP emesso, nessuna deroga | Unit |

## D. Certificazione e altri percorsi

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| D1 | Certificazione con ticket aperti su una qualunque CRF del paziente | 409, nessun OTP | Unit |
| D2 | Certificazione senza ticket aperti | Procede alla sfida OTP | Unit |
| D3 | CRF che nasce già completata dal paziente con ticket aperti noti | 409 | Unit |
| D4 | SAE | Esclusi dal blocco | Da provare |
| D5 | PATCH diretta della compilazione / import | Non coperti dal blocco (limite noto) | Documentato |

## E. Pannello ticket e visibilità

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| E1 | Elenco dei ticket della CRF | Solo i ticket della CRF, dal più recente, per chi vede il paziente | Unit + E2E locale |
| E2 | Utente di un'altra organizzazione, anche con permessi pieni su Zammad | 403 su elenco, conversazione, risposta, chiusura, creazione, riepilogo | E2E locale |
| E3 | Utente senza contesto attivo | 403 | E2E locale |
| E4 | Risposta nel pannello | La nota compare in Zammad a nome dell'utente; senza permessi di gruppo Zammad si usa l'identità di servizio con nome in testa | Unit + E2E locale |
| E5 | Chiusura/riapertura | Solo con `internal:close:ticket`, motivazione di almeno 5 caratteri; chi ha aperto il ticket non può chiuderlo senza capability | Unit + E2E locale |
| E6 | Note interne | Non visibili a chi ha solo aperto il ticket | Unit |
| E7 | Testo mostrato | Solo testo, senza HTML, script, email | Unit |
| E8 | Allegati | Non scaricabili (limite noto) | Documentato |

## F. Home paziente e icone

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| F1 | Riquadro «Ticket aperti» in fondo ai pulsanti, chiuso di default, apribile | Elenco con numero, stato, titolo, CRF | E2E locale (browser) |
| F2 | «Apri la CRF» | Porta alla CRF con `careplanId` e `crfId` | E2E locale (browser) |
| F3 | Icone su cicli, passi a sinistra, schede CRF e gruppi | Presenti dove ci sono ticket aperti | E2E locale (browser) |
| F4 | Ticket chiuso | Sparisce subito dall'elenco e dalle icone | E2E locale |
| F5 | Zammad giù | Il riquadro mostra il messaggio di manutenzione, la home non si rompe, niente icone | E2E locale (browser) |
| F6 | Bottone «Conferma CRF» con ticket aperti | Disabilitato senza deroga; con deroga si apre il dialogo | Unit (logica) |
| F7 | Bottone con Zammad giù | Disabilitato anche con il ruolo di deroga (regola default); chip di manutenzione | Unit + browser locale |

## G. Installazione e sicurezza

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| G1 | `open-for-gate` chiamato dal service account | 200, solo `id` e `state` dei ticket | E2E locale |
| G2 | `open-for-gate` chiamato da un utente normale | 403 | E2E locale |
| G3 | Script di allineamento ripetuto | Idempotente; passo 6 verifica la ricerca a condizioni | E2E locale (passo 6) |
| G4 | Zammad di produzione senza Elasticsearch | La ricerca a condizioni funziona | Da provare in produzione (sola lettura) |
| G5 | Tempi su dati reali | La ricerca risponde entro 3 s | Da provare |
| G6 | Stato personalizzato 7 di Zammad in produzione | Tipo noto o blocca | Da provare |
| G7 | Token Zammad | Ruotato e spostato in un secret prima del go-live | Da fare |
| G8 | Log | Nessun token, risposta, nome o email | Revisione codice |
| G9 | Token di servizio con visibilità parziale | In produzione, un ticket in OGNI gruppo Zammad (anche i ristretti) compare nel blocco; da rifare a ogni nuovo gruppo Zammad | Da provare |
| G10 | Rotazione del token | Dopo la rotazione tutto funziona; il vecchio token risponde 401 | Da provare |
| G11 | Indirizzo `crf.confirm.ticket-service-url` | Dal container di studio-clinico il ms Zammad risponde 200 prima di accendere il flag | Da provare |

## H. Casi aggiunti dopo la revisione funzionale

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| H1 | Modifica/chiusura diretta in Zammad dei campi `patient`/`careplan`/`crf` o dello stato | Decisione del cliente (accettare, bloccare i campi, auditare); il comportamento scelto va provato | Da decidere |
| H2 | Ticket riaperto o aperto DOPO la conferma | Decisione del cliente (nessuna azione / avviso / annullo) | Da decidere |
| H3 | Due utenti concorrenti: uno apre un ticket mentre l'altro conferma | La conferma vede lo stato di Zammad al momento della richiesta; documentare la finestra | Da provare |
| H4 | Zammad lento ma funzionante (2–4 s per chiamata) | Nessun falso 503 entro 3 s verso Zammad e 5 s verso il ms; oltre, 503 | Da provare (strumento per rallentare Zammad) |
| H5 | Rete rotta, DNS errato, certificato scaduto | 503 di manutenzione, mai "via libera" | Da provare |
| H6 | Ticket trovato dalla ricerca ma non leggibile | Elenco e icone rispondono 503 (non mostrano meno ticket) | Unit |
| H7 | Qualunque errore dell'elenco in home paziente | Messaggio di manutenzione (503) o di elenco non disponibile (altri errori), mai "nessun ticket" | Unit (logica) |
| H8 | Stesso questionario più volte nello stesso ciclo (CRF ripetibile) | Decisione del cliente: un ticket blocca tutte le istanze? | Da decidere |
| H9 | Elenco della home = conteggio del blocco | Stesso paziente: i ticket mostrati coincidono con quelli che bloccano | Da provare |
| H10 | Contenuto dell'audit di deroga | Chi, motivo, ticket, CRF; nessun token o testo del ticket nei log | Da provare |
| H11 | Messaggio di manutenzione in it/en/de/fr | Presente e leggibile nelle quattro lingue | Browser locale (solo en) |
| H12 | Manutenzione di 2 ore, regola di deroga spenta e accesa | Procedura scritta applicabile da chi non ha scritto il codice | Da provare |
