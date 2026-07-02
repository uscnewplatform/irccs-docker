#!/usr/bin/env bash
# Carica EORTC QLQ-C30 v1 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: eortc-v1-bundle.json committato.
# Rigenera dall'Excel versionato con:
#   python3 import-eortc-v1.py eortc-qlq-c30.xlsx --bundle-only
#
# Esempio:  bash install-eortc-v1.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/eortc-v1-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────────"
echo "  EORTC QLQ-C30 v1 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse caricate:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/eortc-v1"
echo "  ValueSet            → $HAPI_URL/ValueSet/eortc-v1-items"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/eortc-v1-grade-severity"
