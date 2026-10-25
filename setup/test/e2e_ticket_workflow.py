#!/usr/bin/env python3
"""
Test E2E del flusso ticket <-> CRF su un ambiente (staging), con DUE UTENTI VERI.

Scenario (come lo userebbero le persone):
  1. un admin del centro apre un ticket su una CRF (priorita' alta) scegliendo un gruppo del centro del paziente;
  2. uno sperimentatore dello stesso centro vede il ticket; finche' e' aperto la CRF non si conferma (409);
  3. lo sperimentatore modifica la CRF e risponde al ticket «attivita' svolta»;
  4. l'admin vede la risposta; lo sperimentatore NON puo' chiudere, l'admin si, con motivo;
  5. l'admin conferma la CRF (ora passa) e la CRF risulta confermata.

Cosa fa: crea due utenti temporanei su Keycloak (password casuali, generate a ogni esecuzione, MAI stampate o salvate)
nei gruppi indicati, una CRF di prova su un paziente indicato, esegue lo scenario chiamando le API come farebbe la
dashboard (httpd -> microservizi), e alla fine CANCELLA tutto (utenti Keycloak e Zammad, ticket, risorse FHIR).

Va lanciato sul server dell'ambiente (legge i segreti dal .env e parla con httpd/Keycloak/HAPI in locale):
    python3 -I e2e_ticket_workflow.py [--keep] [--no-restart]

Variabili d'ambiente OBBLIGATORIE: E2E_PATIENT (id del paziente di prova) ed E2E_CAREPLAN (CarePlan modello); opzionali: E2E_ADMIN_GROUP, E2E_SPER_GROUP, E2E_ORG.
"""
import base64
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
ENV = {}
for _l in open(HOME + "/irccs-docker/.env"):
    if "=" in _l and not _l.lstrip().startswith("#") and " " not in _l.split("=")[0].strip():
        _k, _v = _l.rstrip("\n").split("=", 1)
        ENV[_k.strip()] = _v.strip().strip('"')

REALM = ENV.get("KEYCLOAK_REALM") or "pascale"
PATIENT = os.environ.get("E2E_PATIENT", "")
CAREPLAN = os.environ.get("E2E_CAREPLAN", "")
if not PATIENT or not CAREPLAN:
    raise SystemExit("Impostare E2E_PATIENT ed E2E_CAREPLAN: nessun default, per non creare ticket su un paziente reale per sbaglio")
ORG = os.environ.get("E2E_ORG", "9ec10f85-ad24-426c-ab2b-b6a74c4c08e1")           # radice del centro (IRCCS)
GROUP_ADMIN = os.environ.get("E2E_ADMIN_GROUP", "1689f3a0-22d6-4e97-ade8-034753fe23c4")   # Admins del centro
GROUP_SPER = os.environ.get("E2E_SPER_GROUP", "772b0cec-87c2-4f39-8d7c-66a83eb11ee0")     # Sperimentatori del centro
KEEP = "--keep" in sys.argv
NO_RESTART = "--no-restart" in sys.argv

RUN = secrets.token_hex(3)
PASSWORD = secrets.token_urlsafe(18) + "aA1!"          # mai stampata, mai salvata
USERS = {
    "admin": {"username": "e2e.admin.%s" % RUN, "email": "e2e.admin.%s@example.org" % RUN, "last": "Admin", "group": GROUP_ADMIN},
    "sper": {"username": "e2e.sper.%s" % RUN, "email": "e2e.sper.%s@example.org" % RUN, "last": "Sperimentatore", "group": GROUP_SPER},
}
RESULTS = []
CREATED = {"kc_users": [], "zammad_users": [], "tickets": [], "fhir": []}


# ---------------------------------------------------------------------------------------------- utilita'
def check(name, ok, info=""):
    RESULTS.append(bool(ok))
    print(("OK   " if ok else "FAIL ") + name + (" - " + str(info) if info != "" else ""), flush=True)
    return bool(ok)


def http(method, url, body=None, headers=None, timeout=60, raw=False):
    h = {"Accept": "application/json"}
    data = None
    if body is not None:
        if raw:
            data = body
        else:
            data = json.dumps(body).encode()
            h["Content-Type"] = "application/json"
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # rete, timeout
        return 0, str(e)


def js(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


KC = "http://localhost:9445"
KC_HOST = {"Host": "irccs-keycloak:8080"}
HTTPD = "http://localhost"
HAPI = "http://localhost:8080/fhir"
ZIP = sh("docker inspect zammad-ticketing_zammad-nginx_1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' | cut -d' ' -f1")
ZAMMAD_TOKEN = open(HOME + "/ticket-crf-align/.zammad-token").read().strip()


def kc_admin_token():
    form = urllib.parse.urlencode({"grant_type": "password", "client_id": "admin-cli",
                                   "username": ENV["KEYCLOAK_ADMIN"], "password": ENV["KEYCLOAK_ADMIN_PASSWORD"]}).encode()
    r = urllib.request.Request(KC + "/realms/master/protocol/openid-connect/token", data=form)
    return json.loads(urllib.request.urlopen(r, timeout=30).read())["access_token"]


def kc_admin(method, path, body=None):
    return http(method, KC + "/admin/realms/%s%s" % (REALM, path), body, {"Authorization": "Bearer " + kc_admin_token()})


def zammad_remove_user(zid):
    """Cancella un utente Zammad. Con riferimenti (creato dal sync) il DELETE da' 422: si usa l'attivita' di
    privacy dei dati di Zammad (cancella l'utente e quanto lo riguarda); in extremis lo si disattiva."""
    c, _ = zammad("DELETE", "/users/%s" % zid)
    if c in (200, 204, 404):
        return True
    c, _ = zammad("POST", "/data_privacy_tasks", {"deletable_type": "User", "deletable_id": zid})
    if c in (200, 201):
        return True
    c, _ = zammad("PUT", "/users/%s" % zid, {"active": False})
    return c == 200


def zammad(method, path, body=None):
    return http(method, "http://%s:8080/api/v1%s" % (ZIP, path), body, {"Authorization": "Bearer " + ZAMMAD_TOKEN}, timeout=120)


def hapi(method, path, body=None):
    c, t = http(method, HAPI + "/" + path, body, {"Content-Type": "application/fhir+json", "Accept": "application/fhir+json"})
    return c, js(t)


def user_session(key):
    """Accesso come l'utente: token, token di contesto del gruppo e intestazioni come le manda la dashboard."""
    u = USERS[key]
    form = urllib.parse.urlencode({"grant_type": "password", "client_id": ENV["KEYCLOAK_CLIENT_ID"], "client_secret": ENV["KEYCLOAK_CLIENT_SECRET"],
                                   "username": u.get("login", u["username"]), "password": PASSWORD}).encode()
    r = urllib.request.Request(KC + "/realms/%s/protocol/openid-connect/token" % REALM, data=form, headers=KC_HOST)
    try:
        tok = json.loads(urllib.request.urlopen(r, timeout=30).read())["access_token"]
    except urllib.error.HTTPError as e:
        raise SystemExit("accesso di %s non riuscito (HTTP %s)" % (u["username"], e.code))
    c, t = http("POST", HTTPD + "/auth/users/context", {"mode": "group", "groupId": u["group"], "organizationId": ORG}, {"Authorization": "Bearer " + tok})
    ctx = (js(t) or {}).get("token")
    if not ctx:
        raise SystemExit("contesto di %s non ottenuto (HTTP %s)" % (u["username"], c))
    return {"Authorization": "Bearer " + tok, "X-Context-Token": ctx, "X-Active-Group": u["group"]}


def api(session, method, path, body=None, fhir=False):
    h = dict(session)
    if fhir:
        h["Content-Type"] = "application/fhir+json"
        h["Accept"] = "application/fhir+json"
    return http(method, HTTPD + path, body, h, timeout=90)


def error_code(text):
    b = js(text) or {}
    try:
        return b["issue"][0]["details"]["coding"][0]["code"]
    except Exception:
        return b.get("error", "") if isinstance(b, dict) else ""


# ---------------------------------------------------------------------------------------------- preparazione
def create_keycloak_users():
    for key, u in USERS.items():
        body = {"username": u["username"], "email": u["email"], "firstName": "E2E", "lastName": u["last"], "enabled": True,
                "emailVerified": True, "credentials": [{"type": "password", "value": PASSWORD, "temporary": False}]}
        c, t = kc_admin("POST", "/users", body)
        if c != 201:
            raise SystemExit("utente %s non creato (HTTP %s)" % (u["username"], c))
        found = kc_find_user(u["email"])
        if not found:
            raise SystemExit("utente %s creato ma non ritrovato" % u["email"])
        u["id"] = found["id"]
        # il realm assegna ai nuovi utenti azioni richieste (es. configurare il TOTP) che bloccano l'accesso con password
        kc_admin("PUT", "/users/%s" % found["id"], {"requiredActions": [], "enabled": True, "emailVerified": True})
        u["login"] = found["username"]          # con "email come username" coincide con l'email
        CREATED["kc_users"].append(u["id"])
        c, _ = kc_admin("PUT", "/users/%s/groups/%s" % (u["id"], u["group"]))
        check("preparazione: utente %s creato e nel gruppo" % key, c in (200, 204), c)


def kc_find_user(email):
    """Utente per email esatta (il realm puo' usare l'email come username)."""
    c, t = kc_admin("GET", "/users?email=%s&exact=true" % urllib.parse.quote(email))
    rows = js(t) if c == 200 else None
    return rows[0] if isinstance(rows, list) and rows else None


def group_capabilities(group_id):
    c, t = kc_admin("GET", "/groups/%s/role-mappings/realm" % group_id)
    return {r["name"] for r in (js(t) or [])}


def create_fhir_crf():
    c, q = hapi("POST", "Questionnaire", {"resourceType": "Questionnaire", "status": "active", "title": "ZZ-E2E ticket %s" % RUN,
                                          "item": [{"linkId": "a", "text": "Valore", "type": "string"}]})
    CREATED["fhir"].append("Questionnaire/" + q["id"])
    c, r = hapi("POST", "QuestionnaireResponse", {
        "resourceType": "QuestionnaireResponse", "status": "in-progress", "questionnaire": "Questionnaire/" + q["id"],
        "subject": {"reference": "Patient/" + PATIENT}, "basedOn": [{"reference": "CarePlan/" + CAREPLAN}],
        "item": [{"linkId": "a", "answer": [{"valueString": "valore iniziale"}]}]})
    CREATED["fhir"].append("QuestionnaireResponse/" + r["id"])
    return q["id"], r["id"]


def wait_zammad_users():
    """Il sync Keycloak->Zammad crea gli utenti e ne imposta keycloak_ref e i gruppi: si aspetta che ci siano."""
    if not NO_RESTART:
        sh("docker restart irccs-zammad >/dev/null 2>&1")      # il sync parte all'avvio del ms
    deadline = time.time() + 600
    ids = {}
    while time.time() < deadline and len(ids) < len(USERS):
        for key, u in USERS.items():
            if key in ids:
                continue
            c, t = zammad("GET", "/users/search?query=%s&limit=5" % urllib.parse.quote(u["email"]))
            for z in (js(t) or []):
                if isinstance(z, dict) and (z.get("email") or "").lower() == u["email"].lower() and z.get("keycloak_ref") and z.get("group_ids"):
                    ids[key] = z["id"]
                    CREATED["zammad_users"].append(z["id"])
        time.sleep(10)
    return ids


# ---------------------------------------------------------------------------------------------- scenario
def scenario():
    caps_admin = group_capabilities(GROUP_ADMIN)
    caps_sper = group_capabilities(GROUP_SPER)
    print("capacita' (informativo): admin chiude=%s conferma=%s | sperimentatore chiude=%s conferma=%s" % (
        "internal:close:ticket" in caps_admin, "internal:confirm:crf" in caps_admin,
        "internal:close:ticket" in caps_sper, "internal:confirm:crf" in caps_sper), flush=True)
    check("prerequisito: il gruppo admin puo' chiudere i ticket", "internal:close:ticket" in caps_admin)
    check("prerequisito: il gruppo sperimentatori NON puo' chiudere i ticket", "internal:close:ticket" not in caps_sper)
    check("prerequisito: il gruppo admin puo' confermare le CRF", "internal:confirm:crf" in caps_admin)

    create_keycloak_users()
    qid, qr = create_fhir_crf()
    zids = wait_zammad_users()
    if not check("preparazione: i due utenti sono collegati a Zammad (sync)", len(zids) == 2, zids):
        return
    admin, sper = user_session("admin"), user_session("sper")
    check("preparazione: accesso dei due utenti riuscito", True)

    # 1) l'admin vede solo i gruppi del centro e apre il ticket
    c, t = api(admin, "GET", "/zammad/tickets/groups-for-patient?patient=" + PATIENT)
    groups = js(t) or []
    labels = [g.get("label") for g in groups] if isinstance(groups, list) else []
    check("1. l'admin vede solo i gruppi del centro del paziente", c == 200 and len(groups) > 0 and all("ASL" not in (l or "") for l in labels), (c, labels))
    sper_gid = next((g["id"] for g in groups if "Sperimentatori" in (g.get("label") or "")), groups[0]["id"] if groups else 7)
    c, t = api(admin, "POST", "/zammad/tickets", {
        "title": "E2E %s: dato da verificare" % RUN, "group_id": sper_gid, "customer_id": zids["admin"], "state_id": 1, "priority_id": 3,
        "crf": qid, "crfscope": "CRF", "qrid": qr, "careplan": CAREPLAN, "patient": PATIENT, "crfdisplay": "E2E", "careplandisplay": "E2E",
        "patientdisplay": "E2E", "patientjourneydisplay": "E2E", "directlink": "https://example.org/e2e",
        "article": {"body": "Controllare il valore inserito nella CRF."}})
    tid = (js(t) or {}).get("id")
    if tid:
        CREATED["tickets"].append(tid)
    check("1. l'admin apre il ticket sulla CRF (priorita' alta)", c == 201 and tid, (c, tid))
    if not tid:
        return
    c, t = zammad("GET", "/tickets/%s" % tid)
    check("1. il ticket e' salvato con priorita' alta e gruppo del centro", (js(t) or {}).get("priority_id") == 3 and (js(t) or {}).get("group_id") == sper_gid)

    # 2) lo sperimentatore lo vede; con il ticket aperto non conferma
    c, t = api(sper, "GET", "/zammad/tickets/by-crf?patient=%s&questionnaire=%s&careplan=%s" % (PATIENT, qid, CAREPLAN))
    check("2. lo sperimentatore vede il ticket sulla CRF", c == 200 and any(x.get("id") == tid for x in (js(t) or [])), c)
    c, t = api(sper, "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, qid, CAREPLAN, qr))
    s = js(t) or {}
    check("2. il riepilogo dice che la conferma e' bloccata", c == 200 and s.get("outcome") == "BLOCKED" and s.get("count") == 1, (c, s.get("outcome"), s.get("count")))
    cq, body = hapi("GET", "QuestionnaireResponse/" + qr)
    body["status"] = "completed"
    c, t = api(sper, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    # lo sperimentatore, se il suo gruppo non ha la capability di conferma, e' fermato dal permesso (403) prima ancora che dal ticket (409)
    expected = 403 if "internal:confirm:crf" not in caps_sper else 409
    check("2. lo sperimentatore non puo' confermare la CRF (%s)" % expected, c == expected, (c, error_code(t)))
    cq, now = hapi("GET", "QuestionnaireResponse/" + qr)
    check("2. la CRF resta in compilazione dopo il tentativo dello sperimentatore", now.get("status") == "in-progress", now.get("status"))
    c, t = api(admin, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    check("2. anche l'admin, con il ticket aperto, e' fermato dal blocco (409 CRF_OPEN_TICKETS)", c == 409 and error_code(t) == "CRF_OPEN_TICKETS", (c, error_code(t)))

    # 3) lo sperimentatore modifica la CRF e risponde al ticket
    cq, body = hapi("GET", "QuestionnaireResponse/" + qr)
    body["item"][0]["answer"][0]["valueString"] = "valore corretto dallo sperimentatore"
    c, t = api(sper, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    cq, now = hapi("GET", "QuestionnaireResponse/" + qr)
    check("3. lo sperimentatore modifica la CRF (resta in compilazione)", c == 200 and now["status"] == "in-progress"
          and now["item"][0]["answer"][0]["valueString"].startswith("valore corretto"), (c, now.get("status")))
    c, t = api(sper, "POST", "/zammad/tickets/%s/articles" % tid, {"body": "Attivita' svolta: ho corretto il valore nella CRF."})
    check("3. lo sperimentatore risponde al ticket «attivita' svolta»", c in (200, 201), c)

    # 4) l'admin vede la risposta; chiusura: solo con la capability
    c, t = api(admin, "GET", "/zammad/tickets/%s/articles" % tid)
    thread = js(t) or {}
    texts = [a.get("body", "") for a in thread.get("articles", [])]
    check("4. l'admin vede la risposta dello sperimentatore", c == 200 and any("Attivita' svolta" in x for x in texts), c)
    check("4. l'admin puo' chiudere, lo sperimentatore no (canClose)", thread.get("canClose") is True)
    c, t = api(sper, "POST", "/zammad/tickets/%s/close" % tid, {"reason": "Chiuso dallo sperimentatore"})
    check("4. lo sperimentatore NON puo' chiudere il ticket (403)", c == 403, c)
    c, t = api(admin, "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, qid, CAREPLAN, qr))
    check("4. prima della chiusura la conferma e' ancora bloccata", (js(t) or {}).get("outcome") == "BLOCKED")
    c, t = api(admin, "POST", "/zammad/tickets/%s/close" % tid, {"reason": "Verificato: attivita' svolta dallo sperimentatore"})
    check("4. l'admin chiude il ticket con il motivo", c == 200, c)
    c, t = zammad("GET", "/tickets/%s" % tid)
    z = js(t) or {}
    check("4. il ticket e' chiuso con il segno di chiusura della piattaforma", z.get("state_id") == 4 and str(z.get("crfclosure", "")).startswith("v1|"), (z.get("state_id"), str(z.get("crfclosure", ""))[:3]))

    # 5) l'admin conferma la CRF
    c, t = api(admin, "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, qid, CAREPLAN, qr))
    check("5. dopo la chiusura il riepilogo e' libero", (js(t) or {}).get("outcome") == "CLEAR", (js(t) or {}).get("outcome"))
    cq, body = hapi("GET", "QuestionnaireResponse/" + qr)
    body["status"] = "completed"
    c, t = api(admin, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    cq, now = hapi("GET", "QuestionnaireResponse/" + qr)
    check("5. l'admin conferma la CRF e risulta confermata", c == 200 and now["status"] == "completed", (c, error_code(t), now.get("status")))


# ---------------------------------------------------------------------------------------------- pulizia
def cleanup():
    if KEEP:
        print("--keep: pulizia saltata", flush=True)
        return
    errs = []
    for tid in CREATED["tickets"]:
        c, _ = zammad("DELETE", "/tickets/%s" % tid)
        if c not in (200, 204, 404):
            errs.append("ticket %s (%s)" % (tid, c))
    for ref in reversed(CREATED["fhir"]):
        c, _ = hapi("DELETE", ref)
        if c not in (200, 204, 404, 410):
            errs.append("%s (%s)" % (ref, c))
    for zid in CREATED["zammad_users"]:
        if not zammad_remove_user(zid):
            errs.append("utente Zammad %s" % zid)
    for u in USERS.values():
        found = kc_find_user(u["email"])                 # anche se la creazione si e' interrotta a meta'
        uid = u.get("id") or (found or {}).get("id")
        if uid:
            c, _ = kc_admin("DELETE", "/users/%s" % uid)
            if c not in (200, 204, 404):
                errs.append("utente Keycloak %s (%s)" % (u["email"], c))
    for key, u in USERS.items():                         # utenti Zammad creati dal sync, anche se non tracciati
        c, t = zammad("GET", "/users/search?query=%s&limit=5" % urllib.parse.quote(u["email"]))
        for z in (js(t) or []):
            if isinstance(z, dict) and (z.get("email") or "").lower() == u["email"].lower() and z["id"] not in CREATED["zammad_users"]:
                zammad_remove_user(z["id"])
    print("pulizia: " + ("completa" if not errs else "incompleta -> " + ", ".join(errs)), flush=True)


if __name__ == "__main__":
    try:
        scenario()
    except SystemExit as e:
        check("esecuzione", False, e)
    except Exception as e:  # nessuna traccia con dati sensibili
        check("esecuzione", False, type(e).__name__)
    finally:
        cleanup()
    print("RISULTATO %d/%d" % (sum(RESULTS), len(RESULTS)))
    sys.exit(0 if all(RESULTS) else 1)
