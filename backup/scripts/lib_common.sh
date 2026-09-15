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
