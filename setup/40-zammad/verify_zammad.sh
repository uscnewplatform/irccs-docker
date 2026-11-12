#!/usr/bin/env bash
# Controlli (sola lettura) sull'integrazione Zammad dopo l'installazione: raggiungibilità e token, attributi,
# ricerca a condizioni dei ticket (serve al blocco "Conferma CRF"), stati, configurazione del microservizio.
#
# Uso:   ZAMMAD_TOKEN=<token> ./setup/40-zammad/verify_zammad.sh <ZAMMAD_URL>
# Variabile facoltativa: ZAMMAD_MS_CONTAINER (default: primo container che contiene "microservice-zammad" o "irccs-zammad").
set -euo pipefail

[ $# -ge 1 ] && [ -n "${ZAMMAD_TOKEN:-}" ] || { echo "Uso: ZAMMAD_TOKEN=<token> $0 <ZAMMAD_URL>"; exit 1; }
URL="${1%/}"
OK=0; WARN=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; OK=$((OK+1)); }
warn() { printf '  \033[33mATT\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }
api()  { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ZAMMAD_TOKEN" "$@"; }

code="$(api "$URL/api/v1/users/me" || true)"
[ "$code" = "200" ] && ok "Zammad raggiungibile e token valido" || { warn "GET /users/me ha risposto $code (URL o token errati?)"; exit 1; }

attrs="$(curl -sf -H "Authorization: Bearer $ZAMMAD_TOKEN" "$URL/api/v1/object_manager_attributes" | python3 -I -c 'import sys,json;print(" ".join(a["name"] for a in json.load(sys.stdin) if a.get("object")=="Ticket"))' || true)"
for a in crf crfscope studyid targetgroups; do
  case " $attrs " in *" $a "*) ok "attributo Ticket.$a presente" ;; *) warn "attributo Ticket.$a mancante (lancia 40-zammad/install_zammad_attributes.sh)" ;; esac
done

code="$(api -X POST -H 'Content-Type: application/json' "$URL/api/v1/tickets/search?per_page=1" -d '{"condition":{"ticket.patient":{"operator":"is","value":"0"}}}' || true)"
[ "$code" = "200" ] && ok "ricerca ticket a condizioni: 200" || warn "ricerca a condizioni: $code (il blocco non potrà leggere i ticket)"

states="$(curl -sf -H "Authorization: Bearer $ZAMMAD_TOKEN" "$URL/api/v1/ticket_states" | python3 -I -c 'import sys,json;print(" ".join("%s=%s" % (s["id"], s["name"]) for s in json.load(sys.stdin)))' || true)"
[ -n "$states" ] && echo "  stati: $states  (uno stato personalizzato con tipo non riconosciuto BLOCCA la conferma)" || warn "elenco stati non leggibile"

hooks="$(curl -sf -H "Authorization: Bearer $ZAMMAD_TOKEN" "$URL/api/v1/webhooks" | python3 -I -c 'import sys,json;print(sum(1 for w in json.load(sys.stdin) if w.get("name","").startswith("IRCCS")))' || echo 0)"
[ "${hooks:-0}" -ge 1 ] && ok "webhook IRCCS presente (email)" || warn "webhook IRCCS assente (lancia 40-zammad/install_zammad_email_webhook.sh)"

if command -v docker >/dev/null 2>&1; then
  C="${ZAMMAD_MS_CONTAINER:-$(docker ps --format '{{.Names}}' | grep -i 'microservice-zammad\|irccs-zammad' | head -1 || true)}"
  if [ -n "$C" ]; then
    echo "  container: $C   immagine: $(docker inspect -f '{{.Config.Image}}' "$C")"
    envof() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C" | sed -n "s/^$1=//p" | head -1; }
    [ -n "$(envof ZAMMAD_BASE_URL)" ] && ok "ZAMMAD_BASE_URL impostato" || warn "ZAMMAD_BASE_URL non impostato"
    if [ -n "$(envof ZAMMAD_TOKEN_SERVICE)" ] || [ -n "$(envof ZAMMAD_TOKEN)" ]; then ok "token del servizio impostato"; else warn "token del servizio mancante (ZAMMAD_TOKEN_SERVICE)"; fi
    [ "$(envof ZAMMAD_NOTIFICATIONS_ENABLED)" = "true" ] && ok "email del microservizio abilitate" || warn "email del microservizio spente (ZAMMAD_NOTIFICATIONS_ENABLED)"
  else
    warn "container del microservizio non trovato (ZAMMAD_MS_CONTAINER)"
  fi
fi
printf '\nRiepilogo: %s controlli OK, %s avvisi.\n' "$OK" "$WARN"
