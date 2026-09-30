#!/bin/bash
# Abilita l'estensione pgaudit sullo store audit dedicato (postgres-hapi-audit),
# cosi' anche le LETTURE dirette via SQL (bypassando HAPI/i microservizi) restano
# tracciate - i trigger in audit_db_protection.sql bloccano solo scritture/
# cancellazioni, non tracciano ne' impediscono una SELECT diretta.
#
# Precondizioni: postgres-hapi-audit deve girare con l'immagine buildata da
# postgres-audit-image/ (contiene il pacchetto postgresql-<major>-pgaudit) e
# shared_preload_libraries=pgaudit gia' passato come comando (docker-compose.yaml)
# - la libreria va precaricata all'avvio del processo Postgres, non basta creare
# l'estensione a runtime. Se il container e' partito con l'immagine vecchia,
# ricrearlo (`docker compose up -d --build postgres-hapi-audit`) prima di lanciare
# questo script.
#
# Idempotente. Uso:
#   ./install_audit_pgaudit.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$COMPOSE_DIR"

envval() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2-; }
U="$(envval HAPI_AUDIT_DB_USER)"; D="$(envval HAPI_AUDIT_DB_NAME)"
: "${U:?HAPI_AUDIT_DB_USER non in .env}"; : "${D:?HAPI_AUDIT_DB_NAME non in .env}"

# docker compose v2 (plugin) se disponibile, altrimenti docker-compose v1 (legacy) -
# alcuni host hanno solo uno dei due installato.
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

PRELOADED="$($DC exec -T postgres-hapi-audit psql -U "$U" -d "$D" -tAc "SHOW shared_preload_libraries;")"
case "$PRELOADED" in
  *pgaudit*) ;;
  *)
    echo "ERRORE: shared_preload_libraries='$PRELOADED' non include pgaudit." >&2
    echo "Il container va avviato col comando -c shared_preload_libraries=pgaudit" >&2
    echo "(vedi docker-compose.yaml) - ricrealo con: $DC up -d --build postgres-hapi-audit" >&2
    exit 1
    ;;
esac

echo "Creo/verifico estensione pgaudit su postgres-hapi-audit ($D)..."
$DC exec -T postgres-hapi-audit psql -U "$U" -d "$D" -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS pgaudit;"

echo "pgaudit attiva. Verifica log con: $DC logs postgres-hapi-audit | grep AUDIT"
