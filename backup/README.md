# Backup/Restore — HAPI FHIR + Keycloak

Sistema di backup notturno per i due database postgres della stack prod
(`postgres-hapi-fhir`, `postgres-keycloak`). RPO 24h, esecuzione a caldo
(nessun downtime), verifica automatica ogni notte, archivio cifrato con
retention GFS, replica offsite.

## Architettura

```
[systemd timer 03:15] → backup_nightly.sh
   ├─ backup_db.sh          pg_dump -Fc su entrambi i DB → staging/ (plaintext)
   ├─ verify_restore.sh     restore su container postgres scratch isolato + sanity query
   │                        (fallito → dump resta in staging, script esce in errore, alert)
   ├─ encrypt_and_offsite.sh cifratura age → archive/ locale, poi rclone/rsync offsite
   │                        (plaintext rimosso solo dopo cifratura riuscita)
   └─ retention_cleanup.sh  GFS: 14 giornalieri + 8 settimanali + 6 mensili
```

Log strutturati (`level=info|warn|error`) su stdout/stderr → journald (via
systemd) → Alloy (`loki.source.journal`, aggiunto in
`monitoring-config/config.alloy`) → Loki. Alert in `alerting/backup-rules.yaml`,
dashboard in `monitoring-config/dashboards/irccs-backup.json` (auto-provisionata,
stesso meccanismo delle altre dashboard nella cartella — nessun setup aggiuntivo
oltre a fondere `backup-rules.yaml` e riavviare/reload Alloy).

## File

| File | Scopo |
|---|---|
| `scripts/lib_common.sh` | logging condiviso |
| `scripts/backup_db.sh` | dump dei due DB |
| `scripts/verify_restore.sh` | test restore + sanity query su container scratch |
| `scripts/encrypt_and_offsite.sh` | cifratura age + push offsite |
| `scripts/retention_cleanup.sh` | pulizia GFS archivio locale |
| `scripts/backup_nightly.sh` | orchestratore (entry point del timer) |
| `systemd/irccs-backup.{service,timer}` | schedulazione host (non container: sopravvive a redeploy stack) |
| `alerting/backup-rules.yaml` | regole Grafana (da fondere in `monitoring-config/alerting/rules.yaml`) |
| `../monitoring-config/config.alloy` (modificato) | aggiunto `loki.source.journal` per ingestione log systemd `irccs-backup.service` |
| `../monitoring-config/dashboards/irccs-backup.json` | dashboard Grafana (stato ultimo backup, errori, log raw) — auto-provisionata |
| `.env.backup.example` | template config (copiare come `.env.backup`, non committare) |
| `RESTORE_PLAYBOOK.md` | procedura DR passo-passo + log storico test |

## Setup (una tantum)

1. `apt install age rclone` (o equivalente) sull'host prod.
2. `age-keygen -o <path-sicuro-fuori-da-questo-host>/irccs-backup-key.txt` — annotare la chiave pubblica, la privata **non** resta sull'host di backup.
3. `rclone config` per il remote offsite (nome a scelta, es. `offsite-remote`).
4. `cp backup/.env.backup.example backup/.env.backup` e compilare (root path, retention, `BACKUP_AGE_RECIPIENT`, `BACKUP_OFFSITE_TARGET`).
5. `chmod +x backup/scripts/*.sh`
6. `cp backup/systemd/irccs-backup.{service,timer} /etc/systemd/system/` (adattare `WorkingDirectory`/`ExecStart` al path reale della checkout su quell'host).
7. `systemctl daemon-reload && systemctl enable --now irccs-backup.timer`
8. Fondere `alerting/backup-rules.yaml` in `monitoring-config/alerting/rules.yaml` esistente (adattare label `unit=` al setup Alloy reale — verificare come Alloy etichetta i job systemd/journald su quell'host).

## Test prima del go-live

1. **Su pascale-local (dev)**, non su prod: eseguire `backup_nightly.sh` a mano con `.env.backup` puntato a una `BACKUP_ROOT` di test, verificare che dump/verify/encrypt/retention funzionino.
2. Eseguire l'intera procedura in `RESTORE_PLAYBOOK.md` su ambiente scratch, misurare RTO reale, annotarlo nello storico del playbook.
3. Solo dopo test 1+2 riusciti: installare timer su prod (step Setup sopra).

## Stato / prossimi passi

- [x] Script dump + verify + encrypt + retention + orchestratore
- [x] Systemd service/timer
- [x] Ingestione log: `loki.source.journal` in `config.alloy` (label `unit`, `component=irccs-backup`)
- [x] Regole alert Loki (`alerting/backup-rules.yaml`, da fondere in `rules.yaml` esistente)
- [x] Dashboard Grafana `dashboards/irccs-backup.json` (stato ultimo backup, errori 24h, trend 14gg, log raw)
- [x] Playbook restore
- [x] Test end-to-end su pascale-local (dump+verify+encrypt+retention, 3 bug corretti)
- [ ] Test restore reale su ambiente scratch, RTO misurato
- [ ] Scelta e configurazione target offsite definitivo
- [ ] Installazione timer su host prod
- [ ] Backup separato per `dicom/` (volume TAC, non coperto da questo sistema — vedi nota sotto)
- [ ] (fase 2, solo se necessario) PITR con pgBackRest/WAL-G se RPO 24h risulta insufficiente

## Fuori scope (per ora)

- `dicom/` (bind mount TAC): volume grande, cambia meno spesso dei DB. Backup
  da progettare separatamente (rsync incrementale con `--link-dest` o simile),
  non incluso in questa prima iterazione.
- `keycloak-config/realm-export`, `terminology/`: già versionati in git, non
  richiedono backup runtime separato.
