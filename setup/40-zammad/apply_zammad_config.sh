#!/usr/bin/env bash
# Applica a un Zammad nuovo la configurazione salvata in setup/40-zammad/config/ che gli altri script NON coprono:
#   - stato ticket "annuncio" (le news di studio)
#   - trigger "Ticket - presa in carico alla risposta" (new / pending reminder -> open alla prima risposta)
#   - impostazioni: fuso orario, mittente delle email, registrazione utenti spenta
#   - (con EMAIL_FROM) indirizzo mittente e assegnazione a tutti i gruppi + notification_sender
#   - (con --disable-low-priority) priorita' "1 low" disattivata
# Attributi, webhook, trigger e job delle email, spegnimento dei trigger nativi: li fanno gli altri script di questa cartella.
#
# Uso:
#   ZAMMAD_TOKEN=<token admin> ./setup/40-zammad/apply_zammad_config.sh <ZAMMAD_URL> [--apply] [--disable-low-priority]
#                                                                       [--no-takeover-trigger] [--no-settings]
#   --no-takeover-trigger  non crea il trigger "presa in carico alla risposta" (scelta di processo: new/pending -> open alla prima risposta)
#   --no-settings          non tocca le impostazioni (fuso, mittente, registrazione utenti): utile se il cliente ha gia' le sue
# I trigger/job nativi che mandavano email li spegne disable_zammad_native_emails.sh (nomi di fabbrica inclusi).
#   Variabili facoltative: EMAIL_FROM=noreply@cliente.it  EMAIL_FROM_NAME="CLIENTE - Ticket"  ZAMMAD_TIMEZONE=Europe/Rome
#
# Senza --apply elenca soltanto. Idempotente: cio' che c'e' gia' non si tocca. Il token e' letto dall'ambiente e non compare mai in output.
# Dopo che il microservizio Zammad ha sincronizzato i gruppi (centri nuovi) rilanciare con EMAIL_FROM per assegnare l'indirizzo ai gruppi nuovi.
# Il canale SMTP e il login SSO (credenziali) restano manuali: vedi config/README.md.
set -euo pipefail

if [ $# -lt 1 ] || [ -z "${ZAMMAD_TOKEN:-}" ]; then
  echo "Uso: ZAMMAD_TOKEN=<token> $0 <ZAMMAD_URL> [--apply] [--disable-low-priority] [--no-takeover-trigger] [--no-settings]"
  exit 1
fi
API="${1%/}"; API="${API%/api/v1}/api/v1"; shift
APPLY=no; LOW=no; NO_TRIGGER=no; NO_SETTINGS=no
for a in "$@"; do
  case "$a" in
    --apply) APPLY=yes ;;
    --disable-low-priority) LOW=yes ;;
    --no-takeover-trigger) NO_TRIGGER=yes ;;
    --no-settings) NO_SETTINGS=yes ;;
    *) echo "Opzione sconosciuta: $a" >&2; exit 2 ;;
  esac
done
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export API APPLY LOW NO_TRIGGER NO_SETTINGS CONFIG_DIR="$HERE/config" ZAMMAD_TOKEN
export EMAIL_FROM="${EMAIL_FROM:-}" EMAIL_FROM_NAME="${EMAIL_FROM_NAME:-}" ZAMMAD_TIMEZONE="${ZAMMAD_TIMEZONE:-}"

python3 -I - <<'PY'
import json, os, sys, urllib.request, urllib.error

API, APPLY, LOW, CFG = os.environ["API"], os.environ["APPLY"] == "yes", os.environ["LOW"] == "yes", os.environ["CONFIG_DIR"]
NO_TRIGGER, NO_SETTINGS = os.environ["NO_TRIGGER"] == "yes", os.environ["NO_SETTINGS"] == "yes"
TOKEN = os.environ["ZAMMAD_TOKEN"]

def call(method, path, body=None):
    req = urllib.request.Request(f"{API}/{path}", method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"ERRORE: {method} {path} -> HTTP {e.code}")
    except Exception as e:
        sys.exit(f"ERRORE: {method} {path} non riuscita ({type(e).__name__})")

def load(name):
    with open(os.path.join(CFG, name), encoding="utf-8") as f:
        return json.load(f)

def todo(msg, action=None):
    if action is None:
        print(f"gia' a posto : {msg}")
    elif APPLY:
        action()
        print(f"fatto        : {msg}")
    else:
        print(f"da fare      : {msg}")

# ---- stati ticket
states = call("GET", "ticket_states")
by_name = {s["name"]: s for s in states}
for s in load("ticket-states.json")["states"]:
    if s["name"] in by_name:
        sid = by_name[s["name"]]["id"]
        todo(f"stato '{s['name']}' (id {sid})")
        if sid != 7:
            print(f"             ATTENZIONE: id {sid} diverso da 7: imposta VITE_APP_ZAMMAD_TICKET_ANNUNCE_STATE_ID={sid} nella dashboard")
        continue
    nxt = by_name.get(s["next_state"])
    if not nxt:
        sys.exit(f"ERRORE: stato '{s['next_state']}' non trovato")
    body = {k: s[k] for k in ("name", "state_type_id", "ignore_escalation", "default_create", "default_follow_up", "active", "note")}
    body["next_state_id"] = nxt["id"]
    todo(f"crea stato '{s['name']}'", lambda b=body: call("POST", "ticket_states", b))
    print("             nota: l'id del nuovo stato va in VITE_APP_ZAMMAD_TICKET_ANNUNCE_STATE_ID della dashboard (default 7); rilancia senza --apply per leggerlo")

# ---- trigger personalizzati (i nativi li spegne disable_zammad_native_emails.sh)
triggers = call("GET", "triggers")
tby = {t["name"]: t for t in triggers}
cfg = load("triggers.json")
for t in ([] if NO_TRIGGER else cfg["custom"]):
    if t["name"] in tby:
        todo(f"trigger '{t['name']}' (id {tby[t['name']]['id']})")
    else:
        todo(f"crea trigger '{t['name']}'", lambda b=t: call("POST", "triggers", b))

# ---- impostazioni
settings = {s["name"]: s for s in call("GET", "settings")}
want = dict(load("settings.json")["applica"])
if os.environ.get("ZAMMAD_TIMEZONE"):
    want["timezone_default"] = os.environ["ZAMMAD_TIMEZONE"]
if os.environ["EMAIL_FROM"]:
    name = os.environ["EMAIL_FROM_NAME"] or "Ticket"
    want["notification_sender"] = f'"{name}" <{os.environ["EMAIL_FROM"]}>'
for k, v in ({} if NO_SETTINGS else want).items():
    s = settings.get(k)
    if s is None:
        print(f"non trovata  : impostazione {k}")
    elif s["state_current"].get("value") == v:
        todo(f"impostazione {k}")
    else:
        todo(f"imposta {k}", lambda i=s["id"], v=v: call("PUT", f"settings/{i}", {"state_current": {"value": v}}))

# ---- indirizzo mittente e gruppi
if os.environ["EMAIL_FROM"]:
    addr = os.environ["EMAIL_FROM"].lower()
    ea = {a["email"].lower(): a for a in call("GET", "email_addresses")}
    if addr in ea:
        eid = ea[addr]["id"]
        todo(f"indirizzo mittente (id {eid})")
    else:
        eid = None
        def make():
            global eid
            eid = call("POST", "email_addresses", {"name": os.environ["EMAIL_FROM_NAME"] or "Ticket", "email": addr, "active": True})["id"]
        todo("crea indirizzo mittente", make)
    n = 0
    for g in call("GET", "groups"):
        if g.get("active") and not g.get("email_address_id"):
            n += 1
            if APPLY and eid:
                call("PUT", f"groups/{g['id']}", {"email_address_id": eid})
    print(f"{'assegnati' if APPLY else 'da assegnare'}: {n} gruppi senza indirizzo mittente")
else:
    print("saltato      : indirizzo mittente (imposta EMAIL_FROM e EMAIL_FROM_NAME per crearlo e assegnarlo ai gruppi)")

# ---- priorita' bassa
if LOW:
    for p in call("GET", "ticket_priorities"):
        if p["name"] == "1 low":
            if p.get("active"):
                todo("disattiva priorita' '1 low'", lambda i=p["id"]: call("PUT", f"ticket_priorities/{i}", {"active": False}))
            else:
                todo("priorita' '1 low' disattiva")

if not APPLY:
    print("Nessuna modifica fatta: aggiungere --apply per applicare.")
PY
