#!/usr/bin/env bash
# Carica CTCAE v4.03 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: ctcae-v4-bundle.json committato.
# Rigenera dall'Excel versionato con:
#   python3 import-ctcae-v4.py CTCAE_4.03_2010-06-14.xlsx --bundle-only
#
# Esempio:  bash install-ctcae-v4.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/ctcae-v4-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────"
echo "  CTCAE v4.03 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse disponibili:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v4"
echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v4-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-v4-grade-severity"
