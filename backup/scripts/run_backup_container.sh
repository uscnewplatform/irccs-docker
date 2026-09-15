#!/usr/bin/env bash
# Wrapper lanciato da systemd (irccs-backup.service): costruisce ed esegue il
# container di backup (vedi ../Dockerfile). Unico script che gira sull'host
# come processo diretto — tutto il resto (dump/verify/encrypt/retention) gira
# dentro il container, i cui log su stdout/stderr sono catturati automaticamente
# da loki.source.docker (Alloy), nessuna configurazione aggiuntiva necessaria.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
# STACK_DIR: normalmente il repo padre (prod). Override con BACKUP_STACK_DIR
# per puntare a un altro .env (es. test su pascale-local).
STACK_DIR="${BACKUP_STACK_DIR:-$(dirname "$BACKUP_DIR")}"
IMAGE="${BACKUP_IMAGE:-irccs-backup:latest}"

[ -f "$STACK_DIR/.env" ] || { echo ".env stack non trovato: $STACK_DIR/.env" >&2; exit 1; }
[ -f "$BACKUP_DIR/.env.backup" ] || { echo "backup/.env.backup non trovato (copiare da .env.backup.example)" >&2; exit 1; }

# BACKUP_ROOT serve qui per il bind mount host<->container (stesso path dentro
# e fuori, cosi' gli script interni non devono sapere se girano in container).
# .env.backup e' un file pulito, semplice KEY=VALUE: sourcing diretto sicuro
# (a differenza del .env della stack, che passa solo via --env-file sotto,
# mai sourced in bash).
set -a
# shellcheck source=/dev/null
source "$BACKUP_DIR/.env.backup"
set +a

[ -n "${BACKUP_ROOT:-}" ] || { echo "BACKUP_ROOT non definito in .env.backup" >&2; exit 1; }
mkdir -p "$BACKUP_ROOT"

# `docker run --env-file` e' rigido (niente spazi attorno a "=", niente righe
# malformate): il .env della stack ne contiene alcune (variabili frontend Vite
# non rilevanti qui). Si filtra su un file temporaneo con solo righe KEY=VALUE
# valide — sufficiente, le uniche variabili che servono davvero al backup
# (POSTGRES_KEYCLOAK_*, HAPI_DB_*) sono gia' in quel formato.
STACK_ENV_SANITIZED="$(mktemp)"
trap 'rm -f "$STACK_ENV_SANITIZED"' EXIT
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$STACK_DIR/.env" > "$STACK_ENV_SANITIZED" || true

# Log: il container e' one-shot (avvia, fa il backup, esce) — discovery.docker
# di Alloy scopre SOLO container in esecuzione (come `docker ps` senza -a):
# un job che finisce sparisce dalla discovery prima ancora di essere visto,
# a prescindere da --rm. Si scrive quindi una copia dell'output anche su file
# semplice (BACKUP_LOG_FILE), letto da Alloy via loki.source.file (tailing di
# file, nessuna dipendenza da discovery/timing). set -o pipefail (ereditato da
# "set -euo pipefail" sopra) preserva l'exit code del container attraverso tee.
LOG_FILE="${BACKUP_LOG_FILE:-/var/log/irccs-backup/backup.log}"
mkdir -p "$(dirname "$LOG_FILE")"

docker run --rm --name irccs-backup-run \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$BACKUP_ROOT:$BACKUP_ROOT" \
  --env-file "$STACK_ENV_SANITIZED" \
  --env-file "$BACKUP_DIR/.env.backup" \
  "$IMAGE" 2>&1 | tee -a "$LOG_FILE"
