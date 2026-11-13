# Configurazione Zammad salvata (da produzione)

Fotografia, ripulita, di ciò che in Zammad **non** è un valore di fabbrica e che un cliente nuovo deve ritrovarsi.
Esportata in sola lettura dall'istanza di produzione il 2026-11-12 (Zammad 7.2.2). Nei file non ci sono segreti
(`signature_token`, token, password, client secret), indirizzi email, host del cliente né id numerici specifici dell'istanza:
dove serve c'è un segnaposto `<...>` o un nome.

## Come si applica

```bash
ZAMMAD_TOKEN=<token admin> ./setup/40-zammad/apply_zammad_config.sh https://<zammad>            # elenca soltanto
ZAMMAD_TOKEN=<token admin> EMAIL_FROM=noreply@cliente.it EMAIL_FROM_NAME="CLIENTE - Ticket" \
  ./setup/40-zammad/apply_zammad_config.sh https://<zammad> --apply [--disable-low-priority] [--no-takeover-trigger] [--no-settings]
```

È la fase 40 di `setup/install.sh` (`--zammad-url`). Idempotente. Va **rilanciato con `EMAIL_FROM`** dopo che il microservizio Zammad
ha creato i gruppi dei centri nuovi: assegna l'indirizzo mittente ai gruppi che ne sono ancora privi.

## Cosa c'è, e da chi è coperto

| File | Contenuto | Applicato da |
|---|---|---|
| (attributi) | `Ticket.crf`, `crfscope`, `studyid`, `targetgroups`… `User/Organization/Group.keycloak_ref`, `Group.organization` | `install_zammad_attributes.sh` |
| (webhook, trigger, job) | webhook «IRCCS Query - email», trigger «IRCCS Query - email (priorità alta)» e «IRCCS News - email», job «IRCCS Query - sollecito (ogni ora)» | `install_zammad_email_webhook.sh` |
| (trigger nativi) | trigger e job nativi che mandavano email, sia i nomi di fabbrica di Zammad sia quelli rinominati in produzione | `disable_zammad_native_emails.sh` |
| `ticket-states.json` | stato **«annuncio»** (news di studio), tipo *pending action*, prossimo stato *closed* | `apply_zammad_config.sh` |
| `triggers.json` | trigger **«Ticket - presa in carico alla risposta»** (new / pending reminder → open alla prima risposta di chi non ha aperto); facoltativo (`--no-takeover-trigger`) | `apply_zammad_config.sh` |
| `settings.json` (`applica`) | `timezone_default` (cambiabile con `ZAMMAD_TIMEZONE`), `ticket_define_email_from=SystemAddressName`, `user_create_account=false`; saltabili con `--no-settings` | `apply_zammad_config.sh` |
| `email.json` | indirizzo mittente assegnato a **tutti** i gruppi + `notification_sender` | `apply_zammad_config.sh` con `EMAIL_FROM` |
| `ticket-priorities.json` | solo normale e alta; «1 low» da disattivare | `apply_zammad_config.sh --disable-low-priority` (facoltativa) |

## Cosa resta manuale

* **Canale SMTP** delle notifiche (Admin → Canali → Email → Notifiche): host e credenziali sono del cliente; la struttura è in `email.json`.
  Senza canale e senza indirizzo sui gruppi Zammad rifiuta l'invio (422) e le email delle Query e delle news non partono.
* **Login SSO con Keycloak** (`settings.json` → `sso`): richiede client id e secret del client Keycloak dedicato.
* `fqdn`, `http_type`, `organization` (nome dell'organizzazione): specifici dell'installazione.
* Variabile della dashboard `VITE_APP_ZAMMAD_TICKET_ANNUNCE_STATE_ID`: deve coincidere con l'id dello stato «annuncio» creato (in produzione 7).

## Cosa NON c'è perché è di fabbrica o a runtime

Ruoli (Admin, Agent, Customer), panoramiche, macro «Close & Tag as Spam», modelli di testo, calendario, SLA (nessuna) sono quelli
predefiniti di Zammad, non personalizzati. I **gruppi** li crea il microservizio Zammad (sync da Keycloak, con `keycloak_ref` e
`organization`); gli **utenti** pure; i **tag** (`mail-apertura`, `news-mail-apertura`, `mail-ultimo-invio-…`) li scrive il microservizio sui ticket.

## Confronto produzione-script (2026-11-12)

* Webhook, trigger «priorità alta» e «News», job di sollecito: **identici** agli script (stesse condizioni e azioni).
* Trigger nativi e job nativi: disattivi come previsto. In produzione i trigger di fabbrica sono stati rinominati («Ticket - …»): `disable_zammad_native_emails.sh`
  ora spegne anche i nomi di fabbrica di un Zammad nuovo («auto reply (on new tickets)», «auto reply (on follow-up of tickets)», «customer notification (on owner change)»).
* Lo stato «annuncio» (in staging «annuncio studio») e il trigger «presa in carico alla risposta» erano fuori da ogni script: ora sono qui.
* «1 low» è **ancora attiva** in produzione (la piattaforma usa solo due priorità).
* Nota «creato da Claude 2026-10-27» sull'indirizzo mittente di produzione: non riportata.
