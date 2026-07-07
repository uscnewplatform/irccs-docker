#!/usr/bin/env bash
# Carica CTCAE v5.0 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: ctcae-v5-bundle.json committato.
# Rigenera dall'Excel versionato con:
#   python3 import-ctcae-v5.py CTCAE_v5.0_2017-11-27.xlsx --bundle-only
#
# Esempio:  bash install-ctcae-v5.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/ctcae-v5-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────"
echo "  CTCAE v5.0 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse disponibili:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v5"
echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v5-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-v5-grade-severity"
