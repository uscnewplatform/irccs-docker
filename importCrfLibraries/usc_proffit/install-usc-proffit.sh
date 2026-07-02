#!/usr/bin/env bash
# Carica USC PROFFIT (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: usc-proffit-bundle.json committato.
# Rigenera dal CSV con:  python3 import-usc-proffit.py --bundle-only
#
# Esempio:  bash install-usc-proffit.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/usc-proffit-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────────"
echo "  USC PROFFIT → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse caricate:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/usc-proffit"
echo "  ValueSet            → $HAPI_URL/ValueSet/usc-proffit-items"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/usc-proffit-metadata"
