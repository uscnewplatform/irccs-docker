# Email dei ticket: report settimanale e ticket ad alta priorità — progetto (2026-11-09)

Stato: **bozza da approvare**. Nessun codice scritto. Richiesta del cliente (cambio di specifica del 2026-11-09). Sostituisce le notifiche email per-evento configurate a mano su Zammad (`pj-tk`).

## Perché

Il cliente non vuole più una mail a ogni evento di un ticket. Vuole due sole cose: un **report periodico** per gruppo con i ticket aperti e, solo per i ticket **ad alta priorità**, le mail di apertura, di chiusura e di sollecito. Oggi su `pj-tk` ci sono trigger che scrivono a ogni evento di ogni ticket (apertura, modifica, assegnatario, chiusura, conferma al cliente) e due job pianificati di sollecito (dopo 2 giorni, poi ogni giorno, per tutti i ticket). Zammad sa scrivere solo agli agenti del gruppo primario di un ticket, mentre un ticket di CRF può avere **più gruppi coinvolti** (attributo `targetgroups`): per questo l'invio passa dal microservizio Zammad.

## Regole decise dal committente

1. **Nessuna mail per gli eventi dei ticket normali** (apertura, modifica, assegnatario, chiusura): non partono più.
2. **Report settimanale.** Una sola email per gruppo, con tutti i ticket aperti associati a quel gruppo. Per ogni ticket una riga della tabella: numero del paziente, studio, ticket (numero e titolo) e un collegamento che apre il ticket associato a quella CRF. Partenza di default: **lunedì alle 8:00** (ora italiana).
3. **Destinatari del report:** i membri del gruppo. «Gruppi a cui è stato associato il ticket» = il gruppo primario e quelli coinvolti.
4. **Ticket ad alta priorità** (priorità «3 high» di Zammad):
   - **Apertura:** una mail ai soli gruppi a cui il ticket è stato aperto.
   - **Chiusura:** una mail ai soli gruppi a cui il ticket è stato aperto (non a chi lo ha aperto).
   - **Riapertura:** se un ticket ad alta priorità chiuso viene riaperto, una mail di riapertura (decisione del committente). Destinatari: gli stessi dell'apertura (gruppi a cui è stato aperto): ipotesi del progettista.
   - **Sollecito:** parte solo se il ticket è **fermo da 3 giorni**, cioè senza nuovi messaggi, e si ripete ogni 3 giorni finché resta fermo; qualsiasi nuovo messaggio azzera il conteggio (come faceva il sollecito di Zammad). Va a **entrambe le parti**: i gruppi a cui è stato aperto e il gruppo di chi lo ha aperto.
   - Il ticket compare anche nel report, con l'etichetta «ALTA».
5. **Colori e aspetto** dell'email: quelli di Zammad (`pj-tk`): blu `#337ab7` per titolo e pulsanti, rosso `#a94442` su `#f2dede` per l'etichetta ALTA, grigio `#f5f5f5` per l'intestazione della tabella, bordi `#dddddd`. Testo bilingue italiano/inglese.
6. **Configurabile** con variabili di configurazione del servizio (si cambia il valore e si riavvia il servizio): giorno e ora del report, intervallo del sollecito, interruttore generale. Nessuna pagina di impostazioni.
7. Le **news di studio** (ticket di ambito STUDIO) non mandano mai email.

## Obiettivi

- Le regole 1-7 applicate dal microservizio, senza doppioni neanche dopo un riavvio.
- Un ticket a più gruppi è visto da ogni gruppo coinvolto nel report e nelle mail di apertura/chiusura.

## Non obiettivi

- Nessuna pagina di impostazioni, nessuna preferenza per utente, nessuna disiscrizione.
- Nessuna mail al paziente né a indirizzi che non siano utenti Zammad attivi: membri dei gruppi previsti o, per i ticket vecchi senza `opengroup`, chi ha aperto il ticket.
- Nessuna risposta via email che aggiorna il ticket.
- Nessuna notifica per ticket a priorità normale o bassa, a parte il report.

## Anti-obiettivi (fallimento anche se «funziona»)

- Mail ripetute per lo stesso evento (riavvio del servizio, due esecuzioni ravvicinate).
- All'attivazione, una raffica di mail di «apertura» per tutti i ticket ad alta priorità già aperti.
- Mail a chi non fa parte dei gruppi previsti, o a un gruppo senza permessi di lettura.
- Un'email di report vuota quando un gruppo non ha ticket aperti.
- Dati personali, indirizzi o testi nei log.

## Vincoli

- Stack: Quarkus/Java 21 (`irccs-microservice-zammad`, che ha già `quarkus-scheduler`), `EmailService` di `i3-mail` (`sendHtmlEmail`), Zammad 7.2 REST. Commenti e log in italiano; log di successo e di servizio con soli conteggi.
- Il microservizio non ha database: ciò che è già stato inviato si ricava da Zammad (vedi «Come funziona»).
- Server SMTP: relay `10.1.253.151:25` senza autenticazione né TLS, mittente `noreply-pj@istitutotumori.na.it` (come per le notifiche già provate su `pj-tk`).
- Utenti di un gruppo = utenti Zammad attivi con email e permesso `read`, `change` o `full` su quel gruppo (`create` e `overview` non contano), come per i ticket a più gruppi.
- Nessun commit finché l'utente non lo chiede; branch `feature/PASTRL-<n>`, PR aperta dalla CI.

## Come funziona (scelte del progettista, da rivedere)

1. **Un solo job del microservizio**, con interruttore `zammad.notifications.enabled` (default **spento**) e fuso orario `Europe/Rome`.
2. **Controllo periodico ogni 5 minuti** (configurabile) dei ticket ad alta priorità: per ciascuno, in base allo stato e a un segno salvato sul ticket, manda la mail di apertura, di chiusura o di sollecito.
   - **Apertura:** ticket ad alta priorità, di CRF, non chiuso, senza il segno di apertura inviata → mail ai gruppi coinvolti, poi segno. Un ticket già aperto prima dell'attivazione non riceve la mail di apertura.
   - **Chiusura:** ticket con il segno di apertura e chiuso, senza il segno di chiusura → mail, poi segno. Un ticket chiuso senza essere mai stato notificato non manda nulla.
   - **Riapertura:** ticket con il segno di chiusura e di nuovo non chiuso → mail di riapertura, poi si toglie il segno di chiusura (una nuova chiusura manderà una nuova mail di chiusura).
   - **Sollecito:** ticket ad alta priorità non chiuso, fermo da 3 giorni → mail, poi si aggiorna la data. «Fermo» = l'ultimo messaggio del ticket (`last_contact_at` di Zammad, che non cambia con i tag del servizio) e l'ultima mail inviata (apertura, riapertura o sollecito) sono entrambi più vecchi di 3 giorni. Un nuovo messaggio azzera il conteggio.
3. **Il segno si salva in Zammad**, non nel servizio, così sopravvive ai riavvii: tag sul ticket o attributo personalizzato (a scelta del realizzatore; i tag non richiedono migrazioni e non riavviano Zammad).
4. **Report:** ogni lunedì alle 8:00 (cron configurabile), per ciascun gruppo cerca i ticket di CRF non chiusi con quel gruppo fra quelli coinvolti, ordina per priorità poi per anzianità, e manda **una email per gruppo a ogni suo membro**. Un utente di due gruppi riceve due email. Un gruppo senza ticket aperti non riceve nulla. Le righe contengono: numero paziente (`patientdisplay`), studio (`patientjourneydisplay`), ticket (numero e titolo, etichetta ALTA se priorità alta), giorni di apertura e il collegamento.
5. **Collegamento del ticket.** Il collegamento salvato nel ticket alla creazione (`directlink`, la pagina della CRF dove si apre il pannello del ticket); se manca, la pagina del ticket in Zammad costruita da un modello configurabile (`zammad.notifications.ticket-url-template`).
6. **Destinatari delle mail ad alta priorità.** Apertura e chiusura: gli utenti dei gruppi coinvolti (gruppo primario più `targetgroups`). Sollecito: gli utenti dei gruppi coinvolti più quelli del gruppo di chi ha aperto (`opengroup`; per i ticket vecchi senza `opengroup`, solo il cliente del ticket).
7. **Spegnimento di Zammad nativo**, solo dopo l'attivazione, con un'opzione esplicita dello script di installazione: trigger «conferma apertura al cliente», «cambio assegnatario», «apertura», «modifica», «chiusura» e i due job di sollecito. Il trigger «presa in carico alla risposta» (cambia solo stato) resta.
8. **Variabili di configurazione** (nomi indicativi, da allineare al resto del repo): `ZAMMAD_NOTIFICATIONS_ENABLED`, `ZAMMAD_NOTIFICATIONS_REPORT_CRON` (default lunedì 8:00), `ZAMMAD_NOTIFICATIONS_REMINDER_INTERVAL` (3d), `ZAMMAD_NOTIFICATIONS_POLL_INTERVAL` (5m), `ZAMMAD_NOTIFICATIONS_TICKET_URL`, `ZAMMAD_NOTIFICATIONS_START_FROM` (data di attivazione), `ZAMMAD_NOTIFICATIONS_EXCLUDE_EMAILS`, più `quarkus.mailer.*`.

## Scelte lasciate al realizzatore

- Struttura delle classi e dei test; formato esatto dei segni sul ticket (tag o attributo).
- Impaginazione HTML dell'email nel rispetto dei colori; pausa fra un invio e l'altro per non saturare il relay.
- Script di installazione (opzione per spegnere trigger e job di Zammad) e documentazione.

## Chiarimenti e scelte del progettista (dopo la lettura del revisore)

Sono decisioni del progettista da rivedere, tranne dove indicato.

1. **Identità del job.** Il job gira con il **token di servizio** di Zammad già usato dal microservizio (lettura di ticket, gruppi e utenti con i loro permessi; scrittura dei tag sui ticket). Non passa da `TicketAccessPolicy` (che ragiona per utente): i destinatari li calcola con la regola «utenti attivi con email e `read`/`change`/`full` sul gruppo».
2. **Ticket ad alta priorità già aperti all'attivazione.** Al primo giro dopo l'attivazione ricevono un segno retroattivo, **senza mail**, con la data di attivazione: il primo sollecito arriva **3 giorni dopo l'attivazione**, mai subito. `ZAMMAD_NOTIFICATIONS_START_FROM` è la data di attivazione: i ticket creati prima non ricevono la mail di apertura.
3. **Segni sul ticket.** Tag: `mail-apertura`, `mail-chiusura` e `mail-sollecito-<aaaammggThhmm>` con la data dell'ultimo invio (un solo tag di sollecito alla volta: il vecchio si toglie quando si scrive il nuovo). Non servono attributi né migrazioni. Ordine: **prima la mail, poi il tag**: se la scrittura del tag fallisce, la mail si può ripetere; per i ticket ad alta priorità si preferisce un doppione a una mail persa.
4. **Riapertura.** Se un ticket con `mail-chiusura` torna aperto, parte una mail di **riapertura** (non di apertura) e si toglie il tag `mail-chiusura`: una nuova chiusura manderà di nuovo la mail di chiusura. I destinatari della mail di riapertura sono quelli dell'apertura (scelta del progettista, da confermare). Il conteggio del sollecito riparte dalla riapertura.
5. **Report non inviato.** Se il servizio è fermo alle 8:00 di lunedì, **la settimana si salta** (nessun recupero dopo il riavvio). I gruppi da trattare si ricavano dai ticket di CRF non chiusi (gruppo primario più `targetgroups`), non da tutti i gruppi di Zammad.
6. **`EXCLUDE_EMAILS`.** Elenco di indirizzi (per esempio account di prova o di servizio) a cui non si scrive mai, valido per tutte le mail, report compreso.
7. **Ticket vecchi senza `opengroup`.** Per il sollecito l'altra parte è il cliente del ticket, se è un utente Zammad attivo con email.

## Punti da confermare col committente

1. **La priorità conta quella del ticket in quel momento.** Se alzata a «alta» dopo l'apertura, la mail di apertura parte alla prima rilevazione; se abbassata, i solleciti si fermano.
2. **Chi riceve la mail di riapertura:** gli stessi dell'apertura (i gruppi a cui è stato aperto).
3. **Un utente di più gruppi riceve un report per ciascun gruppo.**
4. **Un solo servizio in esecuzione**: con più copie del servizio le mail pianificate potrebbero ripetersi.
5. **Report saltato** se il servizio è fermo alle 8:00 di lunedì.

## Aggiornamento 2026-11-09 (sera): invio via Zammad, as-is con produzione

- Le mail le spedisce **Zammad** (messaggio di tipo email via API `ticket_articles`, canale SMTP e mittente di Zammad), non un mailer del microservizio. Il report parte da un ticket tecnico chiuso «Report settimanale ticket aperti» per gruppo.
- **Destinatari come oggi in produzione**: solo gli utenti con permesso `full` sul gruppo («agenti del gruppo»), **una mail separata per ciascuno** (nessuno vede gli altri). Sostituisce «read, change o full» e «una mail con tutti in A» scritti sopra.
- **Ticket broadcast (news di studio, `crfscope` STUDY) invariati**: nessuna mail e nessuna riga nel report, come i trigger attuali (`crfscope is not STUDY`).
- Verificato su Zammad di staging: tags `{"tags":[..]}`, `tags/add` 201, messaggio email 201 anche su ticket chiuso (resta chiuso), gruppo senza indirizzo email = 422.
