#!/usr/bin/env bash
# Crea su Zammad gli attributi personalizzati (Object Manager) usati dalla piattaforma.
#
#   Ticket: crf, crfdisplay, careplan, careplandisplay, patient, patientdisplay,
#           patientjourneydisplay, directlink
#   Group : organization
#
# Senza questi attributi Zammad SCARTA IN SILENZIO i campi inviati dalla dashboard alla
# creazione del ticket: il ticket nasce senza collegamento a paziente/CRF/percorso e il
# contatore ticket della dashboard (che raggruppa per patientjourneydisplay) non lo conta.
# Il MS irccs-microservice-zammad verifica la presenza degli attributi all'avvio.
#
# Uso:
#   ZAMMAD_TOKEN=<token admin> ./setup/install/install_zammad_attributes.sh <ZAMMAD_URL>
#
# Esempio:
#   ZAMMAD_TOKEN=xxxx ./setup/install/install_zammad_attributes.sh https://zammad.infocube.it
#
# Il token e' letto dall'ambiente (non da argomento) per non lasciarlo nella history/ps.
# Il token deve essere di un utente con permesso admin.object (Admin -> Oggetti).
#
# Idempotente: gli attributi gia' presenti vengono saltati, non modificati.
set -euo pipefail

if [ $# -lt 1 ] || [ -z "${ZAMMAD_TOKEN:-}" ]; then
  echo "Uso: ZAMMAD_TOKEN=<token> $0 <ZAMMAD_URL>"
  echo "Esempio: ZAMMAD_TOKEN=xxxx $0 https://zammad.infocube.it"
  exit 1
fi

API="${1%/}"
API="${API%/api/v1}/api/v1"
AUTH="Authorization: Bearer ${ZAMMAD_TOKEN}"

# Elenco "Oggetto.nome" gia' presenti
EXISTING="$(curl -sf -H "$AUTH" "$API/object_manager_attributes" \
  | python3 -I -c 'import sys,json; [print(a["object"]+"."+a["name"]) for a in json.load(sys.stdin)]')" || {
  echo "ERRORE: impossibile leggere object_manager_attributes (URL/token/permessi errati?)" >&2
  exit 1
}

CREATED=0

# crea_attributo <Oggetto> <nome> <etichetta> <tipo: input|textarea> <maxlength> <screens JSON>
crea_attributo() {
  local obj="$1" name="$2" display="$3" type="$4" maxlen="$5" screens="$6"

  if grep -qx "$obj.$name" <<<"$EXISTING"; then
    echo "  = $obj.$name gia' presente, salto"
    return 0
  fi

  local data_option
  if [ "$type" = "textarea" ]; then
    data_option="{\"type\":\"textarea\",\"maxlength\":$maxlen,\"rows\":4,\"null\":true,\"default\":\"\"}"
  else
    data_option="{\"type\":\"text\",\"maxlength\":$maxlen,\"null\":true,\"default\":\"\"}"
  fi

  local body="{\"object\":\"$obj\",\"name\":\"$name\",\"display\":\"$display\",\"active\":true,\"data_type\":\"$type\",\"data_option\":$data_option,\"screens\":$screens}"
  local code
  code="$(curl -s -o /tmp/zammad_attr_resp.$$ -w '%{http_code}' -X POST -H "$AUTH" \
    -H 'Content-Type: application/json' -d "$body" "$API/object_manager_attributes")"

  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    echo "  ! $obj.$name ERRORE HTTP $code: $(cat /tmp/zammad_attr_resp.$$)" >&2
    rm -f /tmp/zammad_attr_resp.$$
    exit 1
  fi
  rm -f /tmp/zammad_attr_resp.$$
  echo "  + $obj.$name creato"
  CREATED=$((CREATED + 1))
}

TICKET_SCREENS='{"create_middle":{"ticket.agent":{"shown":true,"required":false,"item_class":"column"}},"edit":{"ticket.agent":{"shown":true,"required":false}}}'
GROUP_SCREENS='{"create":{"admin.group":{"shown":true,"required":false}},"edit":{"admin.group":{"shown":true,"required":false}}}'

echo "Zammad: $API"
echo "Attributi Ticket"
crea_attributo Ticket crf                   "CRF (id)"                     input    255  "$TICKET_SCREENS"
crea_attributo Ticket crfdisplay            "CRF"                          input    255  "$TICKET_SCREENS"
crea_attributo Ticket careplan              "Percorso di cura (id)"        input    255  "$TICKET_SCREENS"
crea_attributo Ticket careplandisplay       "Percorso di cura"             input    255  "$TICKET_SCREENS"
crea_attributo Ticket patient               "Paziente (id)"                input    255  "$TICKET_SCREENS"
crea_attributo Ticket patientdisplay        "Paziente"                     input    255  "$TICKET_SCREENS"
crea_attributo Ticket patientjourneydisplay "Studio / percorso paziente"   input    255  "$TICKET_SCREENS"
crea_attributo Ticket directlink            "Link diretto"                 textarea 2000 "$TICKET_SCREENS"

echo "Attributi Group"
crea_attributo Group organization           "Organization FHIR (id)"       input    255  "$GROUP_SCREENS"

# Gli attributi diventano colonne del DB solo dopo la migrazione. Si esegue sempre (idempotente
# in Zammad): copre anche il caso di un giro precedente interrotto dopo la creazione.
# Body '{}' esplicito: senza, nginx davanti a Zammad risponde 411 (Length Required).
echo "Eseguo le migrazioni dell'Object Manager..."
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" \
  -H 'Content-Type: application/json' -d '{}' "$API/object_manager_attributes_execute_migrations")"
if [ "$code" != "200" ] && [ "$code" != "201" ]; then
  echo "ERRORE: execute_migrations HTTP $code (attributi creati ma non applicati: rieseguire o applicarli da Admin -> Oggetti)" >&2
  exit 1
fi

echo "OK: $CREATED attributi creati."
echo "Nota: per Group.organization vanno ancora valorizzati a mano i gruppi annunci_* (vedi zammad-ticketing/README.md)."
