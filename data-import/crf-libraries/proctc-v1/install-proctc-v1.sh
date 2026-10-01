#!/usr/bin/env bash
# Carica PRO-CTCAE v1 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: proctc-v1-bundle.json committato.
# Rigenera dal CSV con:  python3 import-proctc-v1.py --bundle-only
#
# Esempio:  bash install-proctc-v1.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/proctc-v1-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────────"
echo "  PRO-CTCAE v1 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse caricate:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/proctc-v1"
echo "  ValueSet            → $HAPI_URL/ValueSet/proctc-v1-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/proctc-v1-grade-severity"
