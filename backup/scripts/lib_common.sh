#!/usr/bin/env bash
# Funzioni condivise: logging strutturato per parsing Loki (level=info|warn|error).
# Sourced dagli altri script di backup/, non eseguibile da solo.

log_info()  { echo "$(date -Is) level=info  component=irccs-backup msg=\"$*\"" >&2; }
log_warn()  { echo "$(date -Is) level=warn  component=irccs-backup msg=\"$*\"" >&2; }
log_error() { echo "$(date -Is) level=error component=irccs-backup msg=\"$*\"" >&2; }

# Interrompe lo script con messaggio d'errore strutturato (per alert Loki su level=error).
die() {
  log_error "$*"
  exit 1
}

require_env() {
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      die "variabile ambiente mancante: $var (verificare backup/.env.backup)"
    fi
  done
}

# Preflight: interrompe subito (prima di qualunque pg_dump) se lo spazio
# libero sul filesystem di $1 e' sotto la soglia $2 (MB). Evita che un dump
# di centinaia di MB fallisca a meta' per disco pieno con un errore oscuro.
#
# Warning anticipato: BACKUP_MIN_FREE_MB e' una soglia fissa dimensionata
# sui volumi attuali — non si adatta da sola alla crescita dei dati nel
# tempo. Sotto BACKUP_WARN_FREE_MB (default 2x la soglia minima) emette un
# log_warn (non blocca) per dare a un operatore un margine di preavviso
# prima che lo spazio diventi davvero critico, invece di scoprirlo la notte
# in cui il backup si ferma.
check_disk_space() {
  local path="$1" min_free_mb="$2"
  local warn_free_mb="${BACKUP_WARN_FREE_MB:-$((min_free_mb * 2))}"
  mkdir -p "$path"
  local free_mb
  free_mb="$(df -Pm "$path" | awk 'NR==2 {print $4}')"
  if [ -z "$free_mb" ]; then
    die "impossibile determinare lo spazio libero su $path"
  fi
  if [ "$free_mb" -lt "$min_free_mb" ]; then
    die "spazio disco insufficiente su $path: ${free_mb}MB liberi, richiesti almeno ${min_free_mb}MB (BACKUP_MIN_FREE_MB)"
  fi
  if [ "$free_mb" -lt "$warn_free_mb" ]; then
    log_warn "spazio disco in avvicinamento alla soglia su $path: ${free_mb}MB liberi (soglia minima ${min_free_mb}MB, warning sotto ${warn_free_mb}MB) — valutare se alzare BACKUP_MIN_FREE_MB/liberare spazio prima che diventi critico"
  fi
  log_info "spazio disco OK su $path: ${free_mb}MB liberi (soglia ${min_free_mb}MB)"
}
