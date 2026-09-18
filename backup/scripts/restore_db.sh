#!/usr/bin/env bash
# Drop + create + pg_restore su UNO dei tre DB (hapi|keycloak|hapi-audit),
# protetto da conferma esplicita del hostname corrente prima di eseguire
# l'operazione distruttiva (DROP DATABASE). Pensato per essere invocato dal
# playbook RESTORE_PLAYBOOK.md §4-5 invece di copiare/incollare i comandi
# psql/pg_restore a mano — riduce il rischio di eseguire il drop sull'host
# sbagliato (es. shell SSH aperta su prod invece che sullo scratch di test).
#
# La decifratura age (§3) e la pulizia del plaintext (§6) restano a carico
# dell'operatore: questo script fa solo drop+create+restore, non tocca file
# cifrati ne' li elimina.
#
# Uso:
#   restore_db.sh <hapi|keycloak|hapi-audit> <path/al/dump/plaintext> [--yes-i-am-sure=<hostname>]
#
# Interattivo: chiede di digitare per intero l'hostname corrente per confermare.
# Non interattivo (es. runbook scriptato/test automatizzati): passare
# --yes-i-am-sure=<hostname> con l'hostname REALE della macchina — se non
# corrisponde esattamente, lo script si ferma senza fare nulla.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
STACK_DIR="$(dirname "$BACKUP_DIR")"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

# HAPI_DB_USER/HAPI_DB_NAME/POSTGRES_KEYCLOAK_USER/POSTGRES_KEYCLOAK_DB/
# HAPI_AUDIT_DB_USER vivono nel .env della stack, non in backup/.env.backup:
# il playbook non chiede di sourcarlo a mano, quindi lo estraiamo qui. Stesso
# pattern (mai `source` diretto) di run_backup_container.sh: il .env della
# stack contiene segreti non correlati al backup (JWT_SECRET, ecc.) che
# potrebbero contenere caratteri shell-unsafe — grep+cut tratta il contenuto
# come dato, mai come codice. Non sovrascrive variabili gia' presenti
# nell'ambiente (es. se l'operatore le ha esportate a mano).
if [ -f "$STACK_DIR/.env" ]; then
  STACK_ENV_SANITIZED="$(mktemp)"
  trap 'rm -f "$STACK_ENV_SANITIZED"' EXIT
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$STACK_DIR/.env" > "$STACK_ENV_SANITIZED" || true
  extract_env_var() {
    local var="$1" from_stack
    [ -n "${!var:-}" ] && return 0
    from_stack="$(grep -E "^$var=" "$STACK_ENV_SANITIZED" | tail -1 | cut -d= -f2-)" || true
    [ -n "$from_stack" ] && export "$var=$from_stack"
    return 0
  }
  extract_env_var HAPI_DB_USER
  extract_env_var HAPI_DB_NAME
  extract_env_var POSTGRES_KEYCLOAK_USER
  extract_env_var POSTGRES_KEYCLOAK_DB
  extract_env_var HAPI_AUDIT_DB_USER
  extract_env_var HAPI_AUDIT_DB_NAME
fi

DB_KIND="${1:?uso: restore_db.sh <hapi|keycloak|hapi-audit> <dump> [--yes-i-am-sure=<hostname>]}"
DUMP_FILE="${2:?uso: restore_db.sh <hapi|keycloak|hapi-audit> <dump> [--yes-i-am-sure=<hostname>]}"
CONFIRM_ARG="${3:-}"

[ -f "$DUMP_FILE" ] || die "dump non trovato: $DUMP_FILE"

case "$DB_KIND" in
  hapi)
    CONTAINER="${BACKUP_HAPI_CONTAINER:-postgres-hapi-fhir}"
    require_env HAPI_DB_USER HAPI_DB_NAME
    DB_USER="$HAPI_DB_USER"; DB_NAME="$HAPI_DB_NAME"
    ;;
  keycloak)
    CONTAINER="${BACKUP_KEYCLOAK_CONTAINER:-postgres-keycloak}"
    require_env POSTGRES_KEYCLOAK_USER POSTGRES_KEYCLOAK_DB
    DB_USER="$POSTGRES_KEYCLOAK_USER"; DB_NAME="$POSTGRES_KEYCLOAK_DB"
    ;;
  hapi-audit)
    CONTAINER="${BACKUP_HAPI_AUDIT_CONTAINER:-postgres-hapi-audit}"
    require_env HAPI_AUDIT_DB_USER
    HAPI_AUDIT_DB_NAME="${HAPI_AUDIT_DB_NAME:-hapiaudit}"
    DB_USER="$HAPI_AUDIT_DB_USER"; DB_NAME="$HAPI_AUDIT_DB_NAME"
    ;;
  *)
    die "tipo db sconosciuto: $DB_KIND (atteso hapi|keycloak|hapi-audit)"
    ;;
esac

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  die "container non in esecuzione: $CONTAINER"
fi

CURRENT_HOST="$(hostname)"
DUMP_SIZE="$(du -h "$DUMP_FILE" | cut -f1)"

# Anteprima del contenuto PRIMA di chiedere conferma: un dump corrotto va
# scoperto qui, non dopo un DROP DATABASE gia' eseguito. La riga "; dbname:"
# nell'intestazione di `pg_restore --list` e' anche un controllo di sanita'
# gratuito (conferma per quale DB e' stato creato l'archivio, non solo dove
# lo si sta per restorare) — non sostituisce la conferma hostname, la precede.
DUMP_LIST="$(pg_restore --list "$DUMP_FILE" 2>&1)" || die "dump illeggibile/corrotto, impossibile ispezionarlo (pg_restore --list fallito): $DUMP_FILE"

DUMP_DBNAME="$(printf '%s\n' "$DUMP_LIST" | grep -m1 '^; *dbname:' | sed 's/^; *dbname: *//')"
if [ -n "$DUMP_DBNAME" ] && [ "$DUMP_DBNAME" != "$DB_NAME" ]; then
  log_warn "ANOMALIA: il dump e' stato creato per il database \"$DUMP_DBNAME\", ma si sta per restorarlo su \"$DB_NAME\" — verificare che non sia il dump sbagliato prima di confermare"
fi

echo "=== restore_db.sh: operazione DISTRUTTIVA ===" >&2
echo "hostname corrente : $CURRENT_HOST" >&2
echo "container target  : $CONTAINER" >&2
echo "database target   : $DB_NAME (verra' droppato e ricreato)" >&2
echo "dump da ripristinare: $DUMP_FILE ($DUMP_SIZE)" >&2
echo "--- anteprima dump (pg_restore --list, prime 20 righe) ---" >&2
printf '%s\n' "$DUMP_LIST" | head -20 >&2
echo "===============================================" >&2

CONFIRMED=false
if [[ "$CONFIRM_ARG" == --yes-i-am-sure=* ]]; then
  PROVIDED_HOST="${CONFIRM_ARG#--yes-i-am-sure=}"
  if [ "$PROVIDED_HOST" = "$CURRENT_HOST" ]; then
    CONFIRMED=true
  else
    die "conferma rifiutata: --yes-i-am-sure=\"$PROVIDED_HOST\" non corrisponde all'hostname reale \"$CURRENT_HOST\""
  fi
elif [ -n "$CONFIRM_ARG" ]; then
  die "argomento non riconosciuto: $CONFIRM_ARG (atteso --yes-i-am-sure=<hostname>)"
else
  if [ ! -t 0 ]; then
    die "nessun terminale interattivo e nessun --yes-i-am-sure=<hostname>: conferma impossibile, operazione annullata"
  fi
  read -r -p "Digita l'hostname corrente (\"$CURRENT_HOST\") per confermare il DROP di \"$DB_NAME\": " TYPED_HOST
  if [ "$TYPED_HOST" = "$CURRENT_HOST" ]; then
    CONFIRMED=true
  else
    die "conferma rifiutata: hostname digitato non corrisponde, operazione annullata (nessuna modifica eseguita)"
  fi
fi

[ "$CONFIRMED" = true ] || die "conferma non ottenuta, operazione annullata"

log_info "conferma OK, avvio drop+create+restore: db=$DB_KIND container=$CONTAINER"

if ! docker exec -i "$CONTAINER" psql -U "$DB_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" \
  -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"; then
  die "drop+create fallito: db=$DB_KIND container=$CONTAINER"
fi
log_info "drop+create OK: db=$DB_KIND"

if ! docker exec -i "$CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-privileges < "$DUMP_FILE"; then
  die "pg_restore fallito: db=$DB_KIND container=$CONTAINER dump=$DUMP_FILE"
fi
log_info "restore completato: db=$DB_KIND container=$CONTAINER"
