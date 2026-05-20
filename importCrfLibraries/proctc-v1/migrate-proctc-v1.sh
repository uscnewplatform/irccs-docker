#!/usr/bin/env bash
# Migrazione PRO-CTCAE v1 su HAPI FHIR
# Elimina vecchie risorse con ID "adverse-events" e reimporta con ID corretti.
# Uso: bash migrate-proctc-v1.sh [HAPI_URL]
# Default: http://localhost:8080/fhir

set -euo pipefail
HAPI="${1:-http://localhost:8080/fhir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "─────────────────────────────────────────────────────"
echo "  PRO-CTCAE v1 — Migrazione nomenclatura"
echo "  URL: $HAPI"
echo "─────────────────────────────────────────────────────"

delete_if_exists() {
  local RESOURCE_TYPE="$1"
  local RESOURCE_ID="$2"
  local HTTP_CODE
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X DELETE "$HAPI/$RESOURCE_TYPE/$RESOURCE_ID")
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    echo "  ✓ Eliminato $RESOURCE_TYPE/$RESOURCE_ID"
  elif [[ "$HTTP_CODE" == "404" ]]; then
    echo "  — $RESOURCE_TYPE/$RESOURCE_ID non presente (skip)"
  else
    echo "  ✗ Errore DELETE $RESOURCE_TYPE/$RESOURCE_ID → HTTP $HTTP_CODE"
    exit 1
  fi
}

echo ""
echo "  [1/2] Eliminazione risorse obsolete..."
delete_if_exists "ValueSet" "proctc-v1-adverse-events"

echo ""
echo "  [2/2] Reimportazione bundle aggiornato..."
bash "$SCRIPT_DIR/install-proctc-v1.sh" "$HAPI"

echo "─────────────────────────────────────────────────────"
echo "  Migrazione completata."
echo "─────────────────────────────────────────────────────"
