# Ticket a più gruppi, promotore e centro — progetto (2026-11-04)

Stato: **bozza da approvare**. Nessun codice scritto. Richiesta del cliente. Base: `docs/modules/ROOT/pages/ticket-crf.adoc` (stato attuale) e microservizio `irccs-microservice-zammad`.

## Perché

Oggi un ticket di CRF si assegna a **un solo gruppo** Zammad, scelto fra i gruppi del centro del paziente in cui chi apre ha il permesso di creare. Il cliente chiede che il promotore (sponsor) dello studio possa aprire un ticket su un paziente di un altro centro e indirizzarlo a uno o più gruppi di quel centro; e che un centro non promotore possa indirizzarlo a uno o più gruppi del proprio centro e/o a gruppi del promotore. Con più gruppi coinvolti la conversazione è una sola.

## Regole decise dal committente

Definizioni: **promotore** = l'organizzazione indicata come `sponsor` dello studio a cui appartiene il paziente (proprietà dello studio: la stessa organizzazione può essere promotore in uno studio e solo centro in un altro). **Centro del paziente** = il centro (organizzazione) a cui il paziente appartiene. **Gruppi coinvolti** = i gruppi scelti all'apertura.

1. **Apre un gruppo del promotore.** Il paziente è di un altro centro X. Il ticket va a uno, più o tutti i gruppi del centro X (sceglie chi apre; «tutti» è una scorciatoia).
2. **Apre un gruppo di un centro che non è il promotore.** Il paziente è del suo centro. Il ticket va a uno o più gruppi del proprio centro e/o a uno o più gruppi del promotore.
3. **Almeno un gruppo** fra quelli scelti, sempre.
4. **Conversazione unica.** Con più gruppi coinvolti c'è un solo ticket e una sola conversazione: ogni gruppo coinvolto legge tutti i messaggi, compresi quelli degli altri gruppi, e può rispondere.
5. **I gruppi coinvolti restano quelli scelti all'apertura.** Per cambiarli si chiude il ticket e se ne apre un altro. Nessuna aggiunta né rimozione dopo.
6. **Chiusura.** La capability resta `internal:close:ticket`. Se il ticket è stato aperto dal **promotore**: chiude qualunque gruppo del promotore che abbia la capability e veda il ticket. Se è stato aperto da un **centro**: chiude chiunque abbia la capability e veda il ticket. Chi apre o risponde, da solo, non chiude (regola esistente).
7. **Selezione nel dialogo «Nuovo ticket»** (approvata con un bozzetto): chi apre per conto del promotore vede i gruppi del centro del paziente con «Tutti i gruppi del centro» e le singole spunte; chi apre per conto di un centro non promotore vede due sezioni, i gruppi del proprio centro e i gruppi del promotore, con le singole spunte. I gruppi del promotore non compaiono a chi è già del promotore. Nel ticket aperto compare l'elenco dei gruppi coinvolti.
8. **Ticket esistenti**: restano a un gruppo solo, senza modifiche.

## Obiettivi

- Le regole 1-8, applicate dal microservizio (fonte di verità), non dal client.
- Nessuna regressione sui ticket a un solo gruppo (blocco «Conferma CRF», «I miei ticket», pannello, allegati, audit).

## Non obiettivi

- Nessuna modifica dei gruppi dopo l'apertura, nessun «inoltra a».
- Nessuna email (le notifiche email sono escluse da questo lavoro).
- Nessun cambio di come Zammad mostra il ticket ai propri agenti: in Zammad nativo il ticket compare ai soli agenti del gruppo primario (vedi sotto); la piattaforma lo mostra a tutti i coinvolti.

## Anti-obiettivi (fallimento anche se «funziona»)

- Un gruppo non coinvolto, o di un altro centro, che vede il ticket o ci scrive.
- Un gruppo scelto che non appartiene al centro del paziente né al promotore di quel paziente.
- Chiusura da chi non ha la capability, o dal centro quando ha aperto il promotore.
- Un ticket che cambia gruppi coinvolti dopo l'apertura.
- Regressione di visibilità sui ticket esistenti.

## Vincoli

- Stack: Quarkus/Java 21 (`irccs-microservice-zammad`), React/TypeScript (`irccs-react-dashboard`), Zammad 7.2 REST, Keycloak. Commenti e log in italiano; log senza nomi, email o testi; stile dei file vicini.
- Un ticket Zammad ha un solo `group_id`: i gruppi coinvolti si salvano in attributi personalizzati del ticket e la visibilità è decisa dal microservizio (come oggi per il resto: `TicketAccessPolicy`).
- Il microservizio calcola i gruppi ammessi da dati affidabili (promotore dello studio del paziente, centro del paziente, gruppi del promotore e del centro), non da ciò che dice il client.
- Nomi degli attributi Zammad: niente suffissi `_id`/`_ids`, niente nomi riservati (`scope`).
- Chiave `X-Active-Group` = id del gruppo Keycloak attivo di chi chiama; permessi sul ticket confrontati sul gruppo Zammad corrispondente.
- Nessun commit finché l'utente non lo chiede; branch `feature/PASTRL-<n>`, PR aperta dalla CI.

## Come funziona (scelte del progettista, da rivedere)

1. **Dati nel ticket.** Quattro attributi Zammad nuovi: `targetgroups` (id dei gruppi Zammad coinvolti, salvati come `|12|34|`), `openedby` (`SPONSOR` o `CENTRE`, deciso dal server alla creazione), `opengroup` (gruppo Zammad di chi apre) e `sponsororg` (organizzazione del promotore, per la regola di chiusura; aggiunto dal piano). `group_id` del ticket = il primo gruppo coinvolto (gruppo primario). Creati dallo script di installazione degli attributi, come gli altri.
2. **Creazione.** Il microservizio risolve dal paziente: lo studio, il promotore (`ResearchStudy.sponsor`) e il centro. Determina se chi chiama appartiene al promotore o a un centro dal suo gruppo attivo, calcola i gruppi ammessi (regole 1-2), rifiuta con 403 qualunque gruppo fuori dall'elenco, e scrive gli attributi. Se Zammad non lascia creare all'utente nel gruppo primario si usa l'identità di servizio, come oggi (il cliente resta l'utente).
3. **Elenco dei gruppi selezionabili.** L'endpoint `GET tickets/groups-for-patient` evolve: restituisce due sezioni (`centre`, `sponsor`) con i gruppi ammessi a chi chiama, e un indicatore di chi sta aprendo (`SPONSOR` o `CENTRE`).
4. **Visibilità e scrittura.** `TicketAccessPolicy` considera «gruppo del ticket» l'insieme `{group_id} ∪ targetgroups`: lettura se il chiamante ha `read`/`change`/`full` su uno qualunque di essi, oltre alle regole di sempre (ha aperto, paziente visibile). Scrivere/rispondere: aver aperto o `change`/`full` su uno dei gruppi coinvolti.
5. **Chiusura.** La capability `internal:close:ticket` più la visibilità del ticket, più: se `openedby = SPONSOR`, il chiamante deve appartenere al promotore dello studio del paziente.
6. **Dashboard.** `NewTicketDialog` con la scelta a spunte (bozzetto approvato); pannello e «I miei ticket» mostrano i gruppi coinvolti; tutto il resto invariato. Traduzioni in italiano, inglese, tedesco e francese.
7. **Ticket vecchi.** Senza `targetgroups` valgono solo `group_id` e `openedby` assente: comportamento di oggi.

## Scelte lasciate al realizzatore

- Come risalire dal paziente allo studio, al promotore e ai gruppi del promotore (FHIR e Keycloak/Zammad già usati in `PatientCentreGroups`).
- Struttura delle classi e dei test; formato esatto dell'elenco in `targetgroups`.
- Test E2E nello stile di `e2e_ticket_*.py`.

## Chiarimenti e scelte del progettista (dopo la lettura del revisore)

Marcate «mia scelta» sono decisioni del progettista da rivedere; le altre discendono dalle regole del committente.

1. **Studio e promotore.** Lo studio si ricava dal **ticket** (la CRF/ciclo indicati nel ticket appartengono a un percorso paziente = uno studio, lo stesso che oggi il ticket riporta in `patientjourneydisplay`), non dal solo paziente. Il promotore è `ResearchStudy.sponsor` di quello studio. Se lo studio non si ricava, non ha `sponsor`, o è ambiguo: nessun gruppo del promotore selezionabile e `openedby = CENTRE`; i gruppi del centro del paziente restano ammessi. *(Mia scelta; nessun 403 in questo caso.)*
2. **Paziente del centro del promotore.** Se il centro del paziente coincide con l'organizzazione promotore, i gruppi del promotore e del centro sono lo stesso insieme: una sola sezione, senza doppioni. Chi apre dal promotore su un proprio paziente ha `openedby = SPONSOR`. Un centro non promotore non vede pazienti del promotore (regola di visibilità del paziente esistente), quindi il caso inverso non si presenta. *(Mia scelta.)*
3. **«Appartiene al promotore».** Il gruppo Keycloak attivo di chi chiama (`X-Active-Group`) appartiene all'organizzazione promotore se la sua organizzazione radice coincide (stesso legame già usato in `PatientCentreGroups`: identificativo dell'organizzazione = gruppo radice Keycloak = gruppi Zammad con quell'`organization`). Vale solo il gruppo attivo, non le altre appartenenze. Il superadmin senza gruppo attivo scelto non può aprire ticket (come oggi non ha un contesto per vedere il paziente). *(Mia scelta.)*
4. **Chiusura con `openedby = CENTRE`.** Include i gruppi del promotore coinvolti, se hanno la capability e vedono il ticket. Con `openedby` assente (ticket vecchi) resta il comportamento di oggi: capability e visibilità. *(Dalle regole del committente.)*
5. **Gruppo primario e azioni dirette in Zammad.** Il primo gruppo scelto nel dialogo diventa `group_id`; l'ordine in elenco è prima i gruppi del centro, poi quelli del promotore. Le azioni fatte direttamente nell'interfaccia di Zammad (assegnatario, stato) sono fuori ambito. Se Zammad non lascia creare all'utente nel gruppo primario si crea con l'identità di servizio, come oggi. *(Mia scelta.)*
6. **«Tutti i gruppi del centro».** Uno **snapshot al momento dell'apertura**: i gruppi creati dopo non entrano nel ticket. Restano esclusi i gruppi inattivi e `annunci_*`, come oggi. *(Dalla regola 5; il resto mia scelta.)*
7. **Ricerca dei ticket e blocco «Conferma CRF».** Il blocco usa gli attributi `patient`/`crf`/`careplan` con l'identità di servizio e non i gruppi: non cambia. «I miei ticket» e il pannello cercano anche i ticket il cui gruppo compare in `targetgroups`: `targetgroups` si salva come `|12|34|` (barre ai due estremi, per non confondere 12 con 112) e si cerca con la condizione «contiene `|12|`», che Zammad risolve senza indice di ricerca. *(Mia scelta.)*

## Da decidere con il committente

Nessun punto aperto che cambi quello che si costruisce.
