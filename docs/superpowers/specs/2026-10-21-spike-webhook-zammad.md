# Spike webhook Zammad 7.2.2 — esiti (2026-10-21)

Ambiente: stack isolato locale (`spike-zammad-webhook/docker-compose.yaml`, Zammad 7.2.2-0000, **Elasticsearch disattivato**, volumi nuovi, solo localhost). Nessuna chiamata al Zammad infocube reale. Script riproducibili in `spike-zammad-webhook/` (`setup.py`, `exp1.py`, `exp2.py`, `receiver.py`).
Limite: ES disattivato e dati vuoti; la produzione puo' avere configurazione diversa (stati custom, ES).

## Esiti verificati

| # | Tema | Esito | Implicazione sul progetto |
|---|---|---|---|
| 1 | Formato webhook | POST JSON `{ticket, article}`; `ticket` contiene **tutti** gli attributi custom (`crf`, `careplan`, `patient`, `crfscope`, `qrid`, ...), `state` (nome), `state_id`, `updated_at`; `article` = ultimo articolo (con `internal`) | l'handler non deve loggare ne' inoltrare il body (PII: cliente, email, testo) |
| 2 | Firma | `X-Hub-Signature: sha1=<hmac>` con `signature_token`, calcolata sul body esatto: verificata su 24/24 eventi. Altri header: `X-Zammad-Delivery` (uuid **per consegna**), `X-Zammad-Trigger` (nome trigger) | HMAC-SHA1 (non SHA-256): confronto a tempo costante sul body grezzo. Nessun numero di sequenza ne' event-id stabile: `X-Zammad-Delivery` non deduplica |
| 3 | Snapshot al momento della consegna | 3 modifiche rapide di priorita' hanno prodotto 3 consegne con payload **identico (stato finale)**, stesso `updated_at` | conferma: il payload non e' ordinabile/affidabile; **webhook = trigger, lo stato si rilegge da Zammad** |
| 4 | Duplicati | stesso cambiamento consegnato 2 volte (delivery id diversi) in piu' casi (es. pending reminder, tutte le update successive) | idempotenza obbligatoria sul ticket id + rilettura |
| 5 | Latenza | consegna entro pochi secondi dall'azione (job in background) | finestra di inconsistenza dell'ordine di secondi in condizioni normali |
| 6 | Retry | con receiver in errore 500: ritentato a +0, ~+13, ~+33, ~+66, ~+107 s (backoff crescente); non garantito all'infinito | webhook persi possibili oltre i retry: **riconciliazione obbligatoria** |
| 7 | Cancellazione | `DELETE /tickets/{id}` **non genera alcun evento** | la riconciliazione deve rilevare ticket spariti (Task orfano); l'endpoint DELETE del ms resta chiuso |
| 8 | Merge | `PUT /ticket_merge/{source}/{target}`: il target e' il **numero** del ticket, non l'id (con l'id risponde 200 senza unire). Con il numero il ticket sorgente passa a `merged` e **genera** l'evento update | il Task del sorgente `merged` resta non bloccante; conservare il riferimento al ticket di destinazione |
| 9 | Stati | ids di default 7.2.2: 1 new, 2 open, 3 pending reminder, 4 closed, 5 merged, 6 pending close. **Il `state_id: 7` usato oggi dalla dashboard per gli annunci NON e' uno stato di default**: e' uno stato custom della vostra istanza | classificare per **state_type** (new/open/pending reminder/pending action/closed/merged, via `GET /ticket_states`, con cache) e non per nome/id. Tipo sconosciuto = bloccante. Verificare in produzione (sola lettura) quali stati custom esistono |
| 10 | Nomi attributi | `scope` e' parola riservata; i nomi che finiscono per `_id`/`_ids` sono vietati | gli attributi nuovi si chiamano **`crfscope`** e **`qrid`** (non `scope`/`qr_id`) |
| 11 | Ricerca | con Elasticsearch disattivato `GET /tickets/search?query=...` restituisce **sempre vuoto**, anche per `state.name:open` | non basarsi sulla ricerca Zammad. Riconciliazione e backfill con `GET /tickets?page&per_page` (include gli attributi custom) + GET per ticket |
| 12 | X-On-Behalf-Of | funziona per email: l'articolo risulta creato dall'utente indicato. Utente inesistente -> **403** (nessun fallback al proprietario del token). Bearer e `Token token=` accettati | schema confermato per l'identita' reale; il ms lo costruisce lato server da una mappatura stabile subject->utente Zammad; il token di servizio deve avere il permesso di impersonare |
| 13 | Creazione webhook/trigger via API | `POST /webhooks` (`endpoint`, `signature_token`, `ssl_verify`) e `POST /triggers` con `condition: {ticket.action: {operator: is, value: create|update}}`, `perform: {notification.webhook: {webhook_id}}`: servono **due trigger** (create e update) | da inserire nello script di installazione irccs-docker |
| 14 | Host privati | il webhook verso un host interno (host-gateway) funziona, nessun blocco SSRF locale | in produzione l'endpoint del ms sara' raggiungibile solo in rete interna |
| 15 | Migrazioni Object Manager | `object_manager_attributes_execute_migrations` fa riavviare Rails: il container esce senza `restart` policy | negli ambienti con orchestratore serve la restart policy; lo script di install deve attendere il ritorno del servizio |

## Decisioni conseguenti per il progetto
1. Webhook = **notifica**; a ogni evento il ms rilegge il ticket (stato + attributi) con `GET /tickets/{id}` e scrive/aggiorna il Task. Duplicati e snapshot incoerenti convergono.
2. Deduplica per `ticket.id` (+ rilettura), non per `X-Zammad-Delivery`.
3. Riconciliazione periodica con scansione completa via `GET /tickets` (paginato), che rileva: ticket nuovi senza Task, Task con stato diverso, **ticket cancellati** (Task orfano -> da segnalare, non da chiudere automaticamente).
4. Classificazione stato per `state_type`, tabella `ticket_states` in cache con refresh; stato/tipo sconosciuto = bloccante.
5. Attributi da creare: `crfscope`, `qrid` (non `scope`/`qr_id`). Aggiornare `install_zammad_attributes.sh`, `REQUIRED_TICKET_ATTRIBUTES` e il documento funzionale (sezioni 1.1-1.3, 12.3, 12.4).
6. Da verificare in produzione (sola lettura, con tuo OK): elenco `ticket_states` custom (stato 7), presenza di Elasticsearch, permessi del token di servizio per `X-On-Behalf-Of`.
