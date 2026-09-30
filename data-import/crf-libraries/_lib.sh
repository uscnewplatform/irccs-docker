#!/usr/bin/env bash
# Helper condiviso per gli install-*.sh delle CRF library.
#
# Sorgente unica = *-bundle.json committato (pure curl, zero dipendenze).
# Nessun Excel collegato: per rigenerare un bundle dalla sua sorgente si usa
# direttamente import-*.py (CSV per le library CSV, xlsx per CTCAE/EORTC-C30).
#
# Ogni install-*.sh definisce, PRIMA di sourcare questo file:
#   BUNDLE_FILE  percorso *-bundle.json pre-generato
# Poi:
#   crf_parse_args "$@"     # imposta HAPI_URL
#   crf_push                # POST del BUNDLE_FILE su HAPI, exit!=0 su errore

# Default
HAPI_URL="http://localhost:8080/fhir"

_err() { echo "ERRORE: $*" >&2; exit 1; }

crf_usage() {
  cat >&2 <<EOF
Uso: $(basename "$0") [HAPI_URL]

  HAPI_URL   URL base HAPI FHIR (default http://localhost:8080/fhir)
  -h, --help questo messaggio

Carica il *-bundle.json committato. Per rigenerarlo dalla sorgente:
  python3 <cartella>/import-*.py --bundle-only
EOF
}

crf_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) crf_usage; exit 0 ;;
      -*)        _err "opzione sconosciuta: $1 (usa --help)" ;;
      *)         HAPI_URL="$1"; shift ;;
    esac
  done
  HAPI_URL="${HAPI_URL%/}"
}

# POST del bundle su HAPI. Stampa esito; exit 1 su errore HTTP.
crf_push() {
  [ -f "$BUNDLE_FILE" ] || _err \
"Bundle $(basename "$BUNDLE_FILE") non trovato.
  Generalo dalla sorgente:
    python3 $(dirname "$0")/import-*.py --bundle-only"

  local resp; resp="$(mktemp)"
  echo ""
  echo "Caricamento su $HAPI_URL  (bundle $(du -h "$BUNDLE_FILE" | cut -f1))..."
  # || true: su connection-refused curl esce !=0; con -w resta "000" su stdout.
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
