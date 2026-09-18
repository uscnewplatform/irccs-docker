#!/usr/bin/env bash
# Controllo dipendenze host condiviso tra install.sh e restore_orchestrated.sh
# (e riusabile da backup_nightly.sh in futuro). Non fa nulla di distruttivo:
# solo verifica cosa manca sulla macchina e stampa cosa installare, con lo
# stesso stile log_info/log_warn di lib_common.sh (sourced dal caller PRIMA
# di questo file).
#
# Uso: source lib_preflight.sh, poi chiamare preflight_backup() o
# preflight_restore() a seconda del contesto. Ogni funzione ritorna 0 se
# tutto ok, 1 se manca qualcosa di bloccante (i warning non bloccanti non
# influenzano il return code).

PREFLIGHT_MISSING=0

_pf_check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    log_info "preflight: OK, $cmd presente"
  else
    log_error "preflight: MANCANTE $cmd — installare con: $hint"
    PREFLIGHT_MISSING=1
  fi
}

# pg_restore/pg_dump: il wrapper Debian (postgresql-client-common) sceglie la
# versione piu' recente installata. Serve almeno la major del DB piu' recente
# tra quelli in gioco (tipicamente Keycloak, spesso piu' avanti di HAPI) -
# un client piu' vecchio non sa leggere un dump.custom prodotto da un
# pg_dump piu' nuovo ("unsupported version (1.16) in file header", visto in
# pratica su preprod 2026-09-18 con client 14/16 e Keycloak su Postgres 17).
_pf_check_pg_client() {
  local stack_env="$1"
  local hapi_major keycloak_major required_major installed_major

  hapi_major="$(grep -E '^POSTGRES_HAPI_VERSION=' "$stack_env" 2>/dev/null | cut -d= -f2- | cut -d. -f1)"
  keycloak_major="$(grep -E '^POSTGRES_KEYCLOAK_VERSION=' "$stack_env" 2>/dev/null | cut -d= -f2- | cut -d. -f1)"
  required_major="${hapi_major:-0}"
  [ "${keycloak_major:-0}" -gt "$required_major" ] 2>/dev/null && required_major="$keycloak_major"

  if ! command -v pg_restore >/dev/null 2>&1; then
    log_error "preflight: MANCANTE pg_restore — installare con: sudo apt install postgresql-client (poi verificare la major, vedi sotto)"
    PREFLIGHT_MISSING=1
    return
  fi

  installed_major="$(pg_restore --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  if [ -z "$installed_major" ]; then
    log_warn "preflight: impossibile determinare la major di pg_restore installato, verificare manualmente"
    return
  fi
  if [ -n "$required_major" ] && [ "$required_major" -gt 0 ] && [ "$installed_major" -lt "$required_major" ]; then
    log_error "preflight: pg_restore installato e' major $installed_major, ma serve almeno $required_major (Keycloak/HAPI nel .env stack) — installare da PGDG:"
    log_error "  sudo apt install -y postgresql-common && sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y && sudo apt update && sudo apt install -y postgresql-client-$required_major"
    PREFLIGHT_MISSING=1
  else
    log_info "preflight: OK, pg_restore major $installed_major (richiesta almeno $required_major)"
  fi
}

_pf_check_file() {
  local path="$1" desc="$2"
  if [ -e "$path" ]; then
    log_info "preflight: OK, $desc presente ($path)"
  else
    log_error "preflight: MANCANTE $desc ($path)"
    PREFLIGHT_MISSING=1
  fi
}

_pf_check_disk() {
  local path="$1" min_mb="${2:-2048}"
  mkdir -p "$path" 2>/dev/null || true
  local free_mb
  free_mb="$(df -Pm "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -z "$free_mb" ]; then
    log_warn "preflight: impossibile determinare lo spazio libero su $path"
    return
  fi
  if [ "$free_mb" -lt "$min_mb" ]; then
    log_error "preflight: spazio disco insufficiente su $path: ${free_mb}MB liberi, richiesti almeno ${min_mb}MB"
    PREFLIGHT_MISSING=1
  else
    log_info "preflight: OK, spazio disco su $path (${free_mb}MB liberi)"
  fi
}

_pf_check_compose() {
  if docker compose version >/dev/null 2>&1; then
    log_info "preflight: OK, docker compose (v2) disponibile"
    PF_COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    log_info "preflight: OK, docker-compose (v1 legacy) disponibile"
    PF_COMPOSE_CMD="docker-compose"
  else
    log_error "preflight: MANCANTE docker compose/docker-compose — installare docker-compose-plugin o il pacchetto docker-compose"
    PREFLIGHT_MISSING=1
    PF_COMPOSE_CMD=""
  fi
}

# Dipendenze del backup notturno (dump/verify/encrypt/offsite).
preflight_backup() {
  local stack_dir="$1" backup_dir="$2"
  PREFLIGHT_MISSING=0
  log_info "=== preflight: dipendenze backup notturno ==="
  _pf_check_cmd docker "vedi docs.docker.com/engine/install"
  _pf_check_cmd age "sudo apt install age"
  _pf_check_cmd rclone "sudo apt install rclone (solo se BACKUP_OFFSITE_METHOD=rclone)"
  _pf_check_file "$stack_dir/.env" "file .env della stack"
  _pf_check_file "$backup_dir/.env.backup" "backup/.env.backup (copiare da .env.backup.example)"
  [ -f "$backup_dir/.env.backup" ] && grep -qE '^BACKUP_AGE_RECIPIENTS=age1|^BACKUP_AGE_RECIPIENT=age1' "$backup_dir/.env.backup" \
    || { log_error "preflight: BACKUP_AGE_RECIPIENTS non impostata in .env.backup (nessuna chiave age1... trovata)"; PREFLIGHT_MISSING=1; }
  _pf_check_disk "${BACKUP_ROOT:-/opt/irccs-backup}" 2048
  [ "$PREFLIGHT_MISSING" -eq 0 ] && log_info "=== preflight backup: tutto OK ===" || log_error "=== preflight backup: mancano dipendenze, vedere sopra ==="
  return "$PREFLIGHT_MISSING"
}

# Dipendenze del restore (decrypt + pg_restore + riavvio stack).
preflight_restore() {
  local stack_dir="$1"
  PREFLIGHT_MISSING=0
  log_info "=== preflight: dipendenze restore ==="
  _pf_check_cmd docker "vedi docs.docker.com/engine/install"
  _pf_check_cmd age "sudo apt install age"
  _pf_check_cmd shred "sudo apt install coreutils (di norma gia' presente)"
  _pf_check_pg_client "$stack_dir/.env"
  _pf_check_compose
  _pf_check_file "$stack_dir/.env" "file .env della stack"
  [ "$PREFLIGHT_MISSING" -eq 0 ] && log_info "=== preflight restore: tutto OK ===" || log_error "=== preflight restore: mancano dipendenze, vedere sopra — risolvere prima di continuare ==="
  return "$PREFLIGHT_MISSING"
}
