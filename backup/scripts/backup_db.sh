#!/usr/bin/env bash
# Dump logico (pg_dump -Fc) di postgres-hapi-fhir e postgres-keycloak.
# Gira "a caldo" contro i container in produzione: pg_dump usa uno snapshot
# MVCC consistente, non serve fermare Keycloak/HAPI.
#
# Uso: backup_db.sh
# Richiede: docker CLI con accesso ai container, .env stack + backup/.env.backup sourced dal caller.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

require_env BACKUP_ROOT POSTGRES_KEYCLOAK_USER POSTGRES_KEYCLOAK_DB HAPI_DB_USER HAPI_DB_NAME

STAMP="$(date +%F)"
STAGING_DIR="$BACKUP_ROOT/staging"
mkdir -p "$STAGING_DIR/hapi" "$STAGING_DIR/keycloak"

dump_one() {
  local container="$1" db_user="$2" db_name="$3" out_file="$4"
  log_info "dump avviato: container=$container db=$db_name -> $out_file"

  if ! docker ps --format '{{.Names}}' | grep -qx "$container"; then
    die "container non in esecuzione: $container"
  fi

  if ! docker exec "$container" pg_dump -Fc -U "$db_user" "$db_name" > "$out_file.tmp"; then
    rm -f "$out_file.tmp"
    die "pg_dump fallito: container=$container db=$db_name"
  fi

  mv "$out_file.tmp" "$out_file"
  log_info "dump completato: $out_file ($(du -h "$out_file" | cut -f1))"
}

HAPI_OUT="$STAGING_DIR/hapi/hapi_${STAMP}.dump"
KEYCLOAK_OUT="$STAGING_DIR/keycloak/keycloak_${STAMP}.dump"

# Nomi container: default prod, override via .env.backup per pascale-local
# (dove sono prefissati, es. pascale-local-postgres-hapi).
HAPI_CONTAINER="${BACKUP_HAPI_CONTAINER:-postgres-hapi-fhir}"
KEYCLOAK_CONTAINER="${BACKUP_KEYCLOAK_CONTAINER:-postgres-keycloak}"

dump_one "$HAPI_CONTAINER" "$HAPI_DB_USER" "$HAPI_DB_NAME" "$HAPI_OUT"
dump_one "$KEYCLOAK_CONTAINER" "$POSTGRES_KEYCLOAK_USER" "$POSTGRES_KEYCLOAK_DB" "$KEYCLOAK_OUT"

echo "$HAPI_OUT"
echo "$KEYCLOAK_OUT"
