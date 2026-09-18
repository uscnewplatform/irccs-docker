#!/usr/bin/env bash
# Installer idempotente per il sistema di backup DB (HAPI FHIR + Keycloak)
# su una macchina nuova. Automatizza i passi 1,2,5,7,8 di ../DEPLOY_PROD.md.
# Passi 3 (config remote offsite), 6 (test manuale+decifrazione), 9 (restore
# reale su scratch) restano volutamente manuali: richiedono credenziali
# interattive o giudizio umano, non vanno automatizzati.
#
# Uso: sudo backup/scripts/install.sh
# Rieseguibile: ogni step controlla lo stato corrente prima di agire.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
STACK_DIR="$(dirname "$BACKUP_DIR")"

# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

[ "$(id -u)" -eq 0 ] || die "eseguire come root (sudo): serve per apt, systemd, /etc"

KEY_DIR="${BACKUP_INSTALL_KEY_DIR:-/etc/irccs-backup-key}"
KEY_FILE="$KEY_DIR/irccs-backup-key.txt"

CHECKLIST_MANUAL=()
CHECKLIST_DONE=()

step_done() { CHECKLIST_DONE+=("$1"); log_info "OK: $1"; }
step_manual() { CHECKLIST_MANUAL+=("$1"); log_warn "MANUALE: $1"; }

# --- 1. tool richiesti ---------------------------------------------------
log_info "--- step 1: age + rclone ---"
if command -v age >/dev/null && command -v rclone >/dev/null; then
  step_done "age/rclone gia' installati"
else
  apt update -y
  apt install -y age rclone
  command -v age >/dev/null && command -v rclone >/dev/null || die "install age/rclone fallita"
  step_done "age/rclone installati"
fi

# --- 2. chiave age --------------------------------------------------------
log_info "--- step 2: chiave cifratura age ---"
if [ -f "$KEY_FILE" ]; then
  step_done "chiave age gia' presente: $KEY_FILE"
else
  mkdir -p "$KEY_DIR"
  chmod 700 "$KEY_DIR"
  age-keygen -o "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  step_done "chiave age generata: $KEY_FILE"
fi
PUBKEY="$(grep '^# public key:' "$KEY_FILE" | awk '{print $NF}')"
step_manual "copiare $KEY_FILE FUORI da questo host (vault/secondo host), poi rimuoverla qui se non serve in locale"
step_manual "impostare BACKUP_AGE_RECIPIENT=$PUBKEY in $BACKUP_DIR/.env.backup"

# --- 3. offsite target (non automatizzabile: credenziali interattive) ---
log_info "--- step 3: target offsite ---"
step_manual "configurare remote offsite con 'rclone config' (o rsync), poi impostare BACKUP_OFFSITE_METHOD/BACKUP_OFFSITE_TARGET in .env.backup"

# --- 5. .env.backup + permessi script ------------------------------------
log_info "--- step 5: .env.backup + permessi ---"
if [ -f "$BACKUP_DIR/.env.backup" ]; then
  step_done ".env.backup gia' presente (non sovrascritto)"
else
  cp "$BACKUP_DIR/.env.backup.example" "$BACKUP_DIR/.env.backup"
  step_done ".env.backup creato da .env.backup.example"
  step_manual "compilare $BACKUP_DIR/.env.backup (BACKUP_ROOT, retention, recipient age, offsite)"
fi
chmod +x "$SCRIPT_DIR"/*.sh
step_done "permessi esecuzione su scripts/*.sh"

if ! grep -qxF '.env.backup' "$STACK_DIR/.gitignore" 2>/dev/null; then
  echo '.env.backup' >> "$STACK_DIR/.gitignore"
  step_done "backup/.env.backup aggiunto a .gitignore"
else
  step_done ".env.backup gia' in .gitignore"
fi

# --- 6. test manuale (non automatizzabile: serve verifica umana) --------
step_manual "eseguire 'cd $SCRIPT_DIR && ./backup_nightly.sh' e verificare a mano decifrazione di un dump (vedi DEPLOY_PROD.md #6)"

# --- 7. systemd timer ------------------------------------------------------
log_info "--- step 7: systemd timer ---"
SVC_SRC="$BACKUP_DIR/systemd/irccs-backup.service"
TIMER_SRC="$BACKUP_DIR/systemd/irccs-backup.timer"
SVC_DST="/etc/systemd/system/irccs-backup.service"
TIMER_DST="/etc/systemd/system/irccs-backup.timer"

sed -e "s#^WorkingDirectory=.*#WorkingDirectory=$STACK_DIR#" \
    -e "s#^ExecStart=.*#ExecStart=$SCRIPT_DIR/run_backup_container.sh#" \
    "$SVC_SRC" > "$SVC_DST"
cp "$TIMER_SRC" "$TIMER_DST"
systemctl daemon-reload
systemctl enable --now irccs-backup.timer
step_done "irccs-backup.timer installato e abilitato (WorkingDirectory=$STACK_DIR)"

# --- 8. journal persistente + alloy ---------------------------------------
log_info "--- step 8a: journal persistente ---"
JOURNALD_CONF=/etc/systemd/journald.conf
if grep -q '^Storage=persistent' "$JOURNALD_CONF" 2>/dev/null; then
  step_done "journal gia' persistente"
else
  if grep -q '^#Storage=auto' "$JOURNALD_CONF" 2>/dev/null; then
    sed -i 's/^#Storage=auto/Storage=persistent/' "$JOURNALD_CONF"
  else
    echo 'Storage=persistent' >> "$JOURNALD_CONF"
  fi
  systemctl restart systemd-journald
  step_done "journal impostato a persistent + journald riavviato"
fi

log_info "--- step 8b: alert + dashboard ---"
step_manual "fondere $BACKUP_DIR/alerting/backup-rules.yaml nel rules.yaml prod (monitoring-config/alerting/rules.yaml)"
if docker ps --format '{{.Names}}' | grep -q '^irccs-alloy$'; then
  docker restart irccs-alloy >/dev/null
  step_done "container irccs-alloy riavviato (rilegge config.alloy/journal persistente)"
else
  step_manual "container irccs-alloy non in esecuzione qui: riavviarlo manualmente dopo il deploy della stack monitoring"
fi
step_manual "verificare dashboard 'IRCCS Backup DB' in Grafana dopo il prossimo reload"

# --- 9. restore reale (non automatizzabile: richiede ambiente scratch) --
step_manual "eseguire RESTORE_PLAYBOOK.md su ambiente scratch, annotare RTO — obbligatorio prima di considerarsi coperti"

# --- riepilogo -------------------------------------------------------------
echo
log_info "=== installazione automatica completata ==="
log_info "automatizzato: ${#CHECKLIST_DONE[@]} step"
log_warn "resta manuale: ${#CHECKLIST_MANUAL[@]} step"
printf ' - %s\n' "${CHECKLIST_MANUAL[@]}"
