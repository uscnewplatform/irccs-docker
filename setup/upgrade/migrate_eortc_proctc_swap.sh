#!/bin/bash
# Migrazione una-tantum: corregge lo scambio storico EORTC<->PROCTC su
# Questionnaire.identifier.system, introdotto dal bug in
# irccs-react-dashboard/src/fhir/models/Questionnaire.ts (PROCTC_V1 aveva
# system="EORTC", EORTC_V1 aveva system="PROCTC" - ora corretto nel codice).
#
# Questo script allinea le risorse GIA' persistite in HAPI FHIR alla nuova
# semantica corretta:
#   - Questionnaire con identifier system="EORTC" value="V1" (in realta'
#     PRO-CTCAE, creato da PROCTC_V1 col bug)      -> diventa system="PROCTC"
#   - Questionnaire con identifier system="PROCTC" value="V1" (in realta'
#     EORTC QLQ-C30, creato da EORTC_V1 col bug)   -> diventa system="EORTC"
#
# Idempotente: se rilanciato dopo il primo giro, le due query non trovano
# piu' nulla da correggere (i valori sono gia' quelli giusti).
#
# Richiede: curl, jq.
#
# Uso: ./migrate_eortc_proctc_swap.sh <fhir-base-url> [bearer-token]
#   es: ./migrate_eortc_proctc_swap.sh http://localhost:8080/fhir
#       ./migrate_eortc_proctc_swap.sh https://pj.istitutotumori.na.it/fhir "$TOKEN"

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Uso: $0 <fhir-base-url> [bearer-token]"
  exit 1
fi

FHIR_BASE="${1%/}"
TOKEN="${2:-}"

AUTH_HEADER=()
if [ -n "$TOKEN" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
fi

command -v jq >/dev/null || { echo "Serve jq installato."; exit 1; }

# Raccoglie TUTTI gli id prima di scrivere qualsiasi cosa: se si mutasse e
# cercasse nello stesso passaggio, la seconda query ripescherebbe le
# risorse appena corrette dalla prima, ri-scambiandole all'infinito.
fetch_ids() {
  local system_value="$1"
  curl -s "${AUTH_HEADER[@]}" \
    "$FHIR_BASE/Questionnaire?identifier=${system_value}&_elements=id&_count=200" \
    | jq -r '.entry[]?.resource.id // empty'
}

echo "Cerco Questionnaire con identifier EORTC|V1 (da correggere in PROCTC)..."
IDS_EORTC_TO_PROCTC=$(fetch_ids "EORTC|V1")
echo "Cerco Questionnaire con identifier PROCTC|V1 (da correggere in EORTC)..."
IDS_PROCTC_TO_EORTC=$(fetch_ids "PROCTC|V1")

swap_system() {
  local id="$1"
  local from_system="$2"
  local to_system="$3"

  local resource
  resource=$(curl -s "${AUTH_HEADER[@]}" "$FHIR_BASE/Questionnaire/$id")

  local updated
  updated=$(echo "$resource" | jq --arg from "$from_system" --arg to "$to_system" '
    .identifier = (.identifier // []) | map(
      if .system == $from then .system = $to else . end
    )
  ')

  curl -s -o /dev/null -w "  Questionnaire/$id -> HTTP %{http_code}\n" \
    "${AUTH_HEADER[@]}" \
    -H "Content-Type: application/fhir+json" \
    -X PUT "$FHIR_BASE/Questionnaire/$id" \
    -d "$updated"
}

COUNT=0
for id in $IDS_EORTC_TO_PROCTC; do
  echo "EORTC -> PROCTC: $id"
  swap_system "$id" "EORTC" "PROCTC"
  COUNT=$((COUNT + 1))
done

for id in $IDS_PROCTC_TO_EORTC; do
  echo "PROCTC -> EORTC: $id"
  swap_system "$id" "PROCTC" "EORTC"
  COUNT=$((COUNT + 1))
done

echo "Fatto. Questionnaire corretti: $COUNT"
