#!/usr/bin/env python3
"""
Aggiunge a un Keycloak GIA' AVVIATO l'autorizzazione per il microservizio Zammad
(rotta httpd /zammad -> irccs-zammad /fhir/zammad/{users,groups,organizations,roles,tickets}).

Assente nel realm-export: senza, solo gli admin ("Admin Resource" /fhir/*) possono
usare la parte Zammad, gli altri profili ricevono 403 dalla policy enforcer.

Per ognuna delle 5 entita' crea, in modo idempotente (cio' che esiste gia' viene saltato):
  - realm role zammad<entita'>:{create,read,update,delete,search}
  - risorse del client "irccs" (Create/Base/Search <Entita'> Resource; per i ticket anche MyTicket)
  - role policy + scope permission (stessa struttura delle altre risorse)

Dopo l'esecuzione: aggiungere i ruoli zammad*:* ai profili/gruppi che devono usarli
(UI Profili) e far rifare il login agli utenti.

Uso:
  KC_URL=https://host/backoffice REALM=pascale ADMIN_USER=admin ADMIN_PASS=*** \
  python3 add-zammad-authz.py --dry-run     # solo elenco, non scrive
  python3 add-zammad-authz.py               # applica
  python3 add-zammad-authz.py --delete --dry-run   # elenca cosa verrebbe rimosso
  python3 add-zammad-authz.py --delete             # rimuove tutto cio' che crea lo script

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
DELETE = "--delete" in sys.argv


ADMIN_POLICIES = ["Admin Group Policy", "Admin Role Policy"]
OPS = ["create", "read", "update", "delete", "search"]

# (tipo, path REST sotto /fhir/zammad, nome ruolo/policy)
TYPES = [
    ("ZammadUser", "users"),
    ("ZammadGroup", "groups"),
    ("ZammadOrganization", "organizations"),
    ("ZammadRole", "roles"),
    ("ZammadTicket", "tickets"),
]


def role_name(t, op):
    return "%s:%s" % (t.lower(), op)


def policy_name(t, op):
    return "%s %s Policy" % (op.capitalize(), t)


def build(t, path):
    """Risorse e permission di un tipo. Ogni endpoint del controller e' coperto."""
    base = "/fhir/zammad/%s" % path
    resources = [
        ("Create %s Resource" % t, [base], ["GET", "POST"]),
        ("Base %s Resource" % t, [base + "/{id}"], ["DELETE", "PUT"]),
        ("Search %s Resource" % t, [base + "/search"], ["GET"]),
    ]
    perms = [
        ("Create %s Permission" % t, "Create %s Resource" % t, "POST", "create"),
        ("Read %s Permission" % t, "Create %s Resource" % t, "GET", "read"),
        ("Update %s Permission" % t, "Base %s Resource" % t, "PUT", "update"),
        ("Delete %s Permission" % t, "Base %s Resource" % t, "DELETE", "delete"),
        ("Search %s Permission" % t, "Search %s Resource" % t, "GET", "search"),
    ]
    if t == "ZammadTicket":
        # GET /tickets/{userId}/myTicket
        resources.append(("MyTicket %s Resource" % t, [base + "/{id}/myTicket"], ["GET"]))
        perms.append(("MyTicket %s Permission" % t, "MyTicket %s Resource" % t, "GET", "read"))
        # GET /tickets/crf-summary?patient=&careplan=&questionnaire= (stato dei ticket di una CRF per la dashboard)
        resources.append(("CrfSummary %s Resource" % t, [base + "/crf-summary"], ["GET"]))
        perms.append(("CrfSummary %s Permission" % t, "CrfSummary %s Resource" % t, "GET", "read"))
        # GET /tickets/open-for-gate (ticket non chiusi di una CRF, per il blocco della conferma degli altri microservizi).
        # Serve una risorsa PROPRIA: senza, il percorso e' catturato da "Base ... /{id}" (che non ha lo scope GET) e
        # nemmeno il service account passa. Il permesso e' solo per le policy admin (op None): lo chiamano i
        # microservizi con il service account, nessun ruolo zammadticket:* lo abilita.
        resources.append(("OpenForGate %s Resource" % t, [base + "/open-for-gate"], ["GET"]))
        perms.append(("OpenForGate %s Permission" % t, "OpenForGate %s Resource" % t, "GET", None))
        # Gestione dei ticket di una CRF dentro la piattaforma: elenco, conversazione, risposta, chiusura/riapertura.
        resources.append(("ByCrf %s Resource" % t, [base + "/by-crf"], ["GET"]))
        # GET /tickets/by-patient?patient= (ticket aperti di tutte le CRF del paziente, per la home paziente)
        resources.append(("ByPatient %s Resource" % t, [base + "/by-patient"], ["GET"]))
        resources.append(("Articles %s Resource" % t, [base + "/{id}/articles"], ["GET", "POST"]))
        resources.append(("StateChange %s Resource" % t, [base + "/{id}/close", base + "/{id}/reopen", base + "/{id}/validate-closure"], ["POST"]))
        perms.append(("ByCrf %s Permission" % t, "ByCrf %s Resource" % t, "GET", "read"))
        perms.append(("ByPatient %s Permission" % t, "ByPatient %s Resource" % t, "GET", "read"))
        perms.append(("ReadArticles %s Permission" % t, "Articles %s Resource" % t, "GET", "read"))
        perms.append(("ReplyArticles %s Permission" % t, "Articles %s Resource" % t, "POST", "update"))
        perms.append(("StateChange %s Permission" % t, "StateChange %s Resource" % t, "POST", "update"))
    return resources, perms


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


def remove(rs, base, tok, policies):
    """Inverso di main(): permission -> policy -> risorse -> ruoli (ordine di dipendenza)."""
    q = urllib.parse.quote
    for t, path in TYPES:
        resources, permissions = build(t, path)
        names = [n for n, _, _, _ in permissions] + [policy_name(t, op) for op in OPS]
        for name in names:
            if name in policies:
                if not DRY:
                    call("DELETE", "%s/policy/%s" % (rs, policies[name]), tok)
                print("- policy/permission %s%s" % (name, " (dry-run)" if DRY else ""))
        for name, _, _ in resources:
            found = call("GET", "%s/resource?name=%s&exact=true" % (rs, q(name)), tok)
            for r in found or []:
                if not DRY:
                    call("DELETE", "%s/resource/%s" % (rs, r["_id"]), tok)
                print("- risorsa %s%s" % (name, " (dry-run)" if DRY else ""))
        for op in OPS:
            name = role_name(t, op)
            if call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok, allow_404=True):
                if not DRY:
                    call("DELETE", "%s/roles/%s" % (base, q(name, safe="")), tok)
                print("- ruolo %s%s" % (name, " (dry-run)" if DRY else ""))
    print("Rimozione completata." if not DRY else "Dry-run completato, nulla rimosso.")


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

    if DELETE:
        remove(rs, base, tok, policies)
        return

    for t, path in TYPES:
        resources, permissions = build(t, path)
        print("--- %s (/fhir/zammad/%s)" % (t, path))

        # 1. Realm role
        role_ids = {}
        for op in OPS:
            name = role_name(t, op)
            role = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok, allow_404=True)
            if role:
                print("= ruolo %s" % name)
            elif DRY:
                print("+ ruolo %s (dry-run)" % name)
            else:
                call("POST", base + "/roles", tok, {
                    "name": name,
                    "description": "Allows you to perform a %s operation on %s." % (op, t)})
                role = call("GET", "%s/roles/%s" % (base, q(name, safe="")), tok)
                print("+ ruolo %s" % name)
            role_ids[op] = role["id"] if role else None

        # 2. Risorse
        for name, uris, scopes in resources:
            existing = call("GET", "%s/resource?name=%s&exact=true" % (rs, q(name)), tok)
            if existing:
                # risorsa gia' presente: se mancano percorsi (versioni successive dello script) si aggiungono
                current = call("GET", "%s/resource/%s" % (rs, existing[0]["_id"]), tok)
                missing = [u for u in uris if u not in (current.get("uris") or [])]
                if missing and not DRY:
                    current["uris"] = list(current.get("uris") or []) + missing
                    call("PUT", "%s/resource/%s" % (rs, existing[0]["_id"]), tok, current)
                    print("~ risorsa %s: aggiunti %s" % (name, missing))
                elif missing:
                    print("~ risorsa %s: aggiungerebbe %s (dry-run)" % (name, missing))
                else:
                    print("= risorsa %s" % name)
            elif DRY:
                print("+ risorsa %s (dry-run)" % name)
            else:
                call("POST", rs + "/resource", tok, {
                    "name": name, "displayName": name, "type": t, "ownerManagedAccess": False,
                    "uris": uris, "scopes": [{"name": s} for s in scopes]})
                print("+ risorsa %s" % name)

        # 3. Role policy
        for op in OPS:
            name = policy_name(t, op)
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
        for name, resource, scope, op in permissions:
            if name in policies:
                print("= permission %s" % name)
            elif DRY:
                print("+ permission %s (dry-run)" % name)
            else:
                created = call("POST", rs + "/permission/scope", tok, {
                    "name": name, "logic": "POSITIVE", "decisionStrategy": "AFFIRMATIVE",
                    "resources": [resource], "scopes": [scope],
                    "policies": [policies[n] for n in ADMIN_POLICIES] + ([policies[policy_name(t, op)]] if op else [])})
                policies[name] = created["id"] if created else name
                print("+ permission %s" % name)

    print("Fatto." if not DRY else "Dry-run completato, nulla scritto.")
    print("Ora: assegnare i ruoli zammad*:* ai profili/gruppi e far rifare il login.")


if __name__ == "__main__":
    main()
