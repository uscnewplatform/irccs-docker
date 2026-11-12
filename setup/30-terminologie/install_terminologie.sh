#!/usr/bin/env bash
# Terminologie e cataloghi su HAPI FHIR: librerie CRF (CTCAE, EORTC, EuroQol, PRO-CTCAE, USC PROFFIT) e farmaci AIFA.
# I dati stanno in data-import/ (bundle e CSV già committati: nessun download, tranne le classi AIFA se manca il CSV del mese).
#
# Uso:   ./setup/30-terminologie/install_terminologie.sh <HAPI_URL> [crf|aifa|tutto]     (default: tutto)
# Es.:   ./setup/30-terminologie/install_terminologie.sh http://localhost:8080/fhir
# Python con il modulo "requests" per i farmaci AIFA: PYTHON_BIN=.venv/bin/python (vedi README di setup).
# Idempotente: ogni import è un PUT condizionale, si può rilanciare.
# NON fa (manuale, opzionale): terminologia LOINC (richiede account loinc.org, vedi docs installazione.adoc sezione C).
set -euo pipefail

[ $# -ge 1 ] || { echo "Uso: $0 <HAPI_URL> [crf|aifa|tutto]"; exit 1; }
HAPI_URL="${1%/}"
WHAT="${2:-tutto}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DATA_IMPORT_DIR="$(cd "$HERE/../../data-import" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

case "$WHAT" in crf|aifa|tutto) ;; *) echo "Valore non valido: $WHAT (crf|aifa|tutto)"; exit 1 ;; esac

if [ "$WHAT" != "crf" ] && ! "$PYTHON_BIN" -c "import requests" 2>/dev/null; then
  echo "ERRORE: modulo Python 'requests' non trovato per $PYTHON_BIN (serve all'import dei farmaci AIFA)."
  echo "  python3 -m venv .venv && .venv/bin/pip install -r data-import/farmaci-aifa/requirements.txt"
  echo "  PYTHON_BIN=\"\$(pwd)/.venv/bin/python\" $0 $HAPI_URL $WHAT"
  exit 1
fi

if [ "$WHAT" = "crf" ] || [ "$WHAT" = "tutto" ]; then
  echo "== Librerie CRF (bundle committati in data-import/crf-libraries/)"
  for install_sh in "$DATA_IMPORT_DIR"/crf-libraries/*/install-*.sh; do
    echo "  -> $(basename "$(dirname "$install_sh")")"
    bash "$install_sh" "$HAPI_URL"
  done
fi

if [ "$WHAT" = "aifa" ] || [ "$WHAT" = "tutto" ]; then
  echo "== Farmaci AIFA: classi A/H + equivalenti (scarica da aifa.gov.it se manca il CSV del mese)"
  "$PYTHON_BIN" "$DATA_IMPORT_DIR/farmaci-aifa/import-aifa-per-classi/import-aifa-farmaci.py" "$HAPI_URL"
  echo "== Farmaci AIFA: confezioni + ATC (159k concept, a lotti; qualche minuto)"
  "$PYTHON_BIN" "$DATA_IMPORT_DIR/farmaci-aifa/import-confezioni-atc/import-confezioni-atc-batch.py" "$HAPI_URL"
fi
echo "Terminologie completate."
