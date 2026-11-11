#!/usr/bin/env bash
# Disattiva i trigger e i job di Zammad che mandavano email sui ticket: da quando le email dei ticket
# (report settimanale e ticket ad alta priorita') le manda il microservizio Zammad, restano doppie.
#
#   Trigger: "Ticket - conferma apertura al cliente", "Ticket - cambio assegnatario (gruppo)",
#            "Ticket - apertura (gruppo)", "Ticket - modifica (gruppo)", "Ticket - chiusura (gruppo)"
#   Job:     "Ticket - sollecito dopo 2 giorni senza risposta", "Ticket - promemoria giornaliero in attesa di risposta"
#   NON tocca: "Ticket - presa in carico alla risposta".
#
# Uso:
#   ZAMMAD_TOKEN=<token admin> ./setup/install/disable_zammad_native_emails.sh <ZAMMAD_URL>           # solo elenco
#   ZAMMAD_TOKEN=<token admin> ./setup/install/disable_zammad_native_emails.sh <ZAMMAD_URL> --apply   # disattiva
#
# Idempotente: gli elementi gia' disattivi si saltano. Si ferma al primo errore HTTP.
# Il token e' letto dall'ambiente (non da argomento) e non compare mai in output.
# Per riattivare: Admin -> Trigger / Scheduler di Zammad, oppure lo stesso PUT con active=true.
set -euo pipefail

if [ $# -lt 1 ] || [ -z "${ZAMMAD_TOKEN:-}" ]; then
  echo "Uso: ZAMMAD_TOKEN=<token> $0 <ZAMMAD_URL> [--apply]"
  exit 1
fi

API="${1%/}"
API="${API%/api/v1}/api/v1"
APPLY="no"
[ "${2:-}" = "--apply" ] && APPLY="yes"
AUTH="Authorization: Bearer ${ZAMMAD_TOKEN}"

TRIGGERS=(
  "Ticket - conferma apertura al cliente"
  "Ticket - cambio assegnatario (gruppo)"
  "Ticket - apertura (gruppo)"
  "Ticket - modifica (gruppo)"
  "Ticket - chiusura (gruppo)"
)
JOBS=(
  "Ticket - sollecito dopo 2 giorni senza risposta"
  "Ticket - promemoria giornaliero in attesa di risposta"
)

# Cerca per nome in "$1" (triggers|jobs); stampa "<id> <active>" oppure nulla.
find_item() {
  local kind="$1" name="$2" json
  json="$(curl -sf -H "$AUTH" "$API/$kind")" || { echo "ERRORE: lettura di $kind non riuscita" >&2; exit 2; }
  printf '%s' "$json" | python3 -I -c '
import sys, json
name = sys.argv[1]
for x in json.load(sys.stdin):
    if x.get("name") == name:
        print(x["id"], "true" if x.get("active") else "false")
        break
' "$name"
}

process() {
  local kind="$1" name="$2" found id active
  found="$(find_item "$kind" "$name")"
  if [ -z "$found" ]; then
    echo "non trovato   : $name"
    return
  fi
  id="${found%% *}"
  active="${found##* }"
  if [ "$active" = "false" ]; then
    echo "gia' disattivo: $name (id $id)"
  elif [ "$APPLY" = "yes" ]; then
    curl -sf -X PUT -H "$AUTH" -H "Content-Type: application/json" -d '{"active":false}' \
      "$API/$kind/$id" >/dev/null || { echo "ERRORE: disattivazione di '$name' non riuscita" >&2; exit 3; }
    echo "disattivato   : $name (id $id)"
  else
    echo "si disattiverebbe: $name (id $id)"
  fi
}

for n in "${TRIGGERS[@]}"; do process triggers "$n"; done
for n in "${JOBS[@]}"; do process jobs "$n"; done
[ "$APPLY" = "yes" ] || echo "Nessuna modifica fatta: aggiungere --apply per disattivare."
