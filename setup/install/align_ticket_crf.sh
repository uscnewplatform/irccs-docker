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
#   5  microservizio Zammad: configurazione effettiva del container (sola lettura)
#   6  Zammad: la ricerca a condizioni dei ticket funziona (sola lettura)
#   7  promemoria dei passaggi MANUALI (capability ai gruppi, login, prove, attivazione del blocco)
#
# I ticket NON si copiano in HAPI: il blocco della conferma chiede lo stato a Zammad al momento (via ms Zammad).
# Niente webhook, niente riconciliazione. Zammad non raggiungibile = conferma impossibile (503).
#
# Segreti SOLO da ambiente (mai da argomento: finirebbero in history/ps):
#   ZAMMAD_TOKEN      token admin di Zammad (admin.object per gli attributi; lettura ticket per la ricerca)
#   ADMIN_PASS        password dell'admin Keycloak
# Variabili:
#   ZAMMAD_URL        es. https://zammad.infocube.it
#   KC_URL            es. https://host/backoffice        (default http://localhost:9445)
#   REALM             default pascale
#   ADMIN_USER        default admin
#   ZAMMAD_MS_CONTAINER   nome del container del microservizio Zammad (default: il primo che contiene "microservice-zammad")
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
  for v in ZAMMAD_URL ZAMMAD_TOKEN ADMIN_PASS; do need_var "$v"; done; ok "variabili obbligatorie impostate"
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
  say 5 "microservizio Zammad: configurazione effettiva"
  if ! command -v docker >/dev/null; then
    warn "docker non disponibile qui: controllo saltato (lancia il passo 6 sul server dove gira il microservizio)"
  else
    C="${ZAMMAD_MS_CONTAINER:-$(docker ps --format '{{.Names}}' | grep -i 'microservice-zammad\|irccs-zammad' | head -1 || true)}"
    [ -n "$C" ] || die "container del microservizio Zammad non trovato (imposta ZAMMAD_MS_CONTAINER)"
    echo "  container: $C   immagine: $(docker inspect -f '{{.Config.Image}}' "$C")"
    envof() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$C" | sed -n "s/^$1=//p" | head -1; }
    base="$(envof ZAMMAD_BASE_URL)"; [ -n "$base" ] && ok "ZAMMAD_BASE_URL=$base" || warn "ZAMMAD_BASE_URL non impostato"
    # staging/prod: il file montato legge il token da ZAMMAD_TOKEN_SERVICE; negli ambienti locali puo' essere ZAMMAD_TOKEN
    if [ -n "$(envof ZAMMAD_TOKEN_SERVICE)" ] || [ -n "$(envof ZAMMAD_TOKEN)" ]; then ok "token Zammad del servizio impostato"; else warn "token Zammad del servizio mancante (ZAMMAD_TOKEN_SERVICE)"; fi
    t="$(envof ZAMMAD_TICKET_LOOKUP_TIMEOUT)"; echo "  timeout verso Zammad: ${t:-3s (default)}"
    ov="$(envof CRF_CONFIRM_OVERRIDE_WHEN_UNVERIFIABLE)"
    if [ "${ov:-false}" = "true" ]; then warn "la DEROGA vale anche con ticket non verificabili (CRF_CONFIRM_OVERRIDE_WHEN_UNVERIFIABLE=true)"; else ok "nessuna deroga con ticket non verificabili (default)"; fi
    flag="$(envof CRF_CONFIRM_REQUIRE_CLOSED_TICKETS)"
    if [ "${flag:-false}" = "true" ]; then warn "il BLOCCO e' ATTIVO (CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=true) su questo container"; else ok "blocco spento (come previsto per la fase di prova)"; fi
  fi
fi

# ---------------------------------------------------------------- 6
if run_step 6; then
  say 6 "Zammad: ricerca a condizioni dei ticket"
  # la ricerca testuale per campo (query=patient:X) senza indice non trova nulla; la ricerca a condizioni si'
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $ZAMMAD_TOKEN" -H 'Content-Type: application/json' \
    "${ZAMMAD_URL%/}/api/v1/tickets/search?per_page=1" -d '{"condition":{"ticket.patient":{"operator":"is","value":"0"}}}' || true)"
  [ "$code" = "200" ] && ok "POST tickets/search con condition risponde 200" || warn "la ricerca a condizioni ha risposto $code: il blocco non potra' leggere i ticket"
  states="$(curl -sf -H "Authorization: Bearer $ZAMMAD_TOKEN" "${ZAMMAD_URL%/}/api/v1/ticket_states" | python3 -I -c 'import sys,json;print(" ".join("%s=%s" % (s["id"], s["name"]) for s in json.load(sys.stdin)))' || true)"
  [ -n "$states" ] && echo "  stati: $states  (uno stato personalizzato con tipo non riconosciuto BLOCCA la conferma)" || warn "elenco stati non leggibile"
fi

# ---------------------------------------------------------------- 7
if run_step 7; then
  say 7 "passaggi manuali"
  cat <<'EOF'
  1. Dashboard -> Gruppi utenti -> sezione CRF: assegna ai gruppi scelti
       internal:confirm:crf       conferma CRF
       internal:close:ticket      chiude/riapre i ticket (chi apre un ticket non puo' chiuderlo da solo)
       internal:override:ticket-gate   deroga con motivazione (audit obbligatorio)
     Gli utenti devono rifare il login (le capability vengono dai gruppi, non dal token).
  2. Prove con il blocco SPENTO: crea un ticket da una CRF di TEST; pannello ticket (elenco, risposta,
     chiusura), riquadro "Open tickets" nella home paziente e icone su cicli/gruppi/schede. Verifica che un
     utente di un'altra organizzazione NON veda i ticket (403/vuoto).
  3. Accensione del blocco: CRF_CONFIRM_REQUIRE_CLOSED_TICKETS=true sui servizi che confermano
     (studio-clinico, patient-interview) + riavvio. Attesi: 409 CRF_OPEN_TICKETS con ticket aperti, 200 dopo la
     chiusura, deroga con motivo (10-500 caratteri) + capability, 503 CRF_TICKET_STATE_UNVERIFIABLE con Zammad
     fermo ("Sistema di ticket in manutenzione"), SENZA deroga (salvo CRF_CONFIRM_OVERRIDE_WHEN_UNVERIFIABLE=true).
  4. Rollback: rimetti il flag a false e riavvia; non c'e' nessun dato da ripulire.
EOF
fi

printf '\nRiepilogo: %s controlli OK, %s avvisi.\n' "$OK" "$WARN"
[ "$WARN" -eq 0 ] || echo "Rivedi gli avvisi prima di passare alle prove."
