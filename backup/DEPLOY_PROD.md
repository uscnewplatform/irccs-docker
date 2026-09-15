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

## 0. Prerequisiti host

- Accesso root/sudo sull'host dove gira la stack prod (`irccs-docker`, quello
  con `container_name: postgres-hapi-fhir` / `postgres-keycloak`).
- Docker CLI funzionante, stessa rete dei container della stack.
- Connettività di rete verso: repository `age` (o pacchetto già in apt),
  destinazione offsite scelta (secondo host / NAS / object storage).

## 1. Installare i tool richiesti

```bash
sudo apt update && sudo apt install -y age rclone
# oppure rsync se si sceglie quel metodo di offsite invece di rclone
```

Verificare: `age --version`, `rclone version` (o `rsync --version`).

## 2. Generare la chiave di cifratura

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

Annotare la **chiave pubblica** stampata da `age-keygen` (riga `Public key:
age1...`): serve al passo 4.

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

```bash
cd /opt/irccs-docker/backup
cp .env.backup.example .env.backup
```

Editare `.env.backup`:

| Variabile | Valore |
|---|---|
| `BACKUP_ROOT` | path locale con spazio sufficiente, es. `/var/backups/irccs` |
| `BACKUP_KEEP_DAILY/WEEKLY/MONTHLY` | default 14/8/6 vanno bene, adattare a policy interna se diversa |
| `BACKUP_AGE_RECIPIENT` | la chiave pubblica generata al passo 2 |
| `BACKUP_OFFSITE_METHOD` | `rclone` (o `rsync`) |
| `BACKUP_OFFSITE_TARGET` | remote configurato al passo 3, es. `irccs-offsite:irccs-backup/` |
| `BACKUP_HAPI_CONTAINER` / `BACKUP_KEYCLOAK_CONTAINER` | lasciare commentate — i default (`postgres-hapi-fhir`, `postgres-keycloak`) sono già i nomi container di questo repo prod |

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
- file `.dump.age` presenti in `$BACKUP_ROOT/{hapi,keycloak}/archive/`
- file presente anche sul target offsite (`rclone ls irccs-offsite:irccs-backup/`)
- **decifrare manualmente un dump per conferma reale** (non fidarsi del solo
  exit code):
  ```bash
  age -d -i /etc/irccs-backup-key/irccs-backup-key.txt \
    "$BACKUP_ROOT/hapi/archive/hapi_<data>.dump.age" | pg_restore --list | head
  ```

Se questo passo fallisce, **non procedere** all'installazione del timer:
risolvere prima (vedi log strutturato `level=error` per la causa).

## 7. Installare systemd timer

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

## 9. Test restore reale (obbligatorio prima di considerarsi "coperti")

Eseguire l'intera procedura in `RESTORE_PLAYBOOK.md` su un ambiente scratch
(non su prod!) — VM dedicata o pascale-local con dump prod scaricato e
decifrato. Misurare l'RTO reale e annotarlo nello storico del playbook.

Solo dopo un test restore riuscito, considerare il sistema realmente
operativo — un backup mai restorato è una speranza, non una garanzia.

## 10. Checklist finale go-live

- [ ] `age`/`rclone` installati e funzionanti
- [ ] Chiave privata age salvata fuori da questo host
- [ ] `.env.backup` compilato, non committato
- [ ] Test manuale `backup_nightly.sh` riuscito con decifrazione verificata
- [ ] File presente su target offsite
- [ ] Timer systemd attivo (`systemctl list-timers`)
- [ ] Journal persistente abilitato, Alloy riavviato, log visibili in Grafana Explore
- [ ] Alert Loki fusi in `rules.yaml`
- [ ] Dashboard "IRCCS Backup DB" visibile in Grafana
- [ ] Test restore reale su ambiente scratch eseguito, RTO annotato in `RESTORE_PLAYBOOK.md`
- [ ] Referente/team informato di dove si trova questa documentazione
