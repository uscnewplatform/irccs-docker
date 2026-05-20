#!/bin/bash
# Carica CodeSystem + ValueSet + StructureDefinition CTCAE v5.0 su HAPI FHIR
# usando il bundle JSON pre-generato (ctcae-v5-bundle.json).
#
# Uso:
#   bash install-ctcae-v5.sh [HAPI_FHIR_URL]
#
# Esempio:
#   bash install-ctcae-v5.sh http://localhost:8080/fhir
#   bash install-ctcae-v5.sh https://hapi.irccs.infocube.it/fhir
#
# Alternativa Python (genera bundle aggiornato + push):
#   python3 import-ctcae-v5.py "CTCAE_v5.0_2017-11-27.xlsx"

set -e

HAPI_URL="${1:-http://localhost:8080/fhir}"
HAPI_URL="${HAPI_URL%/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_FILE="$SCRIPT_DIR/ctcae-v5-bundle.json"

if [ ! -f "$BUNDLE_FILE" ]; then
  echo "ERRORE: $BUNDLE_FILE non trovato."
  echo "Genera il bundle prima:"
  echo "  python3 import-ctcae-v5.py <percorso_excel> --bundle-only"
  exit 1
fi

echo "─────────────────────────────────────────────────"
echo "  CTCAE v5.0 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "  Bundle: $(du -h "$BUNDLE_FILE" | cut -f1)"
echo "─────────────────────────────────────────────────"
echo ""
echo "Caricamento in corso (CodeSystem + ValueSet + StructureDefinition)..."
echo ""

HTTP_STATUS=$(curl -s -o /tmp/ctcae_v5_response.json \
  -w "%{http_code}" \
  -X POST "$HAPI_URL" \
  -H "Content-Type: application/fhir+json" \
  --data-binary @"$BUNDLE_FILE")

echo ""
if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo "✓ Caricamento completato (HTTP $HTTP_STATUS)"
  echo ""
  echo "Risorse disponibili:"
  echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v5"
  echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v5-adverse-events"
  echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-grade-severity"
else
  echo "✗ Errore HTTP $HTTP_STATUS"
  echo "Risposta HAPI:"
  cat /tmp/ctcae_v5_response.json 2>/dev/null || echo "(nessuna risposta)"
  exit 1
fi
