#!/usr/bin/env bash
# Carica CTCAE v6.0 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
# Sorgente: ctcae-v6-bundle.json committato.
# Rigenera dall'Excel versionato con:
#   python3 import-ctcae-v6.py CTCAE_v6.0_Final_Jan2026.xlsx --bundle-only
#
# Esempio:  bash install-ctcae-v6.sh http://localhost:8080/fhir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

BUNDLE_FILE="$SCRIPT_DIR/ctcae-v6-bundle.json"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────"
echo "  CTCAE v6.0 → HAPI FHIR"
echo "  URL: $HAPI_URL"
echo "─────────────────────────────────────────────────"

crf_push

echo ""
echo "Risorse disponibili:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v6"
echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v6-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-v6-grade-severity"
echo ""
echo "Test ricerca:"
echo "  curl \"$HAPI_URL/ValueSet/\\\$expand?url=https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6-adverse-events&filter=anemia&count=5\""
