# Ticket CRF — casi di test funzionali e di accettazione

Data: 2026-10-22. Versione "tutto a Zammad" (branch `feature/PASTRL-720/ticket-crf-zammad-live`). Riferimenti: design `2026-10-22-ticket-crf-zammad-live-design.md`, guida `2026-10-22-guida-installazione-produzione-ticket-crf.md`.

Colonna **Copertura**: *Unit* = test automatico nel repo; *E2E locale* = provato su pascale-local con Zammad di prova (script non versionati: contengono credenziali locali); *Da provare* = non ancora provato (staging/prod).

## A. Blocco della conferma CRF (flag acceso)

| ID | Scenario | Passi | Atteso | Copertura |
|---|---|---|---|---|
| A1 | CRF senza ticket | Conferma una CRF senza ticket | 200, CRF confermata | Unit + E2E locale |
| A2 | CRF con ticket aperto | Apri un ticket sulla CRF, conferma | 409 `CRF_OPEN_TICKETS`, CRF non confermata | Unit + E2E locale |
| A3 | Ticket chiuso dalla piattaforma | Chiudi il ticket dal pannello (o convalida la chiusura), conferma | 200 subito, senza attese. Chiuso direttamente in Zammad: 409 (vedi I1) | E2E locale |
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
| C8 | Compilazioni del paziente (link con token, `patient-interview`) | Fuori ambito: nessuna gestione dei ticket (decisione del cliente) | Non applicabile |
| C9 | Certificazione (`/certify`) con Zammad giù | 503, nessun OTP emesso, nessuna deroga | Unit |

## D. Certificazione e altri percorsi

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| D1 | Certificazione con ticket aperti su una qualunque CRF del paziente | 409, nessun OTP | Unit |
| D2 | Certificazione senza ticket aperti | Procede alla sfida OTP | Unit |
| D3 | CRF completata dal paziente con ticket aperti | Fuori ambito: nessun blocco (decisione del cliente) | Non applicabile |
| D4 | SAE | Esclusi dal *riporto da confermare* della CRF. Hanno invece il proprio blocco su abilitazione e firma (vedi L11–L15) | Staging 26/10 (L11–L15) |
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
| F1 | Riquadro «Ticket aperti» in testa ai pulsanti, chiuso di default, apribile | Elenco con numero, stato, titolo, CRF | E2E locale (browser) |
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

## I. Decisioni del cliente del 22/10 (chiusura convalidata, dopo la conferma, per compilazione)

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| I1 | Ticket chiuso direttamente in Zammad (senza segno) | La conferma resta bloccata (409); il pannello mostra «Chiuso senza convalida» | Unit + E2E locale |
| I2 | Ticket chiuso dal pannello (capability + motivazione) | Lascia il segno `crfclosure`; la conferma passa | Unit + E2E locale |
| I3 | Convalida di una chiusura diretta («Convalida chiusura», motivazione ≥ 5 caratteri) | Scrive la motivazione e il segno; poi non blocca | Unit + E2E locale |
| I4 | Convalida senza capability / senza motivazione / su ticket non chiuso | 403 / 422 / 409 | Unit + E2E locale |
| I5 | Segno vecchio + nuova chiusura diretta | Blocca (il segno non copre la nuova chiusura) | Unit |
| I6 | Riapertura dal pannello | Toglie il segno; il ticket blocca | Unit + E2E locale |
| I7 | Ticket chiuso da un'automazione di Zammad | Blocca finché non convalidato dal pannello | Da provare (Zammad di staging) |
| I8 | Campi `patient`/`careplan`/`crf`/`crfscope`/`qrid`/`crfclosure` nella maschera di modifica di Zammad | Non visibili/modificabili dall'interfaccia | E2E locale (script attributi) |
| I9 | Ticket aperto dalla piattaforma su una CRF già confermata | La CRF torna in corso (da confermare), estensioni di conferma tolte, evento di audit | Unit + E2E locale |
| I10 | Ticket riaperto dal pannello su una CRF confermata | Come I9 | Unit + E2E locale |
| I11 | Ticket aperto o riaperto direttamente in Zammad dopo la conferma | Nessuna azione sulla CRF (limite documentato); il ticket blocca una nuova conferma | Documentato |
| I12 | Due compilazioni dello stesso questionario nello stesso ciclo, ticket su una sola | Blocca solo quella; l'altra si conferma | Unit + E2E locale |
| I13 | Ticket senza `qrid` (aperto prima del salvataggio) | Blocca tutte le compilazioni di quella CRF | Unit + E2E locale |
| I14 | Riabilitare la CRF dopo la chiusura del ticket | Riconferma normale | E2E locale |

## J. Controlli di sicurezza aggiunti dopo la revisione tecnica

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| J1 | Ticket creato con `crfscope` diverso da CRF/STUDY | 422, nessuna chiamata a Zammad (non si salta la visibilita') | Unit |
| J2 | Ticket con ciclo o compilazione di un altro paziente | 422; con HAPI non raggiungibile 503 | Unit |
| J3 | Ticket in un gruppo in cui l'utente non puo' aprire ticket | 403 | Unit |
| J4 | Id non numerici o con prefissi (Patient/1, 1\|2) | 422 / normalizzati | Unit |
| J5 | `PUT /tickets/{id}` con `state_id` | 422 (chiudi/riapri passano dal pannello) | Unit |
| J6 | Riporto da confermare su una SAE | Non si tocca | Unit |
| J7 | Riporto da confermare con audit non registrabile | La CRF non si tocca, errore nei log | Unit |
| J8 | Riporto: compilazione gia' tornata in corso mentre si cerca | Non si riscrive | Unit |
| J9 | Token di servizio senza accesso a un gruppo Zammad | 503 (mai «nessun ticket»); permesso via ruolo valido; gruppo ignorabile | Unit + E2E locale |
| J10 | Zammad con limite di pagina inferiore a 200 | Nessun troncamento silenzioso | Unit |
| J11 | Conferma con ciclo alterato nel corpo inviato | Il blocco usa la compilazione salvata (decisione piu' restrittiva) | Unit |
| J12 | `create` completato con l'id di una compilazione gia' confermata | E' una conferma: ruolo e blocco si applicano | Unit |

## K. Interfaccia: pagina I miei ticket, icona in tabella, riquadro in testa

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| K1 | Clic su «I miei ticket» nel menu del profilo | Apre `/my-tickets` | E2E locale (browser) |
| K2 | Numero nel menu = righe della scheda «Aperti» | Coincidono | E2E locale |
| K3 | Scheda «Tutti», ricerca testuale, «Apri la CRF» | Piu' righe; filtro; porta alla CRF con careplanId e crfId | E2E locale |
| K4 | Ticket di un gruppo che l'utente non legge in Zammad, su paziente visibile | In home si', in «I miei ticket» no (differenza voluta, da confermare col cliente) | Documentato |
| K5 | Icona accanto allo stato nella tabella pazienti | Presente sul paziente con ticket; una sola chiamata per le righe visibili | E2E locale (browser) |
| K6 | Riquadro «Ticket aperti» nella home paziente | Primo elemento sopra i pulsanti | E2E locale (browser) |

## H. Casi aggiunti dopo la revisione funzionale

| ID | Scenario | Atteso | Copertura |
|---|---|---|---|
| H1 | Modifica/chiusura diretta in Zammad dei campi `patient`/`careplan`/`crf` o dello stato | Deciso: la chiusura diretta non sblocca, i campi non sono modificabili: vedi I1–I8 | Vedi sezione I |
| H2 | Ticket riaperto o aperto DOPO la conferma | Deciso: la CRF torna da confermare per le azioni dalla piattaforma: vedi I9–I11 | Vedi sezione I |
| H3 | Due utenti concorrenti: uno apre un ticket mentre l'altro conferma | La conferma vede lo stato di Zammad al momento della richiesta; documentare la finestra | Da provare |
| H4 | Zammad lento ma funzionante (2–4 s per chiamata) | Nessun falso 503 entro 3 s verso Zammad e 5 s verso il ms; oltre, 503 | Da provare (strumento per rallentare Zammad) |
| H5 | Rete rotta, DNS errato, certificato scaduto | 503 di manutenzione, mai "via libera" | Da provare |
| H6 | Ticket trovato dalla ricerca ma non leggibile | Elenco e icone rispondono 503 (non mostrano meno ticket) | Unit |
| H7 | Qualunque errore dell'elenco in home paziente | Messaggio di manutenzione (503) o di elenco non disponibile (altri errori), mai "nessun ticket" | Unit (logica) |
| H8 | Stesso questionario più volte nello stesso ciclo (CRF ripetibile) | Deciso: ogni compilazione ha i suoi ticket: vedi I12–I13 | Vedi sezione I |
| H9 | Elenco della home = conteggio del blocco | Stesso paziente: i ticket mostrati coincidono con quelli che bloccano | Da provare |
| H10 | Contenuto dell'audit di deroga | Chi, motivo, ticket, CRF; nessun token o testo del ticket nei log | Da provare |
| H11 | Messaggio di manutenzione in it/en/de/fr | Presente e leggibile nelle quattro lingue | Browser locale (solo en) |
| H12 | Manutenzione di 2 ore, regola di deroga spenta e accesa | Procedura scritta applicabile da chi non ha scritto il codice | Da provare |

## L. Prove su staging del 26/10/2026 (utenti Keycloak temporanei, paziente sintetico 42995, ciclo modello 42552, dati cancellati alla fine)

Script versionati in `setup/test/` (`E2E_PATIENT` ed `E2E_CAREPLAN` obbligatori; `--no-restart` per non riavviare il ms Zammad).

| ID | Scenario | Atteso | Esito |
|---|---|---|---|
| L1 | `e2e_ticket_workflow.py`: admin apre, sperimentatore risponde, l'admin chiude e conferma | Blocco 409, sperimentatore non chiude (403), conferma dopo la chiusura | 25/25 |
| L2 | `e2e_ticket_visibility.py`: quattro utenti dello stesso centro (V1–V4) | Vede solo il gruppo destinatario, chi ha aperto, l'admin del centro | 42/42 |
| L3 | `e2e_ticket_roles.py`: Farmacovigilanza risponde e chiude, l'admin del centro risponde e chiude (R1–R2) | Chiusura con segno firmato, conferma subito dopo | 33/33 |
| L4 (X1) | Autore: ticket, primo messaggio e risposta | Creatore e mittente sono l'utente (`created_by_id`), non il token di servizio | OK (29/29 e 29/29) |
| L5 (X2) | News di studio con i segnaposto `00000` della dashboard | 201, un solo ticket nel gruppo `annunci_tutti`, creato dall'admin; senza `full` sul gruppo 403 | OK |
| L6 (X2) | Lettura e gestione della news | Lo sperimentatore la vede ed è in sola lettura (`canReply` e `canClose` falsi, 403 se risponde o chiude); chi ha `full` risponde, cambia scadenza e priorità, chiude; una news chiusa non si riapre (403) e sparisce dall'elenco | OK |
| L7 (X3, A10) | Blocco spento con un ticket aperto | Riepilogo libero, conferma 200 | OK (flag riportato a `true`) |
| L8 (X3) | Blocco acceso con un ticket aperto | Riepilogo BLOCKED, conferma 409 `CRF_OPEN_TICKETS` | OK |
| L9 (X4, C1) | Zammad non raggiungibile (`--down`: si ferma il container Rails) | 503 `CRF_TICKET_STATE_UNVERIFIABLE`, CRF non confermata; poi Zammad torna disponibile | OK (31/31) |
| L10 (B1–B3, D0) | Deroga sulla conferma di una CRF con ruolo e motivo valido/corto | 200 con motivo valido, 422 `CRF_OVERRIDE_REASON_INVALID` con motivo corto, 409 senza deroga | OK il 26/10 (`e2e_ticket_sae.py`, ruolo assegnato ai gruppi solo per la prova e tolto) |
| L11 (S1) | SAE con medico indicato, salvata dall'admin | Nasce il diritto di firma già abilitato (`accepted`), il medico può firmare | OK |
| L12 (S2) | Query aperta sulla SAE, il medico prova a firmare | 409 `CRF_OPEN_TICKETS`, nessuna email OTP; deroga senza ruolo 403, con motivo corto 422, valida: parte la sfida OTP (202); codice errato 417 | OK |
| L13 (S3) | Query chiusa, il medico firma con l'OTP (letto da Mailpit) | Riepilogo libero, firma 200, stato `signed` | OK |
| L14 (S4) | Query aperta dopo la firma | La SAE resta firmata (`signed`, firma corrente): il ticket blocca solo una nuova firma | OK |
| L15 (S5) | SAE corretta dopo la firma, con la query aperta | Modifica permessa (200); firma non più corrente, nuovo diritto `requested`; abilitazione 409 `CRF_OPEN_TICKETS`, con deroga corta 422, senza il ruolo di abilitazione 403, con deroga valida 200 (`accepted`); nuova firma ancora bloccata (409); chiusa la query la firma riparte e si completa | OK |

Nota: `e2e_ticket_sae.py` (35/35) assegna ai gruppi Admins e Sperimentatori i ruoli di deroga e di abilitazione SAE solo per la durata della prova, li toglie sempre alla fine (anche in caso di errore) e cancella i dati creati (anche Provenance, Task e l'appartenenza del medico di prova al gruppo dei medici). Le email vanno su Mailpit.

Note: l'esito «la news è un solo ticket» si basa sulla ricerca per titolo di Zammad, che dipende dall'indice di ricerca: in staging l'indice non era aggiornato subito (0 risultati), quindi la prova è indicativa; il conteggio per gruppo conferma comunque un solo ticket nel gruppo 74.

