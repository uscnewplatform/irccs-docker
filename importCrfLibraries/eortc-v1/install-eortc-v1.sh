#!/usr/bin/env bash
# Push EORTC QLQ-C30 v1 bundle su HAPI FHIR
# Uso: bash install-eortc-v1.sh [HAPI_URL]
# Default: http://localhost:8080/fhir

set -euo pipefail
HAPI="${1:-http://localhost:8080/fhir}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/eortc-v1-bundle.json"

echo "─────────────────────────────────────────────────────"
echo "  EORTC QLQ-C30 v1 → HAPI FHIR"
echo "  URL: $HAPI"
echo "─────────────────────────────────────────────────────"

HTTP_CODE=$(curl -s -o /tmp/eortc_response.json -w "%{http_code}" \
  -X POST "$HAPI" \
  -H "Content-Type: application/fhir+json" \
  --data-binary "@$BUNDLE")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
  echo "  ✓ Caricamento completato (HTTP $HTTP_CODE)"
  echo ""
  echo "  Risorse caricate:"
  echo "    CodeSystem         → $HAPI/CodeSystem/eortc-v1"
  echo "    ValueSet           → $HAPI/ValueSet/eortc-v1-items"
  echo "    StructureDefinition→ $HAPI/StructureDefinition/eortc-v1-grade-severity"
else
  echo "  ✗ Errore HTTP $HTTP_CODE"
  cat /tmp/eortc_response.json
  exit 1
fi
echo "─────────────────────────────────────────────────────"
