#!/usr/bin/env bash
# Crea su Zammad il webhook e i due trigger (ticket creato / ticket aggiornato) che avvisano il microservizio
# Zammad di ogni cambiamento, cosi' il Task ticket-ref su HAPI resta allineato (blocco della conferma CRF).
#
# Il webhook e' solo una NOTIFICA firmata (HMAC-SHA1, header X-Hub-Signature): il microservizio rilegge il
# ticket da Zammad, non si fida del payload. Servono DUE trigger perche' un trigger Zammad ha una sola azione.
# Cancellazioni di ticket NON generano eventi: le recupera la riconciliazione periodica del microservizio.
#
# Uso:
#   ZAMMAD_TOKEN=<token admin> WEBHOOK_SECRET=<segreto> \
#   ./setup/install/install_zammad_webhook.sh <ZAMMAD_URL> <WEBHOOK_URL>
#
# Esempio:
#   ZAMMAD_TOKEN=xxxx WEBHOOK_SECRET=yyyy ./setup/install/install_zammad_webhook.sh \
#       https://zammad.infocube.it http://irccs-zammad:8080/fhir/zammad/webhook
#
# Lo stesso WEBHOOK_SECRET va dato al microservizio come ZAMMAD_WEBHOOK_SECRET (insieme a
# ZAMMAD_TICKET_REF_ENABLED=true). Token e segreto si leggono dall'ambiente (non da argomento).
# Il token deve avere il permesso admin.webhook / admin.trigger.
#
# Idempotente: webhook e trigger con lo stesso nome esistenti vengono saltati (non modificati).
set -euo pipefail

if [ $# -lt 2 ] || [ -z "${ZAMMAD_TOKEN:-}" ] || [ -z "${WEBHOOK_SECRET:-}" ]; then
  echo "Uso: ZAMMAD_TOKEN=<token> WEBHOOK_SECRET=<segreto> $0 <ZAMMAD_URL> <WEBHOOK_URL>"
  exit 1
fi

API="${1%/}"
API="${API%/api/v1}/api/v1"
ENDPOINT="$2"
AUTH="Authorization: Bearer ${ZAMMAD_TOKEN}"
WEBHOOK_NAME="irccs-ticket-ref"

json_get() { python3 -I -c "import sys,json; d=json.load(sys.stdin); print($1)"; }

# 1. Webhook
EXISTING_WH="$(curl -sf -H "$AUTH" "$API/webhooks" | json_get "next((w['id'] for w in d if w['name']=='$WEBHOOK_NAME'), '')")" || {
  echo "ERRORE: impossibile leggere i webhook (URL/token/permessi errati?)" >&2; exit 1; }

if [ -n "$EXISTING_WH" ]; then
  WH_ID="$EXISTING_WH"
  echo "  = webhook '$WEBHOOK_NAME' gia' presente (id $WH_ID), salto"
else
  BODY="$(WEBHOOK_NAME="$WEBHOOK_NAME" ENDPOINT="$ENDPOINT" SECRET="$WEBHOOK_SECRET" python3 -I -c '
import json, os
print(json.dumps({"name": os.environ["WEBHOOK_NAME"], "endpoint": os.environ["ENDPOINT"],
                  "signature_token": os.environ["SECRET"], "ssl_verify": True, "active": True}))')"
  RESP="$(curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "$BODY" "$API/webhooks")" || {
    echo "ERRORE: creazione webhook fallita" >&2; exit 1; }
  WH_ID="$(printf '%s' "$RESP" | json_get "d['id']")"
  echo "  + webhook '$WEBHOOK_NAME' creato (id $WH_ID)"
fi

# 2. Trigger
EXISTING_TR="$(curl -sf -H "$AUTH" "$API/triggers" | json_get "' '.join(t['name'] for t in d)")" || {
  echo "ERRORE: impossibile leggere i trigger" >&2; exit 1; }

crea_trigger() {
  local name="$1" action="$2"
  if grep -qw -- "$name" <<<"$EXISTING_TR"; then
    echo "  = trigger '$name' gia' presente, salto"
    return 0
  fi
  local body
  body="$(NAME="$name" ACTION="$action" WH_ID="$WH_ID" python3 -I -c '
import json, os
print(json.dumps({"name": os.environ["NAME"],
  "condition": {"ticket.action": {"operator": "is", "value": os.environ["ACTION"]}},
  "perform": {"notification.webhook": {"webhook_id": os.environ["WH_ID"]}},
  "activator": "action", "execution_condition_mode": "always", "active": True}))')"
  curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "$body" "$API/triggers" >/dev/null || {
    echo "ERRORE: creazione trigger '$name' fallita" >&2; exit 1; }
  echo "  + trigger '$name' creato"
}

crea_trigger "irccs-ticket-ref-create" "create"
crea_trigger "irccs-ticket-ref-update" "update"

echo "OK. Imposta sul microservizio: ZAMMAD_TICKET_REF_ENABLED=true ZAMMAD_WEBHOOK_SECRET=<stesso segreto>."
