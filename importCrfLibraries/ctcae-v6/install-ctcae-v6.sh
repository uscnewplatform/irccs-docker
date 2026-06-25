#!/usr/bin/env bash
# Carica CTCAE v6.0 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
#
# Due sorgenti possibili:
#   --source bundle  (default)  carica il ctcae-v6-bundle.json pre-generato/committato
#   --source excel              rigenera il bundle dall'Excel, poi carica
#
# Esempi:
#   bash install-ctcae-v6.sh http://localhost:8080/fhir
#   bash install-ctcae-v6.sh https://hapi.irccs.infocube.it/fhir --source excel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

IMPORT_PY="$SCRIPT_DIR/import-ctcae-v6.py"
BUNDLE_FILE="$SCRIPT_DIR/ctcae-v6-bundle.json"
EXCEL_FILE="$SCRIPT_DIR/CTCAE_v6.0_Final_Jan2026.xlsx"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────"
echo "  CTCAE v6.0 → HAPI FHIR"
echo "  URL     : $HAPI_URL"
echo "  Sorgente: $SOURCE"
echo "─────────────────────────────────────────────────"

crf_resolve_bundle
crf_push

echo ""
echo "Risorse disponibili:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v6"
echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v6-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-grade-severity"
echo ""
echo "Test ricerca:"
echo "  curl \"$HAPI_URL/ValueSet/\\\$expand?url=https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6-adverse-events&filter=anemia&count=5\""
