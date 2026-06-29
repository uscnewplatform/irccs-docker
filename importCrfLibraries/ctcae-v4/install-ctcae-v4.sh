#!/usr/bin/env bash
# Carica CTCAE v4.03 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
#
# Due sorgenti possibili:
#   --source bundle  (default)  carica il ctcae-v4-bundle.json pre-generato/committato
#   --source excel              rigenera il bundle dall'Excel versionato, poi carica
#
# Esempi:
#   bash install-ctcae-v4.sh http://localhost:8080/fhir
#   bash install-ctcae-v4.sh https://hapi.irccs.infocube.it/fhir --source excel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

IMPORT_PY="$SCRIPT_DIR/import-ctcae-v4.py"
BUNDLE_FILE="$SCRIPT_DIR/ctcae-v4-bundle.json"
EXCEL_FILE="$SCRIPT_DIR/CTCAE_4.03_2010-06-14.xlsx"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────"
echo "  CTCAE v4.03 → HAPI FHIR"
echo "  URL     : $HAPI_URL"
echo "  Sorgente: $SOURCE"
echo "─────────────────────────────────────────────────"

crf_resolve_bundle
crf_push

echo ""
echo "Risorse disponibili:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v4"
echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v4-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-grade-severity"
