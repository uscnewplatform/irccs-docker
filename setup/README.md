# setup/ — installare e gestire un ambiente

Gli script sono raggruppati per **quando servono**, non per tipo di file.

```
setup/
  install.sh          ← UN comando per un cliente nuovo (lancia le fasi 10..60 in ordine)
  10-keycloak/        ruoli e autorizzazioni che il realm-export non contiene
  20-fhir/            SearchParameter, Patient Journey J-LI, tipi di consenso
  30-terminologie/    librerie CRF e farmaci AIFA (i dati stanno in ../data-import/)
  40-zammad/          attributi, webhook/trigger delle email, spegnimento email native, configurazione salvata (config/), verifica
  50-audit/           audit trail: partizione, SearchParameter, immodificabilità, pgaudit   (opzionale)
  60-monitoraggio/    cron di archiviazione Loki                                            (opzionale)
  ops/                esercizio quotidiano: controllo integrità audit, snapshot Loki, validazioni
  dev/                solo sviluppo e CI: prove E2E dei ticket, controlli sul compose CI
```

Fuori da `setup/`: `backup/` (sistema di backup e restore, ha il suo `scripts/install.sh`), `host-maintenance/`
(modalità manutenzione), `data-import/` (dati e import delle terminologie), `keycloak-config/` (realm-export e provider).

## Cliente nuovo, da zero

1. **Preparare l'ambiente**: copiare `.env_example` in `.env` e compilarlo; `docker compose up -d` (vedi `docs/.../installazione.adoc`
   e `deployment.adoc`). Attendere che Keycloak e HAPI rispondano.
2. **Lanciare l'installer**:
   ```bash
   cd irccs-docker
   ADMIN_PASS=<password admin Keycloak> ./setup/install.sh --hapi-url http://localhost:8080/fhir --kc-url http://localhost:9445
   ```
   Opzioni per attivare le fasi facoltative: `--zammad-url URL` (con `ZAMMAD_TOKEN` e `WEBHOOK_SECRET` nell'ambiente),
   `--with-audit`, `--with-ops`. Con `--dry-run` stampa i comandi senza eseguirli; `--from N`, `--only N`, `--skip N`
   per ripartire o saltare fasi; `--yes` per non chiedere conferma.
3. **Passi manuali** (l'installer li ricorda alla fine): SMTP, lingua e tema, client-secret in Keycloak; SSL; creazione
   di centri e primo superadmin; assegnazione ai gruppi dei ruoli creati (`internal:confirm:crf`, `internal:close:ticket`...);
   token di servizio Zammad nell'`.env` del microservizio; terminologia LOINC (opzionale, account loinc.org).

Tutti gli script sono **idempotenti**: si possono rilanciare. I segreti si passano solo dall'ambiente, mai come argomento.

## Cosa c'è in ogni cartella

| Cartella | Script | Quando si usa |
|---|---|---|
| `10-keycloak/` | `add-audit-trail-role.py`, `add-documentreference-authz.py`, `add-farmacovigilanza-role.sh`, `add-ticket-gate-roles.py`, `add-zammad-authz.py`, `sync-fhir-authz.py` (+ `SYNC-FHIR-AUTHZ.md`) | Installazione; `sync-fhir-authz.py` anche quando si aggiunge un tipo FHIR e le rotte danno 403 ai non-admin |
| `20-fhir/` | `install_searchparameters.sh`, `install_jli.sh`, `install_consent_types.sh` | Installazione (i SearchParameter per primi) |
| `30-terminologie/` | `install_terminologie.sh [crf\|aifa\|tutto]` | Installazione; per aggiornare solo i farmaci o solo le librerie |
| `40-zammad/` | `install_zammad_attributes.sh`, `install_zammad_email_webhook.sh`, `disable_zammad_native_emails.sh`, `apply_zammad_config.sh` (+ `config/`, vedi il suo README), `verify_zammad.sh` | Installazione Zammad; `verify_zammad.sh` dopo ogni deploy |
| `50-audit/` | `setup_audit_partition.sh`, `install_audit_searchparameter.sh`, `install_audit_db_protection.sh`, `install_audit_pgaudit.sh` | Installazione con audit acceso; da rieseguire se si ricrea il volume dello store audit |
| `60-monitoraggio/` | `install_loki_archive_cron.sh` | Installazione (insieme al backup di `backup/scripts/install.sh`) |
| `ops/` | `audit_integrity_loop.sh`, `run_audit_integrity_cron.sh`, `verify_audit_*.py`, `validate_*.sh`, `archive_loki_snapshot.sh` | Esercizio: girano da container o da cron, non vanno lanciati a mano per installare |
| `dev/` | `e2e_ticket_*.py`, `check_ci_compose.sh`, `restore_db_test.sh` | Sviluppo e CI, mai su un cliente |

## Script rimossi

Le migrazioni una-tantum già eseguite su tutti gli ambienti (allineamento ticket CRF, upgrade dell'audit trail, migrazione degli
AuditEvent verso lo store dedicato, backfill farmacovigilanza, scambio EORTC/PROCTC, reindex) non sono più nel repository: si
recuperano dalla storia git, nei commit precedenti al riordino di `setup/`. Un cliente nuovo non ne ha bisogno.
