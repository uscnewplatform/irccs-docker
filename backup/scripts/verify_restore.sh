#!/usr/bin/env bash
# Verifica un dump pg_dump -Fc ripristinandolo su un container postgres scratch
# isolato (rete dedicata, nessun accesso ai container prod), poi esegue una
# sanity query. Il container scratch viene sempre distrutto a fine run.
#
# Uso: verify_restore.sh <hapi|keycloak> <path/al/dump>
# Exit 0 = restore OK e sanity query passata. Exit != 0 = FAIL (non procedere a
# cifratura/retention/offsite di quel dump: va conservato per analisi manuale).

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

DB_KIND="${1:?uso: verify_restore.sh <hapi|keycloak> <dump>}"
DUMP_FILE="${2:?uso: verify_restore.sh <hapi|keycloak> <dump>}"

[ -f "$DUMP_FILE" ] || die "dump non trovato: $DUMP_FILE"

case "$DB_KIND" in
  hapi)
    IMAGE="${BACKUP_VERIFY_IMAGE_HAPI:-postgres:16.8}"
    SANITY_QUERY="SELECT count(*) FROM hfj_resource;"
    ;;
  keycloak)
    IMAGE="${BACKUP_VERIFY_IMAGE_KEYCLOAK:-postgres:17.4}"
    SANITY_QUERY="SELECT count(*) FROM realm;"
    ;;
  *)
    die "tipo db sconosciuto: $DB_KIND (atteso hapi|keycloak)"
    ;;
esac

SCRATCH_NAME="irccs-backup-verify-${DB_KIND}-$$"
SCRATCH_NET="irccs-backup-verify-net-$$"
SCRATCH_USER="verify"
SCRATCH_DB="verify"
SCRATCH_PW="verify-$$-$(date +%s)"

cleanup() {
  docker rm -f "$SCRATCH_NAME" >/dev/null 2>&1 || true
  docker network rm "$SCRATCH_NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log_info "verify avviato: db=$DB_KIND dump=$DUMP_FILE"

docker network create "$SCRATCH_NET" >/dev/null

docker run -d --name "$SCRATCH_NAME" --network "$SCRATCH_NET" \
  -e POSTGRES_USER="$SCRATCH_USER" \
  -e POSTGRES_PASSWORD="$SCRATCH_PW" \
  -e POSTGRES_DB="$SCRATCH_DB" \
  "$IMAGE" >/dev/null

log_info "attesa readiness container scratch $SCRATCH_NAME"
# L'immagine postgres ufficiale fa un doppio avvio (init poi restart interno):
# pg_isready puo' risultare pronto nella finestra breve prima del restart.
# Richiediamo due controlli consecutivi positivi, distanziati, prima di considerarlo stabile.
is_ready() { docker exec "$SCRATCH_NAME" pg_isready -U "$SCRATCH_USER" -d "$SCRATCH_DB" >/dev/null 2>&1; }

READY=false
for _ in $(seq 1 30); do
  if is_ready; then
    sleep 2
    if is_ready; then
      READY=true
      break
    fi
  fi
  sleep 2
done
[ "$READY" = true ] || die "container scratch non pronto entro il timeout: $SCRATCH_NAME"

RESTORE_OK=false
for attempt in 1 2 3; do
  if [ "$attempt" -gt 1 ]; then
    # Retry: DB scratch ripulito per evitare conflitti "already exists" da un restore parziale precedente.
    docker exec "$SCRATCH_NAME" psql -U "$SCRATCH_USER" -d postgres \
      -c "DROP DATABASE IF EXISTS \"$SCRATCH_DB\";" -c "CREATE DATABASE \"$SCRATCH_DB\" OWNER \"$SCRATCH_USER\";" >/dev/null
  fi
  if docker exec -i "$SCRATCH_NAME" pg_restore -U "$SCRATCH_USER" -d "$SCRATCH_DB" --no-owner --no-privileges < "$DUMP_FILE"; then
    RESTORE_OK=true
    break
  fi
  log_warn "pg_restore tentativo $attempt fallito, retry: $DUMP_FILE"
  sleep 3
done
[ "$RESTORE_OK" = true ] || die "pg_restore fallito su dump dopo 3 tentativi: $DUMP_FILE"

RESULT="$(docker exec "$SCRATCH_NAME" psql -U "$SCRATCH_USER" -d "$SCRATCH_DB" -tAc "$SANITY_QUERY" 2>&1)" \
  || die "sanity query fallita su dump: $DUMP_FILE ($RESULT)"

if ! [[ "$RESULT" =~ ^[0-9]+$ ]]; then
  die "sanity query esito inatteso: $RESULT"
fi

log_info "verify OK: db=$DB_KIND dump=$DUMP_FILE sanity_count=$RESULT"
