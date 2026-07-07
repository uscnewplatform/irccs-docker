#!/usr/bin/env bash
# Carica EuroQol EQ-5D-5L (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: euroqol-eq5d5l-bundle.json committato.
# Rigenera dal CSV con:  python3 import-euroqol-eq5d5l.py --bundle-only
#
# Esempio:  bash install-euroqol-eq5d5l.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/euroqol-eq5d5l-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────────"
echo "  EuroQol EQ-5D-5L → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse caricate:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/euroqol-eq5d5l"
echo "  ValueSet            → $HAPI_URL/ValueSet/euroqol-eq5d5l-items"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/euroqol-eq5d5l-metadata"
