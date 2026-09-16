# Backup/Restore — HAPI FHIR + Keycloak

Sistema di backup notturno per i tre database postgres della stack prod
(`postgres-hapi-fhir`, `postgres-keycloak`, `postgres-hapi-audit` — DB audit
trail separato con hash-chain, vedi memoria progetto
`audit-trail-compliance-gaps`). RPO 24h, esecuzione a caldo (nessun downtime),
verifica automatica ogni notte, archivio cifrato con retention GFS, replica
offsite.

## Architettura

```
[systemd timer 03:15] → run_backup_container.sh (HOST, non containerizzato)
   ├─ check_disk_space      preflight: BACKUP_MIN_FREE_MB prima di qualunque dump
   ├─ backup_db.sh          pg_dump -Fc sui tre DB → staging/ (plaintext) — docker exec reale
   ├─ verify_restore.sh     restore su container postgres scratch isolato + sanity query
   │                        (fallito → dump resta in staging, quel DB salta la cifratura, alert)
   └─ docker run irccs-backup-run   SOLO sui DB verificati con successo, container SENZA
      ├─ encrypt_and_offsite.sh     alcun accesso Docker (nessun socket, nessun proxy,
      │                             nessun docker-cli nell'immagine)
      └─ retention_cleanup.sh       GFS locale + offsite (rclone), age multi-recipient
```

**Dump e verify girano sull'host** (`run_backup_container.sh`, ExecStart di
`irccs-backup.service`), non dentro un container: quello script gira già come
processo root gestito da systemd con accesso Docker legittimo per gestire la
stack, non è un privilegio nuovo. Solo cifratura/offsite/retention girano in
un container one-shot (`irccs-backup-run`) sui dump già verificati — quel
container **non ha e non può avere accesso alla Docker API**: nessun
`/var/run/docker.sock` montato, nessun `docker-socket-proxy`, nessun
`docker` CLI nell'immagine (base `debian:bookworm-slim` con solo age/rclone).

Questa architettura sostituisce un giro precedente che instradava dump+verify
dentro il container via `tecnativa/docker-socket-proxy` a permessi ridotti:
verificato EMPIRICAMENTE che con quella configurazione un container
compromesso poteva comunque fare `docker create --privileged -v /:/host` ed
uscire verso root host (il proxy filtra per categoria di endpoint, non per
campo del payload — non esiste un modo di dargli "solo exec su container
esistenti" escludendo "crea container nuovo" una volta che serve la capacità
di creare i container scratch per `verify_restore.sh`). La fix strutturale
elimina il problema alla radice invece di limitarlo: il container che gira
con credenziali potenzialmente sensibili (chiavi age, credenziali offsite)
non tocca mai Docker, e chi lo compromette può al massimo leggere/scrivere
dentro `BACKUP_ROOT` e usare age/rclone — nessuna via di escape verso l'host,
verificato con test reale (`which docker` → non presente,
`/var/run/docker.sock` → assente).

Log strutturati (`level=info|warn|error`) su stdout/stderr → journald (via
systemd) → Alloy (`loki.source.journal`, aggiunto in
`monitoring-config/config.alloy`) → Loki. Alert in `alerting/backup-rules.yaml`,
dashboard in `monitoring-config/dashboards/irccs-backup.json` (auto-provisionata,
stesso meccanismo delle altre dashboard nella cartella — nessun setup aggiuntivo
oltre a fondere `backup-rules.yaml` e riavviare/reload Alloy).

## File

| File | Scopo |
|---|---|
| `scripts/lib_common.sh` | logging condiviso + preflight spazio disco (`check_disk_space`) |
| `scripts/backup_db.sh` | dump dei tre DB (hapi, keycloak, hapi-audit) |
| `scripts/verify_restore.sh` | test restore + sanity query su container scratch |
| `scripts/encrypt_and_offsite.sh` | cifratura age multi-recipient + push offsite |
| `scripts/retention_cleanup.sh` | pulizia GFS archivio locale + offsite (rclone; rsync manuale) |
| `scripts/backup_nightly.sh` | orchestratore (entry point del timer) |
| `scripts/verify_archive_integrity.sh` | verifica periodica (settimanale) di un archivio a campione per DB, decifra+restore reale su scratch, rileva bitrot |
| `scripts/restore_db.sh` | drop+create+pg_restore per un DB, protetto da conferma hostname (usato da `RESTORE_PLAYBOOK.md`) |
| `systemd/irccs-backup.{service,timer}` | schedulazione host backup notturno (non container: sopravvive a redeploy stack) |
| `systemd/irccs-backup-verify.{service,timer}` | schedulazione host verifica integrità settimanale (domenica 04:30) |
| `alerting/backup-rules.yaml` | regole Grafana (6 regole: fallito, assente, disco insufficiente, offsite fallito, backup bloccato, verifica integrità fallita — da fondere in `monitoring-config/alerting/rules.yaml`) |
| `../monitoring-config/config.alloy` (modificato) | aggiunto `loki.source.journal` per ingestione log systemd `irccs-backup.service` |
| `../monitoring-config/dashboards/irccs-backup.json` | dashboard Grafana (stato ultimo backup, errori, log raw) — auto-provisionata |
| `.env.backup.example` | template config (copiare come `.env.backup`, non committare) |
| `RESTORE_PLAYBOOK.md` | procedura DR passo-passo + log storico test |
| `scripts/install.sh` | installer automatico (host nuovo) — vedi sotto |

## Setup (una tantum)

Su un host nuovo, `sudo backup/scripts/install.sh` automatizza gli step 1, 2
(keygen), 5, 7, 8 sotto (idempotente, rieseguibile). Restano manuali gli step
3, 6, 9 (credenziali interattive / verifica umana obbligatoria) — l'installer
stampa a fine run la checklist di cosa resta da fare. Dettaglio completo in
`DEPLOY_PROD.md`.

Sequenza manuale equivalente, se non si usa `install.sh`:

1. `apt install age rclone` (o equivalente) sull'host prod.
2. `age-keygen -o <path-sicuro-fuori-da-questo-host>/irccs-backup-key.txt` — annotare la chiave pubblica, la privata **non** resta sull'host di backup.
3. `rclone config` per il remote offsite (nome a scelta, es. `offsite-remote`).
4. `cp backup/.env.backup.example backup/.env.backup` e compilare (root path, retention, `BACKUP_AGE_RECIPIENT`, `BACKUP_OFFSITE_TARGET`).
5. `chmod +x backup/scripts/*.sh`
6. `cp backup/systemd/irccs-backup.{service,timer} /etc/systemd/system/` (adattare `WorkingDirectory`/`ExecStart` al path reale della checkout su quell'host).
7. `systemctl daemon-reload && systemctl enable --now irccs-backup.timer`
8. Fondere `alerting/backup-rules.yaml` in `monitoring-config/alerting/rules.yaml` esistente (adattare label `unit=` al setup Alloy reale — verificare come Alloy etichetta i job systemd/journald su quell'host).
9. (opzionale ma raccomandato) `cp backup/systemd/irccs-backup-verify.{service,timer} /etc/systemd/system/`, adattare `ExecStart`/env come al passo 6, impostare `BACKUP_VERIFY_KEY_FILE` in `.env.backup` (path alla chiave privata age — trade-off esplicito: questa verifica periodica richiede che una copia della chiave sia disponibile su questo host, vedi commento nello script). `systemctl enable --now irccs-backup-verify.timer`.

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
- [x] Installer automatico host nuovo (`scripts/install.sh`, non ancora testato su host reale)
- [x] DB audit trail (`postgres-hapi-audit`) incluso nella pipeline (2026-09-16)
- [x] Container di backup senza alcun accesso Docker (dump+verify spostati sull'host, no socket/proxy/docker-cli — escape verificato e chiuso, 2026-09-16)
- [x] Multi-recipient age key (`BACKUP_AGE_RECIPIENTS`, retrocompatibile, 2026-09-16)
- [x] Retention GFS estesa all'offsite (rclone; rsync resta manuale, 2026-09-16)
- [x] Preflight spazio disco prima del dump (`BACKUP_MIN_FREE_MB`, 2026-09-16)
- [x] Verifica periodica integrità archivio (`scripts/verify_archive_integrity.sh` + timer settimanale, campiona e restora a rotazione, 2026-09-16)
- [x] Restore protetto da conferma hostname (`scripts/restore_db.sh`, sostituisce i comandi copia-incolla in `RESTORE_PLAYBOOK.md`, 2026-09-16)
- [x] Alert Grafana estesi (disco insufficiente, offsite fallito, backup bloccato, verifica integrità fallita — 6 regole totali, 2026-09-16)
- [x] Dashboard `irccs-backup.json` allineata alle 6 regole alert (5 pannelli nuovi, 2026-09-16)
- [x] Chiave dedicata per verifica periodica, warning se `BACKUP_AGE_RECIPIENTS` ha meno di 3 recipient totali (2026-09-16)
- [x] Margine di sicurezza (`BACKUP_OFFSITE_DELETE_GRACE_DAYS`, default 3gg) prima della cancellazione reale dall'offsite (2026-09-16)
- [x] Preview contenuto dump (`pg_restore --list`) prima della conferma in `restore_db.sh`, blocco su dump illeggibile, warning su dbname mismatch (2026-09-16)
- [x] Hardening container backup (`--cap-drop=ALL` + sole CHOWN/DAC_OVERRIDE/FOWNER, `no-new-privileges`, 2026-09-16)
- [x] Container encrypt/offsite/retention non riceve più i segreti della stack (`.env` completo — solo `backup/.env.backup`, 2026-09-16)
- [x] Immagine Docker pinnata (digest base image + versioni age/rclone, build riproducibile, 2026-09-16)
- [ ] Test restore reale su ambiente scratch, RTO misurato
- [ ] Scelta e configurazione target offsite definitivo
- [ ] Installazione timer su host prod
- [ ] Backup separato per `dicom/` (volume TAC, non coperto da questo sistema — vedi nota sotto)
- [ ] (fase 2, solo se necessario) PITR con pgBackRest/WAL-G se RPO 24h risulta insufficiente

## Rischi noti e decisioni aperte

Punti emersi da due giri di analisi critica architettura/sicurezza/affidabilità
(2026-09-16), non ancora chiusi con codice — richiedono una decisione
organizzativa più che tecnica, o sono accettati come rischio residuo per ora:

- ~~**CRITICO — escape verso root host attraverso il proxy Docker**~~
  **RISOLTO (2026-09-16)**: un giro precedente aveva instradato dump+verify
  dentro il container di backup via `docker-socket-proxy`, verificando
  empiricamente che l'escape (`docker create --privileged`) restava possibile
  nonostante l'hardening (cap-drop, permessi ridotti sul proxy) — il proxy
  filtra per categoria di endpoint, non per campo del payload, e non esiste
  un modo di permettere "exec su container esistenti" escludendo "crea
  container nuovo". Fix strutturale applicata: dump e verify ora girano
  sull'host (`run_backup_container.sh`, già trusted come ExecStart di
  systemd), il container `irccs-backup-run` fa SOLO cifratura/offsite/
  retention e non ha alcun accesso Docker (nessun socket, nessun proxy,
  nessun docker-cli nell'immagine) — verificato con test reale che il
  container non ha `docker` CLI ne' vede `/var/run/docker.sock`. Vedi
  Architettura sopra.
- **3-2-1 non realmente indipendente**: locale + offsite sono 2 copie, ma
  raggiungibili con le STESSE credenziali dalla stessa identità (l'host di
  backup). Chi compromette l'host può cancellare entrambe prima che
  l'alert "backup assente 26h" scatti — **mitigato**: c'è ora un margine di
  sicurezza (`BACKUP_OFFSITE_DELETE_GRACE_DAYS`, default 3gg) prima che la
  retention cancelli DAVVERO dall'offsite (tempo per un operatore di
  accorgersi di un problema), e l'escape verso root host è stato chiuso (vedi
  sopra) — ma le credenziali rclone restano comunque leggibili da chi ha
  accesso al container/host di backup (age/rclone sono legittimamente
  presenti li'). Mitigazione completa richiede credenziali offsite con permessi
  solo-scrittura/append (non delete) lato provider — da configurare nel
  remote scelto (rclone supporta bucket policy separate se il backend le
  supporta, es. S3 IAM condition su `s3:DeleteObject`), non automatizzabile
  qui perché dipende dal provider offsite scelto (vedi `DEPLOY_PROD.md` §3).
- **Nessuna immutabilità/WORM**: né locale né offsite hanno object-lock o
  versioning immutabile. Se il target offsite è S3-compatibile, abilitare
  Object Lock (compliance mode, retention ≥ `BACKUP_KEEP_MONTHLY` mesi) in
  fase di provisioning del bucket — fuori dallo scope di questi script, va
  fatto lato infrastruttura/provider.
- **RPO 24h, nessun PITR**: per un sistema che gestisce consenso/sicurezza
  paziente, la perdita di fino a 24h di dati in caso di disastro potrebbe non
  essere accettabile lato compliance — da verificare con DPO/referente prima
  di considerare "fase 2, PITR con pgBackRest/WAL-G" solo un nice-to-have
  opzionale (vedi lista sopra).
- **Retention backup vs. diritto all'oblio GDPR**: se un paziente esercita
  diritto alla cancellazione, i suoi dati restano comunque nei dump cifrati
  fino a `BACKUP_KEEP_MONTHLY` mesi (locale e offsite). Nessun processo
  documentato per gestire richieste di cancellazione sui backup storici —
  da definire con DPO (politica standard: la cancellazione è considerata
  "in attesa" fino a naturale scadenza retention, documentata come misura
  accettata, oppure richiede procedura di re-cifratura/purge mirato — scelta
  organizzativa, non tecnica).
- **Consistenza referenziale con `dicom/` (TAC)**: un restore del DB HAPI a
  T-24h può referenziare immagini DICOM che nel frattempo sono cambiate o
  sono state cancellate nel volume TAC (il cui backup è "fuori scope" sotto,
  cadenza non ancora progettata). Nessuna garanzia di consistenza tra le due
  fonti in un disaster recovery reale — da tenere presente nel playbook di
  restore come limite noto, non risolvibile senza prima progettare il backup
  TAC con una cadenza/coordinamento esplicito.
- **Scenario ransomware nel restore playbook**: `RESTORE_PLAYBOOK.md`
  assume che l'ultimo backup disponibile sia sempre affidabile. In caso di
  sospetto ransomware/tampering, NON restorare ciecamente dall'ultimo dump:
  verificare prima le date rispetto al momento stimato di compromissione
  (elenco backup disponibili, §1 del playbook) e preferire un punto di
  restore precedente all'attacco anche se più vecchio del limite RPO
  nominale. Aggiunto come nota esplicita in `RESTORE_PLAYBOOK.md`.
- **`HAPI_AUDIT_DB_NAME=hapiaudit` hardcoded/duplicato** come default in più
  script (`backup_db.sh`, `restore_db.sh`) invece che centralizzato in un
  unico posto — se il nome del DB audit cambiasse in futuro, va aggiornato
  in ogni script separatamente (drift risk minore, non urgente).
- **Log strutturati non verificati contro leak di PII**: gli errori
  pg_dump/pg_restore possono includere frammenti di valori che hanno violato
  constraint nel messaggio d'errore, propagati fino a Loki/Grafana via
  journald. Non è mai stata fatta una review esplicita per escludere che dati
  clinici finiscano nei log di errore — da verificare prima di considerare i
  log "sicuri da guardare senza restrizioni" in un contesto sanitario.

## Fuori scope (per ora)

- `dicom/` (bind mount TAC): volume grande, cambia meno spesso dei DB. Backup
  da progettare separatamente (rsync incrementale con `--link-dest` o simile),
  non incluso in questa prima iterazione.
- `keycloak-config/realm-export`, `terminology/`: già versionati in git, non
  richiedono backup runtime separato.
- Volume `audit_integrity_state` (checkpoint hash-chain di `irccs-audit-integrity`,
  non il DB): stato ricostruibile dal DB `hapi-audit` stesso al riavvio
  (vedi memoria `hapi-identifier-modifier-broken` — re-seed hash-chain al
  restart HAPI aggancia il tail giusto), non backuppato separatamente per ora.
