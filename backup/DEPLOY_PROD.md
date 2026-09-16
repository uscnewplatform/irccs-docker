# Deploy in produzione — guida passo-passo

Riferimento per portare `backup/` da testato-su-pascale-local a operativo su un
host diverso (prod, staging, qualsiasi ambiente non-dev). Leggere prima
`README.md` per l'architettura; questo documento è solo la sequenza di
azioni da eseguire su un host nuovo.

Stato validato in dev (2026-09-15): dump, verify (restore reale + sanity
query), cifratura/decifratura age, retention GFS — tutti testati end-to-end
su pascale-local, 3 bug trovati e corretti (vedi log commit). **Non ancora
testati**: push offsite reale, systemd timer su host vero, alert Grafana/Loki
in produzione, restore playbook reale.

**Scorciatoia**: `scripts/install.sh` (idempotente, va eseguito come root)
automatizza i passi 1, 2 (keygen), 5, 7, 8a sotto — a fine run stampa la
checklist di cosa resta manuale (passi 3, 6, 8b, 9). Restano da leggere lo
stesso per capire cosa succede; questa guida resta la sequenza di riferimento
se si preferisce eseguire i passi a mano o l'installer fallisce a metà.

## 0. Prerequisiti host

- Accesso root/sudo sull'host dove gira la stack prod (`irccs-docker`, quello
  con `container_name: postgres-hapi-fhir` / `postgres-keycloak`).
- Docker CLI funzionante sull'host (dump e verify girano qui direttamente,
  non dentro un container — vedi README, sezione Architettura). Il container
  di backup (`irccs-backup-run`, solo cifratura/offsite/retention) non ha
  invece alcun accesso Docker: nessun socket, nessun proxy, niente da
  configurare per quello.
- Connettività di rete verso: repository `age` (o pacchetto già in apt),
  destinazione offsite scelta (secondo host / NAS / object storage).

## 1. Installare i tool richiesti

*(automatizzato da `install.sh` step 1)*

```bash
sudo apt update && sudo apt install -y age rclone
# oppure rsync se si sceglie quel metodo di offsite invece di rclone
```

Verificare: `age --version`, `rclone version` (o `rsync --version`).

## 2. Generare la chiave di cifratura

*(automatizzato da `install.sh` step 2 — genera solo se `/etc/irccs-backup-key/irccs-backup-key.txt` non esiste già; override path con `BACKUP_INSTALL_KEY_DIR`)*

```bash
mkdir -p /etc/irccs-backup-key   # o altra directory con permessi ristretti
age-keygen -o /etc/irccs-backup-key/irccs-backup-key.txt
chmod 600 /etc/irccs-backup-key/irccs-backup-key.txt
```

**Critico**: copiare subito la chiave privata (`irccs-backup-key.txt`) fuori
da questo host, in un posto sicuro e separato (password manager aziendale,
vault, secondo host). Se l'host di backup viene perso insieme alla chiave
privata, i dump cifrati diventano illeggibili — è lo stesso rischio che si
sta cercando di mitigare con l'intero sistema.

**Raccomandato: almeno 2 chiavi da 2 custodi indipendenti** (es. referente
infra + referente sicurezza/DPO), non solo 1. Ripetere `age-keygen` per un
secondo custode (chiave privata in un vault separato dal primo) ed elencare
entrambe le chiavi pubbliche in `BACKUP_AGE_RECIPIENTS` al passo 5 — perdere
una delle due chiavi private non rende illeggibili i backup se l'altra
resta disponibile. Un solo recipient è ancora supportato (retrocompatibile)
ma resta un single point of failure sulla capacità di restore.

Annotare la **chiave pubblica** stampata da `age-keygen` (riga `Public key:
age1...`) per ciascun custode: serve al passo 5.

## 3. Configurare il target offsite

Scegliere in base a cosa è disponibile realmente in produzione (vedi
discussione aperta in README — secondo host fisico IRCCS è la raccomandazione
di default per dati sanitari, evitando cloud pubblico salvo garanzie
contrattuali/DPA adeguate).

```bash
# esempio con rclone verso un secondo host via SFTP
rclone config
# creare un remote (es. "irccs-offsite") di tipo sftp/webdav/s3 a seconda del target
rclone lsd irccs-offsite:   # verifica connettività
```

## 4. Clonare/aggiornare il repo sull'host

```bash
cd /opt   # o il path scelto per l'installazione prod
git clone git@github.com:uscnewplatform/irccs-docker.git
# oppure, se già presente: git pull sul branch che contiene backup/
```

## 5. Configurare `backup/.env.backup`

*(creazione file + `chmod +x scripts/*.sh` automatizzati da `install.sh` step 5 — compilazione valori resta manuale)*

```bash
cd /opt/irccs-docker/backup
cp .env.backup.example .env.backup
```

Editare `.env.backup`:

| Variabile | Valore |
|---|---|
| `BACKUP_ROOT` | path locale con spazio sufficiente, es. `/var/backups/irccs` |
| `BACKUP_MIN_FREE_MB` | soglia minima spazio libero prima di avviare il dump (default 2048 se non impostata, va bene lasciarla commentata) |
| `BACKUP_KEEP_DAILY/WEEKLY/MONTHLY` | default 14/8/6 vanno bene, adattare a policy interna se diversa |
| `BACKUP_AGE_RECIPIENTS` | le chiavi pubbliche generate al passo 2 (**almeno 2**, una per custode, separate da spazio/virgola) — vecchia var singolare `BACKUP_AGE_RECIPIENT` ancora supportata ma sconsigliata (single point of failure) |
| `BACKUP_OFFSITE_METHOD` | `rclone` (o `rsync`) |
| `BACKUP_OFFSITE_TARGET` | remote configurato al passo 3, es. `irccs-offsite:irccs-backup/` |
| `BACKUP_HAPI_CONTAINER` / `BACKUP_KEYCLOAK_CONTAINER` / `BACKUP_HAPI_AUDIT_CONTAINER` | lasciare commentate — i default (`postgres-hapi-fhir`, `postgres-keycloak`, `postgres-hapi-audit`) sono già i nomi container di questo repo prod |

`.env.backup` **non va committato** (già in `.gitignore`? verificare — se
manca, aggiungerlo: contiene path e potenzialmente riferimenti a credenziali
del remote offsite).

```bash
chmod +x scripts/*.sh
```

## 6. Test manuale prima di schedulare

Con la stack prod già in esecuzione (`postgres-hapi-fhir`, `postgres-keycloak`
up):

```bash
cd /opt/irccs-docker/backup/scripts
./backup_nightly.sh
```

Verificare:
- exit code 0
- log finale `backup notturno completato con successo`
- file `.dump.age` presenti in `$BACKUP_ROOT/{hapi,keycloak,hapi-audit}/archive/`
- file presente anche sul target offsite (`rclone ls irccs-offsite:irccs-backup/`)
- se sono configurate 2+ chiavi in `BACKUP_AGE_RECIPIENTS`, verificare che
  ENTRAMBE decifrino lo stesso dump indipendentemente (non solo la prima)
- **decifrare manualmente un dump per conferma reale** (non fidarsi del solo
  exit code):
  ```bash
  age -d -i /etc/irccs-backup-key/irccs-backup-key.txt \
    "$BACKUP_ROOT/hapi/archive/hapi_<data>.dump.age" | pg_restore --list | head
  ```

Se questo passo fallisce, **non procedere** all'installazione del timer:
risolvere prima (vedi log strutturato `level=error` per la causa).

## 7. Installare systemd timer

*(automatizzato da `install.sh` step 7 — riscrive `WorkingDirectory`/`ExecStart` col path reale, fa `enable --now`)*

```bash
sudo cp /opt/irccs-docker/backup/systemd/irccs-backup.service /etc/systemd/system/
sudo cp /opt/irccs-docker/backup/systemd/irccs-backup.timer /etc/systemd/system/
```

Editare `/etc/systemd/system/irccs-backup.service`: aggiornare
`WorkingDirectory` e `ExecStart` con il path reale usato al passo 4 (se
diverso da `/opt/irccs-docker`).

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now irccs-backup.timer
systemctl list-timers irccs-backup.timer   # verifica prossima esecuzione schedulata
```

Test manuale del servizio (non aspettare la notte):

```bash
sudo systemctl start irccs-backup.service
sudo journalctl -u irccs-backup.service -f   # segue i log in tempo reale
```

## 8. Collegare log, alert e dashboard

Log e dashboard sono già pronti (aggiunti a `monitoring-config/`, non
serve scrivere nulla di nuovo — solo attivare):

*(punto 1 e restart Alloy automatizzati da `install.sh` step 8; punti 3 e 4 restano manuali)*

1. **Journal persistente**: `loki.source.journal` legge da
   `/var/log/journal` (via mount `/:/rootfs:ro` già presente su Alloy).
   Se l'host ha solo journal volatile (`/run/log/journal`), i log si perdono
   al riavvio e Alloy non li vede in tempo. Verificare/abilitare:
   ```bash
   grep -q "^Storage=persistent" /etc/systemd/journald.conf || \
     sudo sed -i 's/#Storage=auto/Storage=persistent/' /etc/systemd/journald.conf
   sudo systemctl restart systemd-journald
   ```
2. **Riavviare Alloy** per caricare il nuovo `loki.source.journal` in
   `config.alloy`: `docker compose restart irccs-alloy` (o redeploy stack).
3. **Alert**: aprire `monitoring-config/alerting/rules.yaml` esistente e
   fondere il gruppo `irccs-backup` da `backup/alerting/backup-rules.yaml`.
4. **Dashboard**: `monitoring-config/dashboards/irccs-backup.json` viene
   auto-provisionata al prossimo avvio/reload di Grafana (stesso meccanismo
   delle altre dashboard nella cartella, vedi `dashboard-provisioning/dashboards.yaml`)
   — nessuna azione manuale oltre al restart/redeploy di Grafana se già in
   esecuzione.

Verifica: dopo un run di `backup_nightly.sh` (passo 6), cercare in Grafana →
Explore → Loki: `{component="irccs-backup"}` — devono comparire le righe di
log. Se non compaiono, il problema è quasi sempre il journal non persistente
(punto 1) o Alloy non riavviato (punto 2).

## 8bis. Installare il timer di verifica periodica integrità (opzionale ma raccomandato)

`backup/scripts/verify_archive_integrity.sh` campiona un archivio a rotazione
per DB e ne verifica davvero la leggibilità (decifra + restore reale su
scratch), non solo al momento della creazione ma nel tempo — rileva bitrot
prima del disaster reale.

```bash
sudo cp /opt/irccs-docker/backup/systemd/irccs-backup-verify.{service,timer} /etc/systemd/system/
# stessa modifica WorkingDirectory/ExecStart del passo 7
```

Richiede `BACKUP_VERIFY_KEY_FILE` in `.env.backup` (path alla chiave privata
age): **trade-off esplicito** — per verificare serve poter decifrare, quindi
una copia della chiave privata deve essere disponibile su questo host solo
per questo scopo (diverso dal principio "chiave mai sull'host di backup"
usato per il restore in emergenza). Alternativa più sicura se non si accetta
il trade-off: eseguire lo script manualmente/periodicamente da un host
separato che ha la chiave, invece di schedularlo qui.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now irccs-backup-verify.timer
```

## 9. Test restore reale (obbligatorio prima di considerarsi "coperti")

Eseguire l'intera procedura in `RESTORE_PLAYBOOK.md` su un ambiente scratch
(non su prod!) — VM dedicata o pascale-local con dump prod scaricato e
decifrato. Misurare l'RTO reale e annotarlo nello storico del playbook.

Solo dopo un test restore riuscito, considerare il sistema realmente
operativo — un backup mai restorato è una speranza, non una garanzia.

## 10. Checklist finale go-live

- [ ] `age`/`rclone` installati e funzionanti
- [ ] Almeno 2 chiavi age generate, 2 custodi indipendenti, entrambe le private salvate fuori da questo host
- [ ] `.env.backup` compilato (`BACKUP_AGE_RECIPIENTS` con tutte le chiavi), non committato
- [ ] Retention offsite verificata: se `BACKUP_OFFSITE_METHOD=rsync`, pulizia offsite resta manuale (non automatizzata) — pianificare processo periodico
- [ ] Test manuale `backup_nightly.sh` riuscito con decifrazione verificata
- [ ] File presente su target offsite
- [ ] Timer systemd attivo (`systemctl list-timers`)
- [ ] Journal persistente abilitato, Alloy riavviato, log visibili in Grafana Explore
- [ ] Alert Loki fusi in `rules.yaml`
- [ ] Dashboard "IRCCS Backup DB" visibile in Grafana
- [ ] Test restore reale su ambiente scratch eseguito, RTO annotato in `RESTORE_PLAYBOOK.md` (usare `scripts/restore_db.sh`, non comandi manuali)
- [ ] Timer verifica periodica integrità attivo (`irccs-backup-verify.timer`) o scelta esplicita di eseguirla manualmente da host separato
- [ ] Referente/team informato di dove si trova questa documentazione
