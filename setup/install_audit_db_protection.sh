#!/bin/bash
# Applica i trigger Postgres che rendono gli AuditEvent immodificabili anche per
# chi ha accesso SQL diretto (audit_db_protection.sql).
#
# Va eseguito UNA VOLTA dopo che HAPI ha creato lo schema (hfj_resource,
# hfj_res_ver devono esistere), e rieseguito se il volume Postgres viene ricreato.
# Idempotente.
#
# Uso:
#   ./install_audit_db_protection.sh                 # store audit dedicato (postgres-hapi-audit)
#   ./install_audit_db_protection.sh clinical        # store clinico (postgres-hapi-fhir)
#   ./install_audit_db_protection.sh "postgresql://user:pass@host:5432/db"   # via DSN
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_FILE="$SCRIPT_DIR/audit_db_protection.sql"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[ -f "$SQL_FILE" ] || { echo "ERRORE: $SQL_FILE non trovato" >&2; exit 1; }

TARGET="${1:-audit}"

# docker compose v2 (plugin) se disponibile, altrimenti docker-compose v1 (legacy) -
# alcuni host hanno solo uno dei due installato.
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

envval() { for k in "$@"; do v="$(grep -E "^${k}=" .env 2>/dev/null | head -1 | cut -d= -f2-)"; [ -n "$v" ] && { echo "$v"; return; }; done; }

case "$TARGET" in
  postgresql://*|postgres://*)
    echo "Applico $SQL_FILE via DSN..."
    psql "$TARGET" -v ON_ERROR_STOP=1 -f "$SQL_FILE"
    ;;
  audit)
    cd "$COMPOSE_DIR"
    U="$(envval HAPI_AUDIT_DB_USER)"; D="$(envval HAPI_AUDIT_DB_NAME)"
    : "${U:?HAPI_AUDIT_DB_USER non in .env}"; : "${D:?HAPI_AUDIT_DB_NAME non in .env}"
    echo "Applico $SQL_FILE su postgres-hapi-audit ($D)..."
    $DC exec -T postgres-hapi-audit psql -U "$U" -d "$D" -v ON_ERROR_STOP=1 < "$SQL_FILE"
    ;;
  clinical)
    cd "$COMPOSE_DIR"
    U="$(envval HAPI_DB_USER POSTGRES_HAPI_USER POSTGRES_USER)"
    D="$(envval HAPI_DB_NAME POSTGRES_HAPI_DB POSTGRES_DB)"
    : "${U:?utente DB HAPI non in .env}"; : "${D:?nome DB HAPI non in .env}"
    echo "Applico $SQL_FILE su postgres-hapi-fhir ($D)..."
    $DC exec -T postgres-hapi-fhir psql -U "$U" -d "$D" -v ON_ERROR_STOP=1 < "$SQL_FILE"
    ;;
  *)
    echo "Target sconosciuto: $TARGET (usa: audit | clinical | <DSN>)" >&2; exit 1
    ;;
esac

echo "Protezione DB audit applicata su: $TARGET"
