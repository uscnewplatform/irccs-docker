#!/usr/bin/env bash
# Push PRO-CTCAE v1 bundle su HAPI FHIR
# Uso: bash install-proctc-v1.sh [HAPI_URL]
# Default: http://localhost:8080/fhir

set -euo pipefail
HAPI="${1:-http://localhost:8080/fhir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/proctc-v1-bundle.json"

echo "─────────────────────────────────────────────────────"
echo "  PRO-CTCAE v1 → HAPI FHIR"
echo "  URL: $HAPI"
echo "─────────────────────────────────────────────────────"

HTTP_CODE=$(curl -s -o /tmp/proctc_response.json -w "%{http_code}" \
  -X POST "$HAPI" \
  -H "Content-Type: application/fhir+json" \
  --data-binary "@$BUNDLE")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  echo "  ✓ Caricamento completato (HTTP $HTTP_CODE)"
  echo ""
  echo "  Risorse caricate:"
  echo "    CodeSystem         → $HAPI/CodeSystem/proctc-v1"
  echo "    ValueSet           → $HAPI/ValueSet/proctc-v1-adverse-events"
  echo "    StructureDefinition→ $HAPI/StructureDefinition/proctc-v1-grade-severity"
else
  echo "  ✗ Errore HTTP $HTTP_CODE"
  cat /tmp/proctc_response.json
  exit 1
fi
echo "─────────────────────────────────────────────────────"
