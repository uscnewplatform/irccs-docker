#!/usr/bin/env python3
"""
Crea (idempotente) i ruoli realm usati dal blocco "Conferma CRF" per ticket aperti:

  - internal:override:ticket-gate  conferma una CRF nonostante ticket aperti o non verificabili
                                   (motivazione obbligatoria, audit obbligatorio)
  - internal:close:ticket          chiude e riapre i ticket di una CRF (chi li apre non puo' chiuderli da solo)
  - internal:confirm:crf           conferma una CRF (se manca nel realm)

Sono capability da assegnare ai GRUPPI (form "Gruppi utenti" -> sezione CRF): il nome del gruppo non conta mai.
Dopo l'esecuzione assegnare il ruolo ai gruppi dei responsabili e far rifare il login agli utenti.

Uso:
  KC_URL=http://localhost:9445 REALM=pascale ADMIN_USER=admin ADMIN_PASS=*** python3 add-ticket-gate-roles.py [--dry-run]

Variabili: KC_URL (default http://localhost:9445), REALM (pascale), ADMIN_USER/ADMIN_PASS, ADMIN_REALM (master).
Richiede solo Python 3 (stdlib).
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

KC_URL = os.environ.get("KC_URL", "http://localhost:9445").rstrip("/")
REALM = os.environ.get("REALM", "pascale")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "")
if not ADMIN_PASS:
    raise SystemExit("ADMIN_PASS non impostata: la password dell'amministratore Keycloak va passata dall'ambiente (nessun default)")
ADMIN_REALM = os.environ.get("ADMIN_REALM", "master")
DRY = "--dry-run" in sys.argv

ROLES = [
    ("internal:confirm:crf", "Puo' confermare una CRF"),
    ("internal:close:ticket",
     "Puo' chiudere e riaprire i ticket di una CRF (chi ha solo aperto il ticket o vi ha risposto non puo')"),
    ("internal:override:ticket-gate",
     "Puo' confermare una CRF nonostante ticket aperti o non verificabili (motivazione e audit obbligatori)"),
    ("internal:manage:center-tickets",
     "Admin del centro: vede e gestisce i ticket di tutti i gruppi del centro (il sync da' full su tutta la famiglia di gruppi Zammad). Assegnarlo ai gruppi Admins"),
]


def call(method, path, token=None, body=None, form=None, allow_404=False):
    data, headers = None, {}
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(KC_URL + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if allow_404 and e.code == 404:
            return None
        sys.exit("ERRORE %s %s -> %s %s" % (method, path, e.code, e.read().decode()[:300]))


def main():
    tok = call("POST", "/realms/%s/protocol/openid-connect/token" % ADMIN_REALM, form={
        "client_id": "admin-cli", "grant_type": "password",
        "username": ADMIN_USER, "password": ADMIN_PASS})["access_token"]
    base = "/admin/realms/" + REALM
    for name, description in ROLES:
        path = "%s/roles/%s" % (base, urllib.parse.quote(name, safe=""))
        if call("GET", path, tok, allow_404=True):
            print("= ruolo %s gia' presente, salto" % name)
            continue
        if not DRY:
            call("POST", base + "/roles", tok, body={"name": name, "description": description})
        print("+ ruolo %s%s" % (name, " (dry-run)" if DRY else ""))
    print("Fatto." if not DRY else "Dry-run completato, nulla scritto.")


if __name__ == "__main__":
    main()
