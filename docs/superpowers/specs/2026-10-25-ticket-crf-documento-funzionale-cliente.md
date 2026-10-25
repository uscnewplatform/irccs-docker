---
title: "Gestione dei ticket sulle CRF — Documento funzionale"
subtitle: "Piattaforma IRCCS Pascale"
date: "25 ottobre 2026"
lang: it-IT
---

# 1. Scopo

Sperimentatori, data manager e farmacovigilanza possono segnalare un problema o una richiesta su una CRF (un dato incongruente, un chiarimento, una correzione) aprendo un **ticket**. I ticket sono gestiti dal sistema di ticketing (Zammad), ma chi lavora sulla CRF li legge, risponde e li chiude **senza uscire dalla piattaforma**.

Regola di fondo: una CRF con ticket ancora aperti **non può essere confermata**.

Questo documento descrive come funzionano i ticket tra i diversi gruppi di utenti e nei diversi tipi di ticket, cosa vede e cosa può fare ciascuno, e quali prove sono state eseguite.

# 2. Le tipologie di ticket

| | **Ticket di CRF** | **News di studio** |
|---|---|---|
| A cosa serve | Segnalare o chiedere qualcosa su una specifica CRF di un paziente | Comunicare un avviso a tutto lo studio |
| Legato a | Paziente, ciclo di cura e CRF | Solo allo studio (nessun paziente) |
| Dove si apre | Pulsante *Ticket* nella pagina della CRF | Come ticket dello studio, nel gruppo degli annunci del centro |
| Dove si legge | Pannello laterale della CRF, home del paziente, «I miei ticket» | Card dello studio nella home: «News studio», in un popup |
| Blocca la conferma della CRF | **Sì**, finché non è chiuso | **No**, mai |
| Si può rispondere | Sì | No (sola lettura) |
| Allegati | No | Sì: massimo 3 file da 10 MB (pdf, png, jpg, docx, xlsx, csv, txt) |
| Priorità | Alta / Normale / Bassa, scelta da chi apre | Alta / Normale / Bassa, scelta da chi apre |

**CRF compilate dal paziente** (compresi i diari): non hanno ticket né il pulsante «Conferma CRF».

## Stati di un ticket

- **Nuovo, aperto, in attesa**: il ticket è vivo e **blocca** la conferma della CRF. Un ticket «in attesa» continua a bloccare.
- **Chiuso**: non blocca, **ma solo se la chiusura è stata fatta dalla piattaforma** (vedi paragrafo 5).
- **Unito** ad un altro ticket: non blocca.

# 3. Gruppi e ruoli

I diritti dipendono dal **gruppo di utenti** di appartenenza (gestiti in *Gruppi utenti*), non dal singolo utente.

| Gruppo / ruolo | Cosa può fare sui ticket |
|---|---|
| **Qualsiasi utente che vede il paziente** | Aprire un ticket sulle CRF del paziente; vedere e rispondere ai ticket che ha aperto o che sono assegnati al proprio gruppo |
| **Sperimentatori** | Come sopra; non chiudono i ticket |
| **Farmacovigilanza** | Vede e risponde ai ticket assegnati a Farmacovigilanza; li **chiude** |
| **Admin del centro** | Vede e gestisce **tutti** i ticket di **tutti** i gruppi del centro; risponde e **chiude**; conferma le CRF |
| Chi ha il diritto di **conferma CRF** | Conferma una CRF quando non ci sono ticket aperti |
| Chi ha il diritto di **deroga** (pochi responsabili) | Conferma una CRF nonostante ticket aperti, con motivazione obbligatoria e audit |

Il diritto di **chiudere** i ticket è una scelta di configurazione assegnata ai gruppi autorizzati (su staging: Admins del centro e Farmacovigilanza). Chi apre un ticket, o ci risponde, **non può chiuderlo da solo** se il suo gruppo non ha quel diritto.

# 4. Chi vede un ticket di CRF

Un ticket di CRF è visibile a un utente solo se valgono **entrambe** le condizioni:

1. l'utente **vede il paziente** nella piattaforma (nel suo centro/contesto);
2. l'utente **ha a che fare col ticket**: l'ha aperto lui, oppure appartiene al **gruppo a cui il ticket è assegnato**, oppure è **admin del centro**.

Conseguenze:

- Un ticket assegnato a Farmacovigilanza è visto da Farmacovigilanza, da chi lo ha aperto e dagli admin del centro. **Non** è visto dagli altri sperimentatori, anche se vedono lo stesso paziente.
- Chi non lo vede non può nemmeno rispondere, chiudere o riaprire.
- Il **blocco della conferma vale per tutti**: se una CRF ha un ticket aperto, nessuno la conferma, anche chi non vede il ticket. A chi non lo vede il sistema comunica solo che ci sono ticket aperti (numero e stato), senza titolo né testo.

## Assegnazione a uno o più gruppi

- Ogni ticket di CRF è assegnato a **un solo gruppo**, da scegliere tra i gruppi **del centro del paziente** nei quali l'utente può aprire ticket.
- Per coinvolgere **due gruppi** sulla stessa CRF si aprono **due ticket**, uno per gruppo. Ognuno vede solo il proprio; l'admin del centro li vede entrambi; la CRF resta bloccata finché non sono chiusi tutti e due.

# 5. Ciclo di vita di un ticket di CRF

1. **Apertura.** Un utente apre il ticket dal pulsante *Ticket* della CRF: sceglie il gruppo destinatario, la priorità, scrive titolo e messaggio. Se la CRF era già confermata, **torna «da confermare»** (e viene registrato in audit).
2. **Lavorazione.** Il gruppo destinatario legge il ticket e risponde dal pannello; chi ha aperto il ticket vede le risposte. Lo sperimentatore può correggere la CRF e scrivere «attività svolta».
3. **Chiusura.** Chi ha il diritto di chiusura (Farmacovigilanza, admin del centro) chiude il ticket scrivendo una **motivazione** (almeno 5 caratteri) che resta nella conversazione. La piattaforma registra sul ticket un **segno di chiusura firmato**.
4. **Riapertura.** Chi ha il diritto di chiusura può riaprire il ticket; la CRF già confermata torna da confermare.
5. **Conferma della CRF.** Con tutti i ticket chiusi, chi ha il diritto di conferma conferma la CRF.

**Chiusura fatta direttamente nel sistema di ticketing.** Se qualcuno chiude un ticket **fuori dalla piattaforma** (o con un'automazione), il ticket **continua a bloccare** la CRF e nel pannello compare «Chiuso senza convalida». Chi ha il diritto di chiusura può **convalidare** quella chiusura dal pannello con una motivazione. Il segno di chiusura è firmato dalla piattaforma: non si può simulare scrivendolo a mano.

# 6. Chiudere un ticket e confermare una CRF

Sono **due azioni distinte**, con regole proprie, che possono essere fatte da persone diverse: prima si chiude il ticket, poi si conferma la CRF.

```
ticket aperto  →  risposta del gruppo  →  chiusura del ticket
                                               ↓
                         ticket chiuso con il segno firmato della piattaforma
                                               ↓
                              conferma della CRF
```

## 6.1 Chiudere un ticket

Servono **tre condizioni insieme**:

1. **Il diritto di chiusura** nel proprio gruppo (assegnato ai gruppi autorizzati; su staging: Admins del centro e Farmacovigilanza).
2. **Poter intervenire sul ticket**: averlo aperto, oppure appartenere al gruppo a cui è assegnato con diritto di modifica, oppure essere admin del centro. Chi può solo leggere il ticket non può chiuderlo.
3. **Una motivazione** di almeno 5 caratteri, che resta nella conversazione.

Chi non ha il diritto di chiusura (per esempio uno sperimentatore, anche se ha aperto lui il ticket) riceve un rifiuto. La chiusura vale per la CRF **solo se passa dalla piattaforma**: viene scritto sul ticket un segno di chiusura firmato. Una chiusura fatta direttamente nel sistema di ticketing non basta (vedi paragrafo 5).

## 6.2 Confermare una CRF

Servono **due condizioni**, controllate in quest'ordine:

1. **Il diritto di conferma** nel proprio gruppo. Se manca, la conferma è rifiutata (su staging il diritto ce l'hanno gli Admins del centro; Sperimentatori e Farmacovigilanza no).
2. **Nessun ticket di CRF bloccante.** Se ce n'è almeno uno, la conferma è rifiutata e il sistema indica quanti sono.

Quali ticket **bloccano**:

| Stato del ticket | Blocca la conferma? |
|---|---|
| Nuovo, aperto, in attesa | **Sì** |
| Chiuso dalla piattaforma (con il segno firmato) | No |
| Chiuso direttamente nel sistema di ticketing, senza convalida | **Sì**, finché non viene convalidato |
| Unito a un altro ticket | No |
| News di studio | No, mai |

Il blocco **vale per tutti**, anche per chi non vede il ticket: lo decide il server. Se il sistema di ticketing non risponde, la conferma non è possibile (si preferisce fermarsi piuttosto che confermare alla cieca).

## 6.3 Riepilogo per gruppo (staging)

| Gruppo | Può chiudere un ticket | Può confermare una CRF | Un ticket aperto blocca la conferma |
|---|---|---|---|
| Sperimentatori | No | No | Sì |
| Farmacovigilanza | Sì | No | Sì |
| Admin del centro | Sì | Sì | Sì |

Chi ha il diritto di **deroga** può confermare anche con ticket aperti (paragrafo 7).

# 7. Il blocco della conferma e la deroga

- Il pulsante **Conferma CRF** lo **vedono solo i gruppi che hanno il diritto di conferma**: per gli altri gruppi non compare affatto (nemmeno grigio), e non vedono neppure l'avviso di conferma bloccata. Per chi lo vede, è **disabilitato** ogni volta che la conferma non è possibile: ci sono ticket non chiusi, oppure il sistema di ticketing non risponde, oppure la CRF si sta ancora salvando o importando. Sopra i pulsanti un avviso giallo spiega quanti ticket bloccano e quali. Chi ha il diritto di deroga vede accanto un secondo pulsante, **«Conferma con deroga…»**.
- Le regole di chi può chiudere e confermare sono nel paragrafo 6. Con il blocco attivo, il pulsante **Conferma CRF** non funziona se la CRF ha ticket non chiusi: il sistema spiega quanti sono.
- Se il sistema di ticketing **non risponde**, la conferma è impossibile (per prudenza), salvo diversa scelta di configurazione.
- La **deroga** consente a pochi responsabili di confermare comunque, con una **motivazione obbligatoria (10–500 caratteri)**. Ogni deroga è registrata in audit con motivazione, utente e ticket coinvolti; se l'audit non si registra, la deroga viene rifiutata. La motivazione non deve contenere dati identificativi del paziente.
- Il blocco vale anche per il completamento di una CRF da **link di compilazione** e per l'**import** di CRF già completate (queste ultime richiedono il diritto di conferma).

# 8. Esempi (provati su staging)

**Esempio A — lo sperimentatore apre a Farmacovigilanza, che chiude.**
Lo sperimentatore apre un ticket sulla CRF assegnandolo a Farmacovigilanza. La CRF è subito bloccata. Farmacovigilanza lo vede, risponde e lo chiude con una motivazione. Lo sperimentatore legge l'intera conversazione, non può chiudere il ticket lui stesso. A ticket chiuso la CRF si conferma.

**Esempio B — risponde e chiude anche l'admin del centro.**
Stesso inizio. Dopo la risposta di Farmacovigilanza, l'admin del centro (che vede tutti i ticket del centro) legge la conversazione, aggiunge una risposta e chiude il ticket. La conversazione completa è visibile a tutti i soggetti coinvolti; l'admin conferma la CRF.

**Esempio C — due gruppi sulla stessa CRF.**
L'admin apre due ticket sulla stessa CRF, uno a Sperimentatori e uno a Farmacovigilanza. Ogni gruppo vede solo il proprio ticket; l'admin li vede entrambi; la conferma resta bloccata finché tutti e due non sono chiusi.

**Esempio D — un utente di un altro gruppo.**
Un utente di Farmacovigilanza non vede un ticket assegnato a Sperimentatori (anche se vede lo stesso paziente) e non può rispondere. Vede però che la conferma della CRF è bloccata da un ticket aperto.

# 9. Le schermate

L'interfaccia si adatta al dispositivo: computer, tablet e telefono.

- **Pannello ticket nella CRF.** Si apre dal pulsante *Ticket* e mostra a sinistra i filtri (**Aperti**, **Tutti**, **Da convalidare**) con i conteggi, e sotto la conversazione del ticket scelto. Un pallino segnala i ticket con messaggi nuovi. Per ogni ticket si vede a che punto è: **Aperto → Preso in carico → Chiuso**. In basso si scrive la risposta e, per chi ha il diritto, si chiude il ticket con una motivazione. Sul telefono elenco e conversazione sono due pagine, con la freccia per tornare indietro.
- **Avviso «Conferma bloccata».** Sopra i pulsanti della CRF un riquadro giallo dice quanti ticket aperti impediscono la conferma e quali sono.
- **Nuovo ticket.** Una sola finestra in tre passi: a quale gruppo inviarlo, la priorità, e cosa succede (con scorciatoie come «Dato incongruente» o «Chiarimento»). Ricorda in testa paziente, ciclo e CRF, e avvisa che la CRF resta non confermabile finché il ticket non è chiuso.
- **I miei ticket.** Elenco di tutti i ticket dell'utente con filtri (**Aperti**, **Assegnati a me**, **Aperti da me**, **Da convalidare**, **Chiusi**) e ricerca. Su schermi larghi a destra c'è l'anteprima con gli ultimi messaggi e il pulsante **Apri la CRF**.
- **Home del paziente.** In alto la fascia **Ticket da seguire**, con una carta per ogni ticket aperto e il pulsante per andare alla CRF.
- **News di studio.** Una finestra con la comunicazione più recente aperta, con scadenza, priorità ed eventuali allegati.

# 10. Tracciabilità e sicurezza

- Ogni apertura, risposta, chiusura, riapertura, convalida e deroga è **registrata in audit** come evento a sé, con chi l'ha fatta, quando, da quale indirizzo, su quale ticket, su quale paziente e CRF, con quale esito; per chiusure, riaperture, convalide e deroghe anche la motivazione. Anche gli accessi negati e le conferme bloccate dai ticket (compreso il completamento da link) sono registrati. Se Zammad rifiuta la scrittura a nome dell'utente e la piattaforma la esegue con l'identità di servizio, ne resta traccia separata. Le consultazioni dei ticket di un paziente si ritrovano dall'audit.
- Il testo dei ticket resta nel sistema di ticketing: la piattaforma non ne tiene copia e, per il blocco, scambia solo numero e stato dei ticket.
- Le conversazioni sono mostrate come solo testo (niente HTML, script o indirizzi e-mail).
- I diritti di visibilità sono verificati dal server a ogni richiesta; se un controllo non è possibile, l'accesso è negato.
- Gli allegati (solo news di studio) sono verificati per tipo, contenuto e dimensione. **Non è attivo un antivirus sugli allegati.**

# 11. Esiti delle prove su staging (24–25 ottobre 2026)

| Prova | Esito |
|---|---|
| Admin apre → sperimentatore risponde e corregge la CRF → admin chiude → conferma della CRF | 25/25 controlli superati |
| Visibilità per gruppo (admin, due sperimentatori, farmacovigilanza; tre scenari più chiusura da parte di admin del centro) | 42/42 controlli superati |
| Sperimentatore → Farmacovigilanza che chiude; stesso caso con risposta e chiusura anche dell'admin | 33/33 controlli superati |

# 12. Scelte concordate e punti da ricordare

- Gli **admin del centro vedono e chiudono tutti i ticket del centro** (decisione del cliente). Il diritto si assegna ai gruppi Admins di ogni centro.
- **Farmacovigilanza** può chiudere i ticket.
- Un **ticket «in attesa»** continua a bloccare la conferma; le notifiche e-mail le gestisce il sistema di ticketing.
- Il blocco è **globale** (non per singolo studio).
- Un ticket aperto o riaperto **direttamente nel sistema di ticketing** non riporta da confermare una CRF già confermata, perché la piattaforma non se ne accorge; se fatto dalla piattaforma sì.
- Un ticket creato **direttamente nel sistema di ticketing** senza i riferimenti a paziente, ciclo e CRF non è visto dal blocco.
- I ticket chiusi **prima** del 24 ottobre 2026 risultano «chiusi senza convalida» e vanno convalidati dal pannello.
- Restano da definire con il cliente: chi è «l'assistenza» nel messaggio di manutenzione, le modalità di revisione periodica delle deroghe, la conservazione dei ticket chiusi e l'eventuale antivirus sugli allegati.
