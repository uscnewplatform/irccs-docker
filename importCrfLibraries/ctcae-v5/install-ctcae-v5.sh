#!/usr/bin/env bash
# Carica CTCAE v5.0 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
#
# Due sorgenti possibili:
#   --source bundle  (default)  carica il ctcae-v5-bundle.json pre-generato/committato
#   --source excel              rigenera il bundle dall'Excel versionato, poi carica
#
# Esempi:
#   bash install-ctcae-v5.sh http://localhost:8080/fhir
#   bash install-ctcae-v5.sh https://hapi.irccs.infocube.it/fhir --source excel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

IMPORT_PY="$SCRIPT_DIR/import-ctcae-v5.py"
BUNDLE_FILE="$SCRIPT_DIR/ctcae-v5-bundle.json"
EXCEL_FILE="$SCRIPT_DIR/CTCAE_v5.0_2017-11-27.xlsx"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────"
echo "  CTCAE v5.0 → HAPI FHIR"
echo "  URL     : $HAPI_URL"
echo "  Sorgente: $SOURCE"
echo "─────────────────────────────────────────────────"

crf_resolve_bundle
crf_push

echo ""
echo "Risorse disponibili:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/ctcae-v5"
echo "  ValueSet            → $HAPI_URL/ValueSet/ctcae-v5-adverse-events"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/ctcae-grade-severity"
