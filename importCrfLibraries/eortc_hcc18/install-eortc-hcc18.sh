#!/usr/bin/env bash
# Carica EORTC QLQ-HCC18 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: eortc-hcc18-bundle.json committato.
# Rigenera dal CSV con:  python3 import-eortc-hcc18.py --bundle-only
#
# Esempio:  bash install-eortc-hcc18.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/eortc-hcc18-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────────"
echo "  EORTC QLQ-HCC18 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse caricate:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/eortc-hcc18"
echo "  ValueSet            → $HAPI_URL/ValueSet/eortc-hcc18-items"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/eortc-hcc18-metadata"
