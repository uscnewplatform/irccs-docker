#!/usr/bin/env python3
"""
Controlla su un Keycloak GIA' AVVIATO quali risorse FHIR instradate dal proxy non hanno
la loro autorizzazione, e crea quelle mancanti. Idempotente: non modifica mai nulla di esistente.

Perche': il realm-export di irccs-docker e' un sottoinsieme e il realm in esecuzione ha stato
proprio. Per un tipo senza risorsa dedicata la rotta cade sulla sola "Admin Resource"
(/fhir/*): solo gli admin passano, gli altri profili ricevono 403.

Per ogni tipo T controlla e, se manca, crea (stessa struttura di Encounter & co.):
  - realm role   t:{create,read,update,delete,search,history}  (nome tipo in minuscolo)
  - risorse      Create/Base/Search/History T Resource  (client "irccs")
  - role policy  {Create,Read,Update,Delete,Search,History} T Policy
  - scope permission  Create/Read/Update/Delete/Search/History T Permission + "Search T Permission 2"
Le permission includono "Admin Group Policy" e "Admin Role Policy" (devono esistere).

Dopo l'esecuzione: spuntare le risorse nei profili/gruppi (UI Profili) e far rifare il login.

Tipi da controllare (in ordine di precedenza):
  --types A,B,C        elenco esplicito
  --from-httpd FILE    rotte "ProxyPass /Tipo http://svc:8080/fhir/Tipo" di irccs.conf
  (nessuno dei due)    lista predefinita (DEFAULT_TYPES)

Uso:
  KC_URL=http://localhost:9445 REALM=pascale ADMIN_USER=admin ADMIN_PASS=*** \
  python3 sync-fhir-authz.py --check                 # solo report, exit 2 se manca qualcosa
  python3 sync-fhir-authz.py                         # crea il mancante
  python3 sync-fhir-authz.py --types ImagingStudy --from-httpd ../httpd-config/irccs.conf

Variabili: KC_URL (default http://localhost:9445), REALM (pascale), CLIENT_ID (irccs),
ADMIN_USER/ADMIN_PASS, ADMIN_REALM (master). Richiede solo Python 3 (stdlib).
Da localhost Keycloak accetta HTTP; da remoto serve HTTPS (sslRequired=external).
"""
import argparse
import json
import os
import re
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

# Tipi instradati dal proxy verso i microservizi e assenti dal realm-export di irccs-docker.
DEFAULT_TYPES = ["DocumentReference", "ImagingStudy", "DiagnosticReport", "GuidanceResponse",
                 "Person", "HealthcareService", "PractitionerRole"]
OPS = ["create", "read", "update", "delete", "search", "history"]
ADMIN_POLICIES = ["Admin Group Policy", "Admin Role Policy"]


def resources_for(t):
    return [
        ("Create %s Resource" % t, ["/fhir/%s" % t], ["GET", "POST"]),
        ("Base %s Resource" % t, ["/fhir/%s/{id}" % t], ["DELETE", "GET", "PUT"]),
        ("Search %s Resource" % t, ["/fhir/%s/_search" % t], ["GET"]),
        ("History %s Resource" % t, ["/fhir/%s/_history" % t, "/fhir/%s/{id}/_history" % t,
                                    "/fhir/%s/{id}/_history/{id}" % t], ["GET"]),
    ]


def permissions_for(t):
    # (nome permission, risorsa, scope, operazione/policy che la abilita)
    return [
        ("Create %s Permission" % t, "Create %s Resource" % t, "POST", "create"),
        ("Read %s Permission" % t, "Base %s Resource" % t, "GET", "read"),
        ("Update %s Permission" % t, "Base %s Resource" % t, "PUT", "update"),
        ("Delete %s Permission" % t, "Base %s Resource" % t, "DELETE", "delete"),
        ("Search %s Permission" % t, "Search %s Resource" % t, "GET", "search"),
        ("History %s Permission" % t, "History %s Resource" % t, "GET", "history"),
        ("Search %s Permission 2" % t, "Create %s Resource" % t, "GET", "search"),
    ]


def policy_name(op, t):
    return "%s %s Policy" % (op.capitalize(), t)


def types_from_httpd(path):
    """Tipi FHIR (iniziale maiuscola) delle ProxyPass /Tipo -> .../fhir/Tipo."""
    conf = open(path).read()
    found = re.findall(r"^\s*ProxyPass\s+/([A-Z][A-Za-z]+)\s+http://\S+?/fhir/\1\s*$", conf, re.M)
    return list(dict.fromkeys(found))


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
    ap = argparse.ArgumentParser(description="Controlla e crea le autorizzazioni FHIR mancanti")
    ap.add_argument("--check", "--dry-run", dest="dry", action="store_true",
                    help="non scrive: elenca cio' che manca (exit 2 se manca qualcosa)")
    ap.add_argument("--types", help="elenco tipi separati da virgola")
    ap.add_argument("--from-httpd", help="irccs.conf da cui ricavare i tipi")
    args = ap.parse_args()

    if args.types:
        types = [t.strip() for t in args.types.split(",") if t.strip()]
    elif args.from_httpd:
        types = types_from_httpd(args.from_httpd)
    else:
        types = DEFAULT_TYPES
    if not types:
        sys.exit("nessun tipo da controllare")

    tok = call("POST", "/realms/%s/protocol/openid-connect/token" % ADMIN_REALM, form={
        "client_id": "admin-cli", "grant_type": "password",
        "username": ADMIN_USER, "password": ADMIN_PASS})["access_token"]
    base = "/admin/realms/" + REALM
    client = call("GET", "%s/clients?clientId=%s" % (base, urllib.parse.quote(CLIENT_ID)), tok)
    if not client:
        sys.exit("client %s non trovato nel realm %s" % (CLIENT_ID, REALM))
    rs = "%s/clients/%s/authz/resource-server" % (base, client[0]["id"])
    q = urllib.parse.quote

    print("Keycloak %s | realm %s | client %s | %s" % (KC_URL, REALM, CLIENT_ID,
                                                       "CHECK (non scrive)" if args.dry else "APPLICA"))
    print("Tipi: %s\n" % ", ".join(types))

    roles = {r["name"]: r["id"] for r in call("GET", base + "/roles?max=5000", tok)}
    res_names = {r["name"] for r in call("GET", rs + "/resource?max=5000", tok)}
    policies = {p["name"]: p["id"] for p in call("GET", rs + "/policy?max=5000", tok)}
    for p in call("GET", rs + "/permission?max=5000", tok):
        policies.setdefault(p["name"], p["id"])
    missing_admin = [n for n in ADMIN_POLICIES if n not in policies]
    if missing_admin:
        sys.exit("policy admin mancanti nel realm: %s" % missing_admin)

    missing = created = 0
    for t in types:
        todo = []

        for op in OPS:
            name = "%s:%s" % (t.lower(), op)
            if name not in roles:
                todo.append("ruolo %s" % name)
                if not args.dry:
                    call("POST", base + "/roles", tok, {
                        "name": name,
                        "description": "Allows you to perform a %s operation on %s." % (op, t)})
                    roles[name] = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok)["id"]

        for name, uris, scopes in resources_for(t):
            if name not in res_names:
                todo.append("risorsa %s" % name)
                if not args.dry:
                    call("POST", rs + "/resource", tok, {
                        "name": name, "displayName": name, "type": t, "ownerManagedAccess": False,
                        "uris": uris, "scopes": [{"name": s} for s in scopes]})
                    res_names.add(name)

        for op in OPS:
            name = policy_name(op, t)
            if name not in policies:
                todo.append("policy %s" % name)
                if not args.dry:
                    policies[name] = call("POST", rs + "/policy/role", tok, {
                        "name": name, "logic": "POSITIVE", "decisionStrategy": "UNANIMOUS",
                        "fetchRoles": True,
                        "roles": [{"id": roles["%s:%s" % (t.lower(), op)], "required": False}]})["id"]

        for name, resource, scope, op in permissions_for(t):
            if name not in policies:
                todo.append("permission %s" % name)
                if not args.dry:
                    policies[name] = call("POST", rs + "/permission/scope", tok, {
                        "name": name, "logic": "POSITIVE", "decisionStrategy": "AFFIRMATIVE",
                        "resources": [resource], "scopes": [scope],
                        "policies": [policies[n] for n in ADMIN_POLICIES] + [policies[policy_name(op, t)]]
                    })["id"]

        if not todo:
            print("OK       %s" % t)
        else:
            print("%-8s %s: %d elementi" % ("MANCA" if args.dry else "CREATO", t, len(todo)))
            for item in todo:
                print("           + %s" % item)
            missing += len(todo) if args.dry else 0
            created += 0 if args.dry else len(todo)

    print()
    if args.dry:
        print("Mancano %d elementi." % missing if missing else "Niente da fare.")
        sys.exit(2 if missing else 0)
    print("Creati %d elementi." % created if created else "Niente da fare.")
    if created:
        print("Ora: spuntare i nuovi tipi nei profili (UI Profili) e far rifare il login.")


if __name__ == "__main__":
    main()
