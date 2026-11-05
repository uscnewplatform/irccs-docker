# Ticket CRF — domande aperte per il cliente prima del go-live

Data: 2026-10-22. Nate dalla revisione funzionale della versione "tutto a Zammad". Ogni domanda dice cosa cambia nel sistema a seconda della risposta.

## Decisioni che cambiano il comportamento

1. **Chiusura diretta in Zammad.** Chi ha diritto di cambiare stato in Zammad sblocca la CRF senza motivazione né audit della piattaforma; chi può modificare i campi `patient`/`careplan`/`crf` toglie il ticket dal blocco. Va bene? Altrimenti: (a) rendere quei campi non modificabili e limitare il cambio di stato ai gruppi autorizzati (configurazione Zammad), (b) registrare in audit le conferme avvenute dopo chiusure dirette (sviluppo nuovo).
2. **Zammad non disponibile per ore.** Oggi nessuno conferma, nemmeno il responsabile, e la certificazione si ferma. Qual è l'SLA di Zammad? Chi decide di attivare `crf.confirm.override-when-unverifiable=true`, per quanto tempo, e chi controlla le deroghe dopo? La certificazione (`/certify`) deve poter avere una deroga in quel caso?
3. **Ticket riaperto o aperto dopo la conferma.** Oggi non succede nulla (la CRF resta confermata). Si vuole: nulla, un avviso a chi ha confermato, o l'annullo della conferma?
4. **Ticket "in attesa" da settimane.** Continua a bloccare? Serve una scadenza?
5. **CRF ripetibili.** Se lo stesso questionario compare più volte nello stesso ciclo, un ticket blocca tutte le istanze (la chiave è paziente + ciclo + questionario)? È voluto?
6. **Blocco per singolo studio.** Il flag è globale. Serve accenderlo solo per alcuni studi?
7. **Percorsi fuori dal blocco.** Import e modifica diretta (PATCH) delle compilazioni non passano dal blocco. Va accettato per iscritto, o serve coprirli?
8. **Ticket creati direttamente in Zammad** senza i campi paziente/ciclo/CRF non sono visti dal blocco. Accettabile?

## Deroga e tracciabilità

9. Le motivazioni di deroga (10–500 caratteri) sono libere o da elenco? Serve una seconda firma? Chi rivede periodicamente le deroghe, e con che frequenza?
10. Quando Zammad nega all'utente la scrittura sul gruppo, la risposta parte con l'identità di servizio e il nome dell'utente in testa al testo. L'audit di Zammad attribuisce al servizio: è accettabile?

## Privacy e sicurezza

11. Il DPO accetta che id e stato dei ticket siano esposti ai servizi della piattaforma, e che Zammad contenga dati sanitari? Per quanto si conservano i ticket chiusi?
12. Quando e da chi viene ruotato il token Zammad (oggi è in chiaro nel repository)? Serve una data certa prima del go-live.

## Operatività

13. Chi è "l'assistenza" del messaggio di manutenzione, con quali orari e contatti? Va indicato nel testo?
14. Chi può chiudere i ticket (capability `internal:close:ticket`) e chi può derogare (`internal:override:ticket-gate`)? Servono i nomi dei gruppi per i test.
15. ~~Compilazioni del paziente con ticket non verificabili~~ — **Risposta del cliente (22/10): `patient-interview` e i questionari al paziente non richiedono la gestione dei ticket delle CRF.** Rimossa ogni gestione in quei percorsi.

## Per il collaudo in staging

16. Disponibilità di uno Zammad di staging con Elasticsearch acceso e spento, gli stessi gruppi e ruoli di produzione, almeno quattro utenti (senza capability, con chiusura, con deroga, di un'altra organizzazione), due studi, due cicli, una CRF ripetibile, un paziente con più di 200 ticket di prova, ticket in tutti i tipi di stato, un modo per rallentare Zammad e l'accesso ai log (Loki/Grafana).

## Risposte ricevute (22/10)

| # | Risposta del cliente | Cosa è stato fatto |
|---|---|---|
| 1 | La chiusura diretta in Zammad non deve sbloccare: si deve bloccare | Chiusura valida solo se passa dalla piattaforma (segno `crfclosure`), convalida dal pannello, campi chiave non modificabili in Zammad |
| 2 | Decisione interna: i sistemisti attivano la proprietà e riavviano | Nessuna modifica: la regola `crf.confirm.override-when-unverifiable` si cambia con la proprietà e un riavvio. Serve una procedura scritta interna |
| 3 | Di nuovo il flusso come prima (la CRF torna da confermare) | Solo per azioni dalla piattaforma (aprire/riaprire un ticket): la CRF torna in corso con audit. Per le azioni in Zammad la piattaforma non se ne accorge |
| 4 | Sì, un ticket in attesa blocca; le notifiche le gestisce Zammad | Nessuna modifica. Da verificare con chi amministra Zammad che le notifiche e-mail dei ticket in attesa siano configurate |
| 5 | No: ogni CRF è a sé anche nello stesso ciclo (più compilazioni) | Ogni compilazione ha i suoi ticket (attributo `qrid`); un ticket senza compilazione indicata blocca tutte le compilazioni di quella CRF |
| 6 | Ok (blocco globale) | Nessuna modifica |

Restano aperte le domande 7–16.
