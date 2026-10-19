#!/usr/bin/env python3
"""
Aggiunge a un Keycloak GIA' AVVIATO l'autorizzazione per DocumentReference
(rotta httpd /DocumentReference -> irccs-tac /fhir/DocumentReference).

Assente nel realm-export storico: senza, solo gli admin ("Admin Resource" /fhir/*)
possono creare/leggere i template consenso, gli altri profili ricevono 403.

Crea, in modo idempotente (cio' che esiste gia' viene saltato):
  - realm role documentreference:{create,read,update,delete,search,history}
  - 4 risorse del client "irccs" (Create/Base/Search/History DocumentReference Resource)
  - 6 role policy + 7 scope permission (stessa struttura delle altre risorse)

Dopo l'esecuzione: aggiungere i ruoli documentreference:* ai profili/gruppi che devono
usarli (UI Profili: spuntare DocumentReference) e far rifare il login agli utenti.

Uso:
  KC_URL=https://host/backoffice REALM=pascale ADMIN_USER=admin ADMIN_PASS=*** \
  python3 add-documentreference-authz.py --dry-run     # solo elenco, non scrive
  python3 add-documentreference-authz.py               # applica

Variabili: KC_URL (default http://localhost:9445), REALM (pascale), CLIENT_ID (irccs),
ADMIN_USER/ADMIN_PASS, ADMIN_REALM (master). Richiede solo Python 3 (stdlib).
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

KC_URL = os.environ.get("KC_URL", "http://localhost:9445").rstrip("/")
REALM = os.environ.get("REALM", "pascale")
CLIENT_ID = os.environ.get("CLIENT_ID", "irccs")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "admin")
ADMIN_REALM = os.environ.get("ADMIN_REALM", "master")
DRY = "--dry-run" in sys.argv

T = "DocumentReference"
OPS = ["create", "read", "update", "delete", "search", "history"]
ADMIN_POLICIES = ["Admin Group Policy", "Admin Role Policy"]

RESOURCES = [
    ("Create %s Resource" % T, ["/fhir/%s" % T], ["GET", "POST"]),
    ("Base %s Resource" % T, ["/fhir/%s/{id}" % T], ["DELETE", "GET", "PUT"]),
    ("Search %s Resource" % T, ["/fhir/%s/_search" % T], ["GET"]),
    ("History %s Resource" % T, ["/fhir/%s/_history" % T, "/fhir/%s/{id}/_history" % T,
                                "/fhir/%s/{id}/_history/{id}" % T], ["GET"]),
]
# (nome permission, risorsa, scope, operazione/policy che la abilita)
PERMISSIONS = [
    ("Create %s Permission" % T, "Create %s Resource" % T, "POST", "create"),
    ("Read %s Permission" % T, "Base %s Resource" % T, "GET", "read"),
    ("Update %s Permission" % T, "Base %s Resource" % T, "PUT", "update"),
    ("Delete %s Permission" % T, "Base %s Resource" % T, "DELETE", "delete"),
    ("Search %s Permission" % T, "Search %s Resource" % T, "GET", "search"),
    ("History %s Permission" % T, "History %s Resource" % T, "GET", "history"),
    ("Search %s Permission 2" % T, "Create %s Resource" % T, "GET", "search"),
]


def policy_name(op):
    return "%s %s Policy" % (op.capitalize(), T)


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
    client = call("GET", "%s/clients?clientId=%s" % (base, urllib.parse.quote(CLIENT_ID)), tok)
    if not client:
        sys.exit("client %s non trovato nel realm %s" % (CLIENT_ID, REALM))
    rs = "%s/clients/%s/authz/resource-server" % (base, client[0]["id"])
    q = urllib.parse.quote

    print("Keycloak %s | realm %s | client %s%s" % (KC_URL, REALM, CLIENT_ID, " | DRY-RUN" if DRY else ""))

    # Le policy admin devono esistere (le usano tutte le permission).
    policies = {p["name"]: p["id"] for p in call("GET", rs + "/policy?max=2000", tok)}
    missing = [n for n in ADMIN_POLICIES if n not in policies]
    if missing:
        sys.exit("policy admin mancanti nel realm: %s" % missing)

    # 1. Realm role
    role_ids = {}
    for op in OPS:
        name = "%s:%s" % (T.lower(), op)
        role = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok, allow_404=True)
        if role:
            print("= ruolo %s" % name)
        elif DRY:
            print("+ ruolo %s (dry-run)" % name)
        else:
            call("POST", base + "/roles", tok, {
                "name": name,
                "description": "Allows you to perform a %s operation on %s." % (op, T)})
            role = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok)
            print("+ ruolo %s" % name)
        role_ids[op] = role["id"] if role else None

    # 2. Risorse
    for name, uris, scopes in RESOURCES:
        if call("GET", "%s/resource?name=%s&exact=true" % (rs, q(name)), tok):
            print("= risorsa %s" % name)
        elif DRY:
            print("+ risorsa %s (dry-run)" % name)
        else:
            call("POST", rs + "/resource", tok, {
                "name": name, "displayName": name, "type": T, "ownerManagedAccess": False,
                "uris": uris, "scopes": [{"name": s} for s in scopes]})
            print("+ risorsa %s" % name)

    # 3. Role policy
    for op in OPS:
        name = policy_name(op)
        if name in policies:
            print("= policy %s" % name)
        elif DRY:
            print("+ policy %s (dry-run)" % name)
        else:
            created = call("POST", rs + "/policy/role", tok, {
                "name": name, "logic": "POSITIVE", "decisionStrategy": "UNANIMOUS",
                "fetchRoles": True, "roles": [{"id": role_ids[op], "required": False}]})
            policies[name] = created["id"]
            print("+ policy %s" % name)

    # 4. Scope permission
    for name, resource, scope, op in PERMISSIONS:
        if name in policies:
            print("= permission %s" % name)
        elif DRY:
            print("+ permission %s (dry-run)" % name)
        else:
            call("POST", rs + "/permission/scope", tok, {
                "name": name, "logic": "POSITIVE", "decisionStrategy": "AFFIRMATIVE",
                "resources": [resource], "scopes": [scope],
                "policies": [policies[n] for n in ADMIN_POLICIES] + [policies[policy_name(op)]]})
            print("+ permission %s" % name)

    print("Fatto." if not DRY else "Dry-run completato, nulla scritto.")
    print("Ora: spuntare DocumentReference nei profili (UI Profili) e far rifare il login.")


if __name__ == "__main__":
    main()
