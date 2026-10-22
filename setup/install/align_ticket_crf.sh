#!/usr/bin/env bash
# Allinea un ambiente (staging/preprod/prod) dopo il deploy delle modifiche "ticket CRF":
# blocco della conferma CRF con ticket aperti + pannello ticket + ticket aperti in home paziente.
#
# Va lanciato DOPO il deploy delle immagini (irccs-common rilasciato, microservizi, dashboard, httpd).
# Procede per passi, si ferma al primo errore, e ogni passo e' ripetibile (idempotente). Per ogni passo
# che SCRIVE (Keycloak, Zammad) prima mostra cosa fara' (dry-run) e chiede conferma.
#
# Passi:
#   1  controlli preliminari (strumenti, variabili, raggiungibilita')
#   2  Keycloak: ruoli internal:confirm:crf / internal:close:ticket / internal:override:ticket-gate
#   3  Keycloak: risorse e permessi del microservizio Zammad (crf-summary, by-crf, by-patient, articles, close/reopen)
#   4  Zammad: attributi personalizzati (crfscope, qrid, ...)
#   5  Zammad: webhook + trigger verso il microservizio (HMAC)
#   6  microservizio Zammad: configurazione effettiva del container (sola lettura)
#   7  HAPI: battito di sincronizzazione e Task ticket-ref (sola lettura, facoltativo)
#   8  promemoria dei passaggi MANUALI (capability ai gruppi, login, prove, attivazione del blocco)
#
# Segreti SOLO da ambiente (mai da argomento: finirebbero in history/ps):
#   ZAMMAD_TOKEN      token admin di Zammad (admin.object, admin.webhook, admin.trigger)
#   WEBHOOK_SECRET    stesso valore di ZAMMAD_WEBHOOK_SECRET del microservizio
#   ADMIN_PASS        password dell'admin Keycloak
# Variabili:
#   ZAMMAD_URL        es. https://zammad.infocube.it
#   WEBHOOK_URL       URL con cui ZAMMAD raggiunge il microservizio, es. http://irccs-zammad:8080/fhir/zammad/webhook
#   KC_URL            es. https://host/backoffice        (default http://localhost:9445)
#   REALM             default pascale
#   ADMIN_USER        default admin
#   ZAMMAD_MS_CONTAINER   nome del container del microservizio Zammad (default: il primo che contiene "microservice-zammad")
#   HAPI_URL          facoltativo, base FHIR di HAPI raggiungibile da qui (es. http://localhost:8080/fhir)
#   HAPI_AUTH         facoltativo, header completo (es. "Authorization: Bearer ...")
#
# Opzioni: --yes (non chiede conferme)   --from N (riparte dal passo N)   --only N (solo il passo N)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KC_DIR="$HERE/../../keycloak-config"
ASSUME_YES=0; FROM=1; ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --from) FROM="${2:?manca il numero}"; shift ;;
    --only) ONLY="${2:?manca il numero}"; shift ;;
    *) echo "Opzione sconosciuta: $1" >&2; exit 2 ;;
  esac
  shift
done

KC_URL="${KC_URL:-http://localhost:9445}"; REALM="${REALM:-pascale}"; ADMIN_USER="${ADMIN_USER:-admin}"
OK=0; WARN=0
say()  { printf '\n\033[1m== Passo %s: %s\033[0m\n' "$1" "$2"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; OK=$((OK+1)); }
warn() { printf '  \033[33mATT\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
die()  { printf '  \033[31mERRORE\033[0m %s\n' "$*" >&2; exit 1; }
run_step() { [ "$ONLY" -eq 0 ] && [ "$1" -ge "$FROM" ] || [ "$ONLY" -eq "$1" ]; }
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  read -r -p "  $1 [s/N] " a; [ "$a" = "s" ] || [ "$a" = "S" ]
}
need_var() { [ -n "${!1:-}" ] || die "variabile $1 non impostata"; }

# ---------------------------------------------------------------- 1
if run_step 1; then
  say 1 "controlli preliminari"
  for t in curl python3; do command -v "$t" >/dev/null || die "manca $t"; done; ok "curl e python3 presenti"
  for v in ZAMMAD_URL ZAMMAD_TOKEN WEBHOOK_SECRET WEBHOOK_URL ADMIN_PASS; do need_var "$v"; done; ok "variabili obbligatorie impostate"
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ZAMMAD_TOKEN" "${ZAMMAD_URL%/}/api/v1/users/me" || true)"
  [ "$code" = "200" ] && ok "Zammad raggiungibile e token valido" || die "Zammad: GET /users/me ha risposto $code (URL o token errati?)"
  code="$(curl -s -o /dev/null -w '%{http_code}' "${KC_URL%/}/realms/$REALM/.well-known/openid-configuration" || true)"
  [ "$code" = "200" ] && ok "Keycloak raggiungibile (realm $REALM)" || die "Keycloak: realm $REALM ha risposto $code (KC_URL errato?)"
fi

# ---------------------------------------------------------------- 2
if run_step 2; then
  say 2 "Keycloak: ruoli del blocco ticket"
  export KC_URL REALM ADMIN_USER ADMIN_PASS
  python3 "$KC_DIR/add-ticket-gate-roles.py" --dry-run
  confirm "Creo i ruoli mancanti?" && python3 "$KC_DIR/add-ticket-gate-roles.py" && ok "ruoli allineati" || warn "passo 2 saltato"
fi

# ---------------------------------------------------------------- 3
if run_step 3; then
  say 3 "Keycloak: risorse e permessi del microservizio Zammad (include by-patient)"
  export KC_URL REALM ADMIN_USER ADMIN_PASS
  # il dry-run elenca anche cio' che esiste gia' ("= ..."): si mostra solo cio' che verrebbe creato
  python3 "$KC_DIR/add-zammad-authz.py" --dry-run | grep -v '^= ' || true
  confirm "Applico le risorse/permessi mancanti?" && { python3 "$KC_DIR/add-zammad-authz.py" | grep -v '^= ' || true; } && ok "autorizzazioni allineate" || warn "passo 3 saltato"
fi

# ---------------------------------------------------------------- 4
if run_step 4; then
  say 4 "Zammad: attributi personalizzati"
  confirm "Creo gli attributi mancanti su $ZAMMAD_URL?" && "$HERE/install_zammad_attributes.sh" "$ZAMMAD_URL" && ok "attributi allineati" || warn "passo 4 saltato"
fi

# ---------------------------------------------------------------- 5
if run_step 5; then
  say 5 "Zammad: webhook e trigger"
  echo "  Zammad chiamera' $WEBHOOK_URL (deve essere raggiungibile DA Zammad, non da qui)."
  confirm "Creo webhook e trigger mancanti?" && "$HERE/install_zammad_webhook.sh" "$ZAMMAD_URL" "$WEBHOOK_URL" && ok "webhook allineato" || warn "passo 5 saltato"
fi

# ---------------------------------------------------------------- 6
if run_step 6; then
  say 6 "microservizio Zammad: configurazione effettiva"
  if ! command -v docker >/dev/null; then
    warn "docker non disponibile qui: controllo saltato (lancia il passo 6 sul server dove gira il microservizio)"
  else
    C="${ZAMMAD_MS_CONTAINER:-$(docker ps --format '{{.Names}}' | grep -i 'microservice-zammad\|irccs-zammad' | head -1 || true)}"
    [ -n "$C" ] || die "container del microservizio Zammad non trovato (imposta ZAMMAD_MS_CONTAINER)"
    echo "  container: $C   immagine: $(docker inspect -f '{{.Config.Image}}' "$C")"
    envof() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C" | sed -n "s/^$1=//p" | head -1; }
    [ "$(envof ZAMMAD_TICKET_REF_ENABLED)" = "true" ] && ok "ZAMMAD_TICKET_REF_ENABLED=true" || warn "ZAMMAD_TICKET_REF_ENABLED non e' true: nessun Task ticket-ref verra' scritto"
    [ -n "$(envof ZAMMAD_WEBHOOK_SECRET)" ] && ok "ZAMMAD_WEBHOOK_SECRET impostato" || warn "ZAMMAD_WEBHOOK_SECRET mancante: il webhook verra' rifiutato"
    [ -n "$(envof ZAMMAD_INSTANCE_ID)" ] && ok "ZAMMAD_INSTANCE_ID=$(envof ZAMMAD_INSTANCE_ID)" || warn "ZAMMAD_INSTANCE_ID non impostato (si usa il default): non cambiarlo piu' dopo l'attivazione"
    base="$(envof ZAMMAD_BASE_URL)"; [ -n "$base" ] && ok "ZAMMAD_BASE_URL=$base" || warn "ZAMMAD_BASE_URL non impostato"
    # staging/prod: il file montato legge il token da ZAMMAD_TOKEN_SERVICE; negli ambienti locali puo' essere ZAMMAD_TOKEN
    if [ -n "$(envof ZAMMAD_TOKEN_SERVICE)" ] || [ -n "$(envof ZAMMAD_TOKEN)" ]; then ok "token Zammad del servizio impostato"; else warn "token Zammad del servizio mancante (ZAMMAD_TOKEN_SERVICE)"; fi
    # il file montato /deployments/config puo' sovrascrivere gli indici del policy enforcer: il webhook deve restare escluso
    if docker exec "$C" sh -c 'grep -q "/fhir/zammad/webhook" /deployments/config/application.properties' 2>/dev/null; then ok "webhook escluso dal policy enforcer nel file montato"; elif docker exec "$C" test -f /deployments/config/application.properties 2>/dev/null; then warn "il file montato non esclude /fhir/zammad/webhook dal policy enforcer: Zammad non riuscira' a notificare (resta la riconciliazione ogni 5 minuti)"; else ok "nessun file di configurazione montato: vale quello del microservizio"; fi
    flag="$(envof CRF_CONFIRM_REQUIRE_CLOSED_TICKETS)"
    if [ "${flag:-false}" = "true" ]; then warn "il BLOCCO e' ATTIVO (CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=true) su questo container"; else ok "blocco spento (come previsto per la fase di prova)"; fi
    logs="$(docker logs --tail 2000 "$C" 2>&1 || true)"   # in variabile: grep -q chiuderebbe la pipe e pipefail darebbe un falso errore
    if grep -qi 'TicketRefSyncService' <<<"$logs"; then ok "il microservizio ha avviato la sincronizzazione ticket-ref"; else warn "nessuna traccia della sincronizzazione nei log recenti (attendi il primo ciclo di 5 minuti)"; fi
  fi
fi

# ---------------------------------------------------------------- 7
if run_step 7; then
  say 7 "HAPI: battito e Task ticket-ref"
  if [ -z "${HAPI_URL:-}" ]; then
    warn "HAPI_URL non impostato: controllo saltato"
  else
    H=(); [ -n "${HAPI_AUTH:-}" ] && H=(-H "$HAPI_AUTH")
    hb="$(curl -sf "${H[@]}" "${HAPI_URL%/}/Task?code=http://irccs.pascale.it/fhir/CodeSystem/ticket-ref%7Cticket-sync-heartbeat&_count=1&_elements=executionPeriod" || true)"
    if [ -z "$hb" ]; then warn "HAPI non risponde o accesso negato"; else
      python3 -I -c '
import sys, json, datetime
b = json.loads(sys.argv[1]); e = b.get("entry", [])
if not e: print("ATT_NOHB")
else:
    end = e[0]["resource"].get("executionPeriod", {}).get("end")
    t = datetime.datetime.fromisoformat(end.replace("Z", "+00:00")); age = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds()
    print("HB", int(age))
' "$hb" | { read -r k v; case "$k" in HB) [ "${v:-99999}" -le 600 ] && ok "battito recente (${v}s fa)" || warn "battito vecchio (${v}s): la riconciliazione non gira o fallisce";; *) warn "nessun battito: la riconciliazione non e' ancora partita (attendi 5 minuti)";; esac; }
    fi
    n="$(curl -sf "${H[@]}" "${HAPI_URL%/}/Task?code=http://irccs.pascale.it/fhir/CodeSystem/ticket-ref%7Cticket-ref&_summary=count" | python3 -I -c 'import sys,json;print(json.load(sys.stdin).get("total","?"))' || echo '?')"
    echo "  Task ticket-ref presenti: $n"
  fi
fi

# ---------------------------------------------------------------- 8
if run_step 8; then
  say 8 "passaggi manuali"
  cat <<'EOF'
  1. Dashboard -> Gruppi utenti -> sezione CRF: assegna ai gruppi scelti
       internal:confirm:crf       conferma CRF
       internal:close:ticket      chiude/riapre i ticket (chi apre un ticket non puo' chiuderlo da solo)
       internal:override:ticket-gate   deroga con motivazione (audit obbligatorio)
     Gli utenti devono rifare il login (le capability vengono dai gruppi, non dal token).
  2. Prove con il blocco SPENTO: crea un ticket da una CRF di TEST -> compare il Task ticket-ref su HAPI;
     pannello ticket (elenco, risposta, chiusura), riquadro "Open tickets" nella home paziente e icone
     su cicli/gruppi/schede. Verifica che un utente di un'altra organizzazione NON veda i ticket (403/vuoto).
  3. Accensione del blocco: CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=true sui servizi che confermano
     (studio-clinico, patient-interview) + riavvio. Attesi: 409 CRF_OPEN_TICKETS con ticket aperti, 200 dopo la
     chiusura, 503 CRF_TICKET_STATE_UNVERIFIABLE con sincronizzazione ferma oltre 10 minuti, deroga con motivo.
  4. Rollback: rimetti il flag a false e riavvia; i Task ticket-ref restano e sono innocui.
EOF
fi

printf '\nRiepilogo: %s controlli OK, %s avvisi.\n' "$OK" "$WARN"
[ "$WARN" -eq 0 ] || echo "Rivedi gli avvisi prima di passare alle prove."
