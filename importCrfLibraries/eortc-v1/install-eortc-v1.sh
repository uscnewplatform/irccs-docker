#!/usr/bin/env bash
# Carica EORTC QLQ-C30 v1 (CodeSystem + ValueSet + StructureDefinition) su HAPI FHIR.
#
# Due sorgenti possibili:
#   --source bundle  (default)  carica l'eortc-v1-bundle.json pre-generato/committato
#   --source excel              rigenera il bundle dall'Excel versionato, poi carica
#
# Esempi:
#   bash install-eortc-v1.sh http://localhost:8080/fhir
#   bash install-eortc-v1.sh https://hapi.irccs.infocube.it/fhir --source excel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../_lib.sh"

IMPORT_PY="$SCRIPT_DIR/import-eortc-v1.py"
BUNDLE_FILE="$SCRIPT_DIR/eortc-v1-bundle.json"
EXCEL_FILE="$SCRIPT_DIR/eortc-qlq-c30.xlsx"

crf_parse_args "$@"

echo "─────────────────────────────────────────────────────"
echo "  EORTC QLQ-C30 v1 → HAPI FHIR"
echo "  URL     : $HAPI_URL"
echo "  Sorgente: $SOURCE"
echo "─────────────────────────────────────────────────────"

crf_resolve_bundle
crf_push

echo ""
echo "Risorse caricate:"
echo "  CodeSystem          → $HAPI_URL/CodeSystem/eortc-v1"
echo "  ValueSet            → $HAPI_URL/ValueSet/eortc-v1-items"
echo "  StructureDefinition → $HAPI_URL/StructureDefinition/eortc-v1-grade-severity"
