#!/usr/bin/env bash
# Helper condiviso per gli install-*.sh delle CRF library (CTCAE / PRO-CTCAE / EORTC).
#
# Ogni install-*.sh definisce, PRIMA di sourcare questo file:
#   SCRIPT_DIR   directory dello script
#   IMPORT_PY    percorso import-*.py
#   BUNDLE_FILE  percorso *-bundle.json pre-generato
#   EXCEL_FILE   percorso .xlsx versionato nella cartella (vuoto se non disponibile)
#
# Poi:
#   crf_parse_args "$@"     # imposta HAPI_URL e SOURCE
#   crf_resolve_bundle      # se SOURCE=excel rigenera BUNDLE_FILE da Excel; valida
#   crf_push                # POST del BUNDLE_FILE su HAPI, exit!=0 su errore

# Default
HAPI_URL="http://localhost:8080/fhir"
SOURCE="bundle"

_err() { echo "ERRORE: $*" >&2; exit 1; }

crf_usage() {
  cat >&2 <<EOF
Uso: $(basename "$0") [HAPI_URL] [--source bundle|excel]

  HAPI_URL            default http://localhost:8080/fhir
  --source bundle     (default) carica il *-bundle.json pre-generato e committato
  --source excel      rigenera il bundle dall'Excel versionato e poi lo carica
  --from-bundle       alias di --source bundle
  --from-excel        alias di --source excel
  -h, --help          questo messaggio
EOF
}

crf_parse_args() {
  local got_url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --source)      SOURCE="${2:?--source richiede bundle|excel}"; shift 2 ;;
      --source=*)    SOURCE="${1#*=}"; shift ;;
      --from-excel)  SOURCE="excel";  shift ;;
      --from-bundle) SOURCE="bundle"; shift ;;
      -h|--help)     crf_usage; exit 0 ;;
      -*)            _err "opzione sconosciuta: $1 (usa --help)" ;;
      *)             HAPI_URL="$1"; got_url=1; shift ;;
    esac
  done
  HAPI_URL="${HAPI_URL%/}"
  case "$SOURCE" in
    bundle|excel) ;;
    *) _err "--source dev'essere 'bundle' o 'excel' (ricevuto: $SOURCE)" ;;
  esac
  : "$got_url"  # silenzia shellcheck
}

# Rigenera il bundle dall'Excel (SOURCE=excel) oppure valida quello esistente (SOURCE=bundle).
crf_resolve_bundle() {
  if [ "$SOURCE" = "excel" ]; then
    [ -n "$EXCEL_FILE" ] && [ -f "$EXCEL_FILE" ] || _err \
"Excel sorgente non versionato in questa cartella.
  Passa il percorso e rigenera a mano il bundle:
    python3 \"$IMPORT_PY\" <percorso_excel> --bundle-only
  poi rilancia con --source bundle."
    command -v python3 >/dev/null 2>&1 || _err "python3 non trovato (serve per --source excel)."
    echo "→ Rigenero il bundle dall'Excel: $(basename "$EXCEL_FILE")"
    if ! python3 "$IMPORT_PY" "$EXCEL_FILE" --bundle-only; then
      echo "" >&2
      _err "generazione bundle fallita. Se mancano dipendenze:
    pip install -r \"$SCRIPT_DIR/../requirements.txt\""
    fi
    echo "→ Bundle rigenerato: $(basename "$BUNDLE_FILE")"
  else
    [ -f "$BUNDLE_FILE" ] || _err \
"Bundle $(basename "$BUNDLE_FILE") non trovato.
  Generalo dall'Excel versionato:
    bash $(basename "$0") --source excel
  oppure manualmente:
    python3 \"$IMPORT_PY\" <percorso_excel> --bundle-only"
  fi
}

# POST del bundle su HAPI. Stampa esito; exit 1 su errore HTTP.
crf_push() {
  local resp; resp="$(mktemp)"
  echo ""
  echo "Caricamento su $HAPI_URL  (bundle $(du -h "$BUNDLE_FILE" | cut -f1))..."
  # || true: su connection-refused curl esce !=0; senza questo set -e abortirebbe
  # prima di mostrare l'errore. Con -w resta comunque "000" su stdout.
  local code
  code=$(curl -s -o "$resp" -w "%{http_code}" \
    -X POST "$HAPI_URL" \
    -H "Content-Type: application/fhir+json" \
    --data-binary @"$BUNDLE_FILE" || true)
  code="${code:-000}"
  if [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    echo "✓ Caricamento completato (HTTP $code)"
    rm -f "$resp"
    return 0
  fi
  echo "✗ Errore HTTP $code" >&2
  cat "$resp" >&2 2>/dev/null
  rm -f "$resp"
  exit 1
}
