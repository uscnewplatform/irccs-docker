#!/usr/bin/env bash
# Crea in Zammad il webhook, il trigger e il job che avvisano il microservizio Zammad quando una Query ad alta priorità
# cambia: il microservizio decide poi se mandare le email (apertura, chiusura, riapertura, sollecito).
#
#   Webhook : "IRCCS Query - email"            -> POST <WEBHOOK_URL> con {"ticket_id": "N"}, firmato (X-Hub-Signature)
#   Trigger : "IRCCS Query - email (priorità alta)" a ogni creazione/modifica di una Query di CRF ad alta priorità
#   Job     : "IRCCS Query - sollecito (ogni ora)"   ogni ora, per le Query ad alta priorità non chiuse
#
# Uso:
#   ZAMMAD_TOKEN=<token admin> WEBHOOK_SECRET=<segreto> ./setup/install/install_zammad_email_webhook.sh <ZAMMAD_URL> [--apply]
#
# Variabili:
#   ZAMMAD_TOKEN     token di un utente con permesso admin (letto dall'ambiente, mai da argomento)
#   WEBHOOK_SECRET   segreto condiviso: lo stesso di ZAMMAD_NOTIFICATIONS_WEBHOOK_SECRET del microservizio
#   WEBHOOK_URL      indirizzo del microservizio visto da Zammad
#                    (default http://irccs-zammad:8080/fhir/zammad/notifications/webhook)
#
# Senza --apply elenca soltanto. Idempotente: gli oggetti con lo stesso nome non si ricreano. Il container "scheduler" di
# Zammad (che esegue i webhook) deve essere sulla rete "irccs": vedi zammad-ticketing/docker-compose.yaml.
set -euo pipefail

if [ $# -lt 1 ] || [ -z "${ZAMMAD_TOKEN:-}" ]; then
  echo "Uso: ZAMMAD_TOKEN=<token> WEBHOOK_SECRET=<segreto> $0 <ZAMMAD_URL> [--apply]"
  exit 1
fi
API="${1%/}"
API="${API%/api/v1}/api/v1"
APPLY="no"
[ "${2:-}" = "--apply" ] && APPLY="yes"
if [ "$APPLY" = "yes" ] && [ -z "${WEBHOOK_SECRET:-}" ]; then
  echo "ERRORE: con --apply serve WEBHOOK_SECRET" >&2
  exit 1
fi
WEBHOOK_URL="${WEBHOOK_URL:-http://irccs-zammad:8080/fhir/zammad/notifications/webhook}"
AUTH="Authorization: Bearer ${ZAMMAD_TOKEN}"

WH_NAME="IRCCS Query - email"
TR_NAME="IRCCS Query - email (priorità alta)"
JOB_NAME="IRCCS Query - sollecito (ogni ora)"

get() { curl -sf -H "$AUTH" "$API/$1" || { echo "ERRORE: lettura di $1 non riuscita" >&2; exit 2; }; }
find_id() { # $1 = elenco, $2 = nome
  python3 -I -c '
import sys, json
for x in json.load(sys.stdin):
    if x.get("name") == sys.argv[1]:
        print(x["id"]); break' "$2"
}
send() { # $1 = metodo, $2 = percorso, $3 = corpo (stdin)
  curl -sf -X "$1" -H "$AUTH" -H "Content-Type: application/json" -d @- "$API/$2" || { echo "ERRORE: $1 $2 non riuscita" >&2; exit 3; }
}

WH_ID="$(get webhooks | find_id x "$WH_NAME")"
TR_ID="$(get triggers | find_id x "$TR_NAME")"
JOB_ID="$(get jobs | find_id x "$JOB_NAME")"

# stati chiusi e uniti (tipo closed e merged)
CLOSED_IDS="$(get ticket_states | python3 -I -c '
import sys, json
print(json.dumps([str(s["id"]) for s in json.load(sys.stdin) if s.get("state_type_id") in (5, 6)]))')"

if [ "$APPLY" != "yes" ]; then
  echo "webhook : ${WH_ID:+già presente (id $WH_ID)}${WH_ID:-da creare} -> $WEBHOOK_URL"
  echo "trigger : ${TR_ID:+già presente (id $TR_ID)}${TR_ID:-da creare}"
  echo "job     : ${JOB_ID:+già presente (id $JOB_ID)}${JOB_ID:-da creare}"
  echo "Nessuna modifica fatta: aggiungere --apply per creare."
  exit 0
fi

if [ -z "$WH_ID" ]; then
  WH_ID="$(WH_NAME="$WH_NAME" WEBHOOK_URL="$WEBHOOK_URL" WEBHOOK_SECRET="$WEBHOOK_SECRET" python3 -I -c '
import json, os
print(json.dumps({"name": os.environ["WH_NAME"], "endpoint": os.environ["WEBHOOK_URL"], "ssl_verify": False, "http_method": "post",
  "signature_token": os.environ["WEBHOOK_SECRET"], "customized_payload": True, "custom_payload": "{\"ticket_id\": \"#{ticket.id}\"}",
  "active": True, "note": "Avvisa il microservizio Zammad per le email delle Query"}))' | send POST webhooks | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
  echo "webhook creato (id $WH_ID)"
else
  echo "webhook già presente (id $WH_ID): non modificato"
fi

if [ -z "$TR_ID" ]; then
  TR_ID="$(TR_NAME="$TR_NAME" WH_ID="$WH_ID" python3 -I -c '
import json, os
print(json.dumps({"name": os.environ["TR_NAME"], "activator": "action", "execution_condition_mode": "always", "active": True,
  "condition": {"ticket.priority_id": {"operator": "is", "value": ["3"]}, "ticket.crfscope": {"operator": "is not", "value": "STUDY"}},
  "perform": {"notification.webhook": {"webhook_id": os.environ["WH_ID"]}}}))' | send POST triggers | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
  echo "trigger creato (id $TR_ID)"
else
  echo "trigger già presente (id $TR_ID): non modificato"
fi

if [ -z "$JOB_ID" ]; then
  JOB_ID="$(JOB_NAME="$JOB_NAME" WH_ID="$WH_ID" CLOSED_IDS="$CLOSED_IDS" python3 -I -c '
import json, os
days = {d: True for d in ("Mon","Tue","Wed","Thu","Fri","Sat","Sun")}
hours = {str(h): True for h in range(24)}
print(json.dumps({"name": os.environ["JOB_NAME"], "object": "Ticket", "active": True,
  "timeplan": {"days": days, "hours": hours, "minutes": {"0": True}},
  "condition": {"ticket.priority_id": {"operator": "is", "value": ["3"]}, "ticket.crfscope": {"operator": "is not", "value": "STUDY"},
                "ticket.state_id": {"operator": "is not", "value": json.loads(os.environ["CLOSED_IDS"])}},
  "perform": {"notification.webhook": {"webhook_id": os.environ["WH_ID"]}}}))' | send POST jobs | python3 -I -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
  echo "job creato (id $JOB_ID)"
else
  echo "job già presente (id $JOB_ID): non modificato"
fi
