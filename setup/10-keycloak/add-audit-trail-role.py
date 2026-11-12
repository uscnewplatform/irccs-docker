#!/usr/bin/env python3
"""
Abilita la consultazione della cronologia attivita' (audit trail) per ruolo di gruppo, in modo idempotente:

  - realm role   internal:read:audit-trail   (si assegna ai GRUPPI dal form "Gruppi utenti": il nome del gruppo non conta)
  - realm role   internal:ui:audittrail      (voce di menu "Audit Trail": pagina trasversale, accesso pieno; di norma gia' creato dal form)
  - role policy  "Read Audit Trail Policy"  (entrambi i ruoli)
  - la policy viene aggiunta alla permission "Audit Event Log Read Permission" (GET /fhir/auth/audit-events)

Il livello grossolano di Keycloak lascia solo PASSARE la chiamata; il microservizio auth poi limita chi ha SOLO questo
ruolo alla cronologia di un singolo paziente visibile al suo gruppo/centro (admin e /auditor restano senza limiti).

Uso:
  KC_URL=http://localhost:9445 REALM=pascale ADMIN_USER=admin ADMIN_PASS=*** python3 add-audit-trail-role.py [--dry-run]

Variabili: KC_URL (default http://localhost:9445), REALM (pascale), CLIENT_ID (irccs), ADMIN_USER/ADMIN_PASS, ADMIN_REALM (master).
Richiede solo Python 3 (stdlib). Dopo l'esecuzione: spuntare il ruolo sui gruppi e far rifare il login.
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
ADMIN_PASS = os.environ.get("ADMIN_PASS", "")
if not ADMIN_PASS:
    raise SystemExit("ADMIN_PASS non impostata: la password dell'amministratore Keycloak va passata dall'ambiente (nessun default)")
ADMIN_REALM = os.environ.get("ADMIN_REALM", "master")
DRY = "--dry-run" in sys.argv

ROLE = "internal:read:audit-trail"
ROLE_DESCRIPTION = "Puo' consultare la cronologia attivita' (audit trail) dei pazienti visibili al proprio gruppo/centro"
ROLE_PAGE = "internal:ui:audittrail"
ROLE_PAGE_DESCRIPTION = "Voce di menu Audit Trail: consultazione trasversale dell'audit trail"
POLICY = "Read Audit Trail Policy"
PERMISSION = "Audit Event Log Read Permission"


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
    q = urllib.parse.quote
    client = call("GET", "%s/clients?clientId=%s" % (base, q(CLIENT_ID)), tok)
    if not client:
        sys.exit("client %s non trovato nel realm %s" % (CLIENT_ID, REALM))
    rs = "%s/clients/%s/authz/resource-server" % (base, client[0]["id"])
    print("Keycloak %s | realm %s | client %s%s" % (KC_URL, REALM, CLIENT_ID, " | DRY-RUN" if DRY else ""))

    # 1. Realm role
    roles = {}
    for name, description in ((ROLE, ROLE_DESCRIPTION), (ROLE_PAGE, ROLE_PAGE_DESCRIPTION)):
        role = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok, allow_404=True)
        if role:
            print("= ruolo %s" % name)
        elif DRY:
            print("+ ruolo %s (dry-run)" % name)
        else:
            call("POST", base + "/roles", tok, body={"name": name, "description": description})
            role = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok)
            print("+ ruolo %s" % name)
        roles[name] = role

    policies = {p["name"]: p["id"] for p in call("GET", rs + "/policy?max=2000", tok)}
    if PERMISSION not in policies:
        sys.exit("permission '%s' non trovata nel realm (realm-export non allineato?)" % PERMISSION)

    # 2. Role policy (entrambi i ruoli; se esiste gia' si completa l'elenco dei ruoli)
    wanted = [r["id"] for r in roles.values() if r]
    if POLICY in policies:
        current = call("GET", "%s/policy/role/%s" % (rs, policies[POLICY]), tok)
        have = {r["id"] for r in current.get("roles", [])}
        missing = [i for i in wanted if i not in have]
        if not missing:
            print("= policy %s" % POLICY)
        elif DRY:
            print("~ policy %s: aggiungerebbe %d ruoli (dry-run)" % (POLICY, len(missing)))
        else:
            current["roles"] = list(current.get("roles", [])) + [{"id": i, "required": False} for i in missing]
            call("PUT", "%s/policy/role/%s" % (rs, policies[POLICY]), tok, body=current)
            print("~ policy %s: aggiunti %d ruoli" % (POLICY, len(missing)))
    elif DRY:
        print("+ policy %s (dry-run)" % POLICY)
    else:
        created = call("POST", rs + "/policy/role", tok, body={
            "name": POLICY, "logic": "POSITIVE", "decisionStrategy": "AFFIRMATIVE",
            "fetchRoles": True, "roles": [{"id": i, "required": False} for i in wanted]})
        policies[POLICY] = created["id"]
        print("+ policy %s" % POLICY)

    # 3. Aggancio alla permission esistente (le policy gia' collegate restano)
    perm_id = policies[PERMISSION]
    linked = call("GET", "%s/policy/%s/associatedPolicies" % (rs, perm_id), tok) or []
    if any(p["name"] == POLICY for p in linked):
        print("= permission %s gia' collegata a %s" % (PERMISSION, POLICY))
    elif DRY:
        print("+ collegherebbe %s a %s (dry-run)" % (POLICY, PERMISSION))
    else:
        perm = call("GET", "%s/permission/scope/%s" % (rs, perm_id), tok)
        resources = [r["_id"] for r in call("GET", "%s/policy/%s/resources" % (rs, perm_id), tok) or []]
        scopes = [s["id"] for s in call("GET", "%s/policy/%s/scopes" % (rs, perm_id), tok) or []]
        perm["policies"] = [p["id"] for p in linked] + [policies[POLICY]]
        perm["resources"] = resources
        perm["scopes"] = scopes
        call("PUT", "%s/permission/scope/%s" % (rs, perm_id), tok, body=perm)
        print("+ %s collegata a %s" % (POLICY, PERMISSION))

    print("Fatto." if not DRY else "Dry-run completato, nulla scritto.")
    print("Ora: spuntare 'Cronologia attivita' sui gruppi interessati e far rifare il login.")


if __name__ == "__main__":
    main()
