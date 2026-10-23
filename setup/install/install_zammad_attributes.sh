#!/usr/bin/env bash
# Crea su Zammad gli attributi personalizzati (Object Manager) usati dalla piattaforma.
#
#   Ticket: crf, crfdisplay, careplan, careplandisplay, patient, patientdisplay,
#           patientjourneydisplay, directlink, crfscope, qrid, crfclosure
#   Group : organization, keycloak_ref   (e keycloak_ref su User e Organization: collegamento con Keycloak)
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
# Idempotente: gli attributi gia' presenti vengono saltati, non modificati. Fa eccezione la visibilita' in
# modifica dei campi che identificano la CRF (patient, careplan, crf, crfscope, qrid, crfclosure): si nascondono
# nella maschera di modifica di Zammad, cosi' un operatore non puo' togliere il ticket dal blocco cambiandoli.
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
# Campi che identificano la CRF e il segno di "chiuso dalla piattaforma": non si modificano dall'interfaccia di
# Zammad (la piattaforma li scrive via API alla creazione e alla chiusura convalidata).
KEY_SCREENS='{"create_middle":{"ticket.agent":{"shown":false,"required":false}},"edit":{"ticket.agent":{"shown":false,"required":false}}}'
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
# Ambito del ticket (CRF = blocca la conferma della CRF; STUDY = annuncio di studio, non blocca) e id della
# QuestionnaireResponse. Nomi vincolati da Zammad: "scope" e' riservato e i nomi non possono finire per _id.
crea_attributo Ticket crfscope              "Ambito (CRF/STUDY)"           input    50   "$TICKET_SCREENS"
crea_attributo Ticket qrid                  "QuestionnaireResponse (id)"   input    50   "$TICKET_SCREENS"
# Chiusura convalidata dalla piattaforma: "<utente>|<data ISO>" scritto alla chiusura dal pannello (o alla convalida).
# Un ticket chiuso SENZA questo segno (chiuso direttamente in Zammad) continua a bloccare la conferma della CRF.
crea_attributo Ticket crfclosure            "Chiusura convalidata"         input    255  "$KEY_SCREENS"

# Nasconde in modifica i campi chiave anche dove esistevano gia' (installazioni precedenti). Zammad accetta
# l'aggiornamento solo con il corpo completo dell'attributo (con i soli "screens" risponde 500).
nascondi_in_modifica() {
  local name="$1" body id
  body="$(curl -sf -H "$AUTH" "$API/object_manager_attributes" | python3 -I -c 'import sys,json
name, screens = sys.argv[1], json.loads(sys.argv[2])
for a in json.load(sys.stdin):
    if a["object"] == "Ticket" and a["name"] == name:
        print(json.dumps({"id": a["id"], "object": "Ticket", "name": name, "display": a["display"], "active": a["active"],
                          "data_type": a["data_type"], "data_option": a["data_option"], "screens": screens}))' "$name" "$KEY_SCREENS")" || true
  [ -n "$body" ] || return 0
  id="$(python3 -I -c 'import sys,json;print(json.loads(sys.argv[1])["id"])' "$body")"
  curl -sf -o /dev/null -X PUT -H "$AUTH" -H 'Content-Type: application/json' -d "$body" "$API/object_manager_attributes/$id" \
    && echo "  ~ Ticket.$name nascosto in modifica" || echo "  ! Ticket.$name: aggiornamento visibilita' non riuscito" >&2
}
for n in patient careplan crf crfscope qrid; do nascondi_in_modifica "$n"; done

echo "Attributi Group"
crea_attributo Group organization           "Organization FHIR (id)"       input    255  "$GROUP_SCREENS"

# Collegamento con Keycloak: la sincronizzazione utenti/organizzazioni/gruppi (ms Zammad) scrive qui l'id Keycloak e
# da qui il ms riconosce l'utente che chiama (un utente senza keycloak_ref riceve 403 "Utente non presente su Zammad").
# Non sono campi da compilare a mano: nascosti nelle schermate.
KC_USER_SCREENS='{"create":{"admin.user":{"shown":false,"required":false}},"edit":{"admin.user":{"shown":false,"required":false}}}'
KC_ORG_SCREENS='{"create":{"admin.organization":{"shown":false,"required":false}},"edit":{"admin.organization":{"shown":false,"required":false}}}'
KC_GROUP_SCREENS='{"create":{"admin.group":{"shown":false,"required":false}},"edit":{"admin.group":{"shown":false,"required":false}}}'
echo "Attributi per il collegamento con Keycloak"
crea_attributo User         keycloak_ref    "Keycloak (id)"                input    255  "$KC_USER_SCREENS"
crea_attributo Organization keycloak_ref    "Keycloak (id)"                input    255  "$KC_ORG_SCREENS"
crea_attributo Group        keycloak_ref    "Keycloak (id)"                input    255  "$KC_GROUP_SCREENS"

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
