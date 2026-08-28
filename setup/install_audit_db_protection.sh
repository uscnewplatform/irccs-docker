#!/bin/bash
# Applica i trigger Postgres che rendono gli AuditEvent immodificabili anche per
# chi ha accesso SQL diretto al database di HAPI FHIR (audit_db_protection.sql).
#
# Va eseguito UNA VOLTA dopo che HAPI ha creato lo schema (hfj_resource, hfj_res_ver
# devono esistere), e rieseguito se il volume postgres_data_hapi viene ricreato.
# Idempotente.
#
# Uso:
#   ./install_audit_db_protection.sh                # via docker compose exec (default)
#   ./install_audit_db_protection.sh "postgresql://user:pass@host:5432/db"   # via DSN
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/audit_db_protection.sql"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$SQL_FILE" ]; then
  echo "ERRORE: $SQL_FILE non trovato" >&2
  exit 1
fi

DSN="${1:-}"

if [ -n "$DSN" ]; then
  echo "Applico $SQL_FILE via DSN..."
  psql "$DSN" -v ON_ERROR_STOP=1 -f "$SQL_FILE"
else
  echo "Applico $SQL_FILE via 'docker compose exec postgres-hapi-fhir'..."
  cd "$COMPOSE_DIR"
  envval() { for k in "$@"; do v="$(grep -E "^${k}=" .env 2>/dev/null | head -1 | cut -d= -f2-)"; [ -n "$v" ] && { echo "$v"; return; }; done; }
  DB_USER="$(envval HAPI_DB_USER POSTGRES_HAPI_USER POSTGRES_USER)"
  DB_NAME="$(envval HAPI_DB_NAME POSTGRES_HAPI_DB POSTGRES_DB)"
  : "${DB_USER:?utente DB HAPI non trovato in .env (HAPI_DB_USER / POSTGRES_HAPI_USER)}"
  : "${DB_NAME:?nome DB HAPI non trovato in .env (HAPI_DB_NAME / POSTGRES_HAPI_DB)}"
  docker compose exec -T postgres-hapi-fhir \
    psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$SQL_FILE"
fi

echo "Protezione DB audit applicata."
