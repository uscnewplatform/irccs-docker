#!/usr/bin/env python3
"""
Test E2E (staging) del blocco dei ticket sulle SAE e della deroga, con utenti veri (Keycloak temporanei, cancellati alla fine):

  D0  deroga sulla conferma di una CRF (motivo corto 422, valido 200) con il ruolo internal:override:ticket-gate;
  S1  SAE con medico indicato: nasce il diritto di firma gia' abilitato (stato «accepted», il medico puo' firmare);
  S2  ticket (query) aperto sulla SAE: il medico NON puo' firmare (409 CRF_OPEN_TICKETS, nessuna OTP); deroga senza ruolo 403;
      deroga con motivo corto 422; deroga valida: parte la sfida OTP;
  S3  ticket chiuso: il medico firma con l'OTP letto da Mailpit;
  S4  ticket aperto DOPO la firma: la SAE resta firmata;
  S5  SAE corretta dopo la firma: firma non piu' corrente, nuovo diritto in attesa; con il ticket aperto NON si abilita (409),
      con deroga valida si abilita; con il ticket aperto la nuova firma e' bloccata; chiuso il ticket si puo' firmare.

I ruoli (deroga ai gruppi Admins e Sperimentatori, abilitazione SAE ai soli Admins) vengono assegnati ai gruppi SOLO per la
durata del test e tolti alla fine, anche in caso di errore. Il flag CRF_CONFIRM_REQUIRE_CLOSED_TICKETS deve essere acceso.
Le email vanno su Mailpit (staging): niente posta reale.

Usa e2e_ticket_workflow.py ed e2e_ticket_extra.py (stessa cartella). Variabili d'ambiente OBBLIGATORIE: E2E_PATIENT ed E2E_CAREPLAN.
Opzioni: --keep, --no-restart.
    E2E_PATIENT=<id> E2E_CAREPLAN=<id> python3 -I e2e_ticket_sae.py --no-restart
"""
import os
import re
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_ticket_extra as ex  # noqa: E402  (importa anche e2e_ticket_workflow come base)

base = ex.base
check, js, api, hapi = base.check, base.js, base.api, base.hapi
PATIENT, CAREPLAN = base.PATIENT, base.CAREPLAN
ROLE_OVERRIDE = "internal:override:ticket-gate"
ROLE_ENABLE_SAE = "internal:enable:sae-signature"
HEADER = "X-Ticket-Gate-Override-Reason"
REASON_OK = "Deroga di prova automatica del test E2E sulle SAE"
GRANTED = []   # (gruppo, nome ruolo, oggetto ruolo) assegnati dal test: da togliere alla fine
SAE_BASE = "/patients/sae-signature/"


# ---------------------------------------------------------------------------------------------- ruoli temporanei
def grant_role(group_id, role_name):
    if role_name in base.group_capabilities(group_id):
        return False
    c, t = base.kc_admin("GET", "/roles/" + urllib.parse.quote(role_name, safe=""))
    role = js(t)
    c, _ = base.kc_admin("POST", "/groups/%s/role-mappings/realm" % group_id, [role])
    if c in (200, 204):
        GRANTED.append((group_id, role_name, role))
        return True
    return False


def revoke_granted():
    for group_id, role_name, role in reversed(GRANTED):
        c, _ = base.kc_admin("DELETE", "/groups/%s/role-mappings/realm" % group_id, [role])
        still = role_name in base.group_capabilities(group_id)
        print("ruolo %s tolto dal gruppo %s: %s" % (role_name, group_id[:8], "ok" if (c in (200, 204) and not still) else "DA CONTROLLARE (%s)" % c), flush=True)
    GRANTED.clear()


# ---------------------------------------------------------------------------------------------- fixture e utilita'
def create_sae(physician_email):
    c, p = hapi("POST", "Practitioner", {"resourceType": "Practitioner", "name": [{"family": "ZZ-E2E-%s" % base.RUN, "given": ["Medico"]}],
                                         "telecom": [{"system": "email", "value": physician_email}]})
    base.CREATED["fhir"].append("Practitioner/" + p["id"])
    c, q = hapi("POST", "Questionnaire", {
        "resourceType": "Questionnaire", "status": "active", "title": "ZZ-E2E SAE %s" % base.RUN,
        "identifier": [{"system": "SAE", "value": "zz-e2e-%s" % base.RUN}],
        "item": [{"linkId": "descrizione", "text": "Descrizione", "type": "string"},
                 {"linkId": "medico", "text": "Medico che riporta l'evento", "type": "reference",
                  "extension": [{"url": "http://example.org/fhir/StructureDefinition/practitioner-select", "valueBoolean": True}]}]})
    base.CREATED["fhir"].append("Questionnaire/" + q["id"])
    return p["id"], q["id"]


def post_sae_response(session, qid, pid):
    c, t = api(session, "POST", "/QuestionnaireResponse", {
        "resourceType": "QuestionnaireResponse", "status": "in-progress", "questionnaire": "Questionnaire/" + qid,
        "subject": {"reference": "Patient/" + PATIENT}, "basedOn": [{"reference": "CarePlan/" + CAREPLAN}],
        "item": [{"linkId": "descrizione", "answer": [{"valueString": "evento avverso di prova"}]},
                 {"linkId": "medico", "answer": [{"valueReference": {"reference": "Practitioner/" + pid}}]}]}, fhir=True)
    qr = (js(t) or {}).get("id")
    if qr:
        base.CREATED["fhir"].append("QuestionnaireResponse/" + qr)
    return c, qr


def sae_state(session, qr):
    c, t = api(session, "GET", SAE_BASE + qr)
    return c, (js(t) or {})


def sae_call(session, qr, action, headers=None, body=None):
    s = dict(session)
    s.update(headers or {})
    c, t = api(s, "POST", SAE_BASE + qr + "/" + action, body if body is not None else {})
    b = js(t) or {}
    return c, (b.get("code") if isinstance(b, dict) else None), b


def override(reason):
    return {HEADER: "utf8-uri:" + urllib.parse.quote(reason, safe="")}


def mailpit_ids(email):
    c, t = base.http("GET", "http://localhost:8025/api/v1/search?query=" + urllib.parse.quote("to:" + email) + "&limit=20")
    return [m["ID"] for m in (js(t) or {}).get("messages", [])]


def mailpit_otp(email, before):
    for _ in range(30):
        for mid in mailpit_ids(email):
            if mid in before:
                continue
            c, t = base.http("GET", "http://localhost:8025/api/v1/message/" + mid)
            m = re.search(r"\n\s*(\d{6})\s*\n", (js(t) or {}).get("Text", ""))
            if m:
                return m.group(1)
        time.sleep(2)
    return None


def close_ticket(session, tid, reason="Query risolta (prova automatica)"):
    c, t = api(session, "POST", "/zammad/tickets/%s/close" % tid, {"reason": reason})
    return c


# ---------------------------------------------------------------------------------------------- scenario
def scenario():
    if not ex.flag_value():
        raise SystemExit("il flag CRF_CONFIRM_REQUIRE_CLOSED_TICKETS deve essere acceso: lo script prova il blocco")
    # ruoli temporanei: deroga a Admins e Sperimentatori, abilitazione SAE ai soli Admins
    g1 = grant_role(base.GROUP_ADMIN, ROLE_OVERRIDE)
    g2 = grant_role(base.GROUP_ADMIN, ROLE_ENABLE_SAE)
    g3 = grant_role(base.GROUP_SPER, ROLE_OVERRIDE)
    print("ruoli temporanei assegnati: deroga admin=%s abilitazione-SAE admin=%s deroga sper=%s (False = gia' presente)" % (g1, g2, g3), flush=True)
    check("preparazione: l'admin ha deroga e abilitazione SAE", {ROLE_OVERRIDE, ROLE_ENABLE_SAE} <= base.group_capabilities(base.GROUP_ADMIN))

    base.create_keycloak_users()
    pid, sae_qid = create_sae(base.USERS["sper"]["email"])
    qid0, qr0 = base.create_fhir_crf()
    zids = base.wait_zammad_users()
    if not check("preparazione: i due utenti sono collegati a Zammad (sync)", len(zids) == 2, zids):
        return
    admin, sper = base.user_session("admin"), base.user_session("sper")
    c, t = api(admin, "GET", "/zammad/tickets/groups-for-patient?patient=" + PATIENT)
    groups = js(t) or []
    gid = next((g["id"] for g in groups if "Sperimentatori" in (g.get("label") or "")), groups[0]["id"] if groups else 7)

    # D0 deroga sulla conferma di una CRF
    c, tid0 = ex.open_crf_ticket(admin, zids["admin"], gid, qid0, qr0, "E2E %s: deroga CRF" % base.RUN)
    check("D0. l'admin apre un ticket sulla CRF", c == 201 and tid0, (c, tid0))
    c, code, st = ex.confirm(admin, qr0)
    check("D0. senza deroga la conferma e' fermata (409 CRF_OPEN_TICKETS)", c == 409 and code == "CRF_OPEN_TICKETS", (c, code))
    c, code, st = ex.confirm(admin, qr0, {HEADER: "corto"})
    check("D0. deroga con motivo troppo corto: 422 CRF_OVERRIDE_REASON_INVALID", c == 422 and code == "CRF_OVERRIDE_REASON_INVALID", (c, code))
    c, code, st = ex.confirm(admin, qr0, override(REASON_OK))
    check("D0. deroga valida con il ruolo: la conferma passa (200)", c == 200 and st == "completed", (c, code, st))

    # S1 SAE con medico indicato
    c, qr = post_sae_response(admin, sae_qid, pid)
    check("S1. l'admin salva la SAE con il medico indicato", c in (200, 201) and qr, (c, qr))
    if not qr:
        return
    time.sleep(3)   # il diritto di firma si crea dopo la scrittura
    c, s = sae_state(sper, qr)
    check("S1. il diritto di firma e' gia' abilitato e il medico puo' firmare", c == 200 and s.get("status") == "accepted" and s.get("canSign") is True, (c, s.get("status"), s.get("canSign")))

    # S2 ticket aperto sulla SAE: la firma e' bloccata
    c, tid1 = ex.open_crf_ticket(admin, zids["admin"], gid, sae_qid, qr, "E2E %s: query SAE" % base.RUN)
    check("S2. la farmacovigilanza (admin) apre una query sulla SAE", c == 201 and tid1, (c, tid1))
    out = ex.summary(sper, sae_qid, qr)
    check("S2. il riepilogo della SAE e' BLOCKED", out.get("outcome") == "BLOCKED", out.get("outcome"))
    before = set(mailpit_ids(base.USERS["sper"]["email"]))
    c, code, b = sae_call(sper, qr, "sign")
    check("S2. il medico non firma: 409 CRF_OPEN_TICKETS", c == 409 and code == "CRF_OPEN_TICKETS", (c, code))
    check("S2. nessun codice OTP e' stato inviato", set(mailpit_ids(base.USERS["sper"]["email"])) == before)
    c, code, b = sae_call(sper, qr, "sign", override("corto"))
    check("S2. deroga con motivo corto: 422", c == 422 and code == "CRF_OVERRIDE_REASON_INVALID", (c, code))
    c, code, b = sae_call(sper, qr, "sign", override(REASON_OK))
    ok_challenge = c == 202
    check("S2. deroga valida con il ruolo: parte la sfida OTP (202)", ok_challenge, (c, code))
    if ok_challenge:
        otp = mailpit_otp(base.USERS["sper"]["email"], before)
        check("S2. il codice OTP arriva su Mailpit", otp is not None)
        c, code, b = sae_call(sper, qr, "sign", {**override(REASON_OK), "X-OTP-Code": "000000"})
        check("S2. codice errato con deroga: 417", c == 417, (c, code))

    # S3 ticket chiuso: firma regolare con l'OTP
    check("S3. la query viene chiusa", close_ticket(admin, tid1) == 200)
    out = ex.summary(sper, sae_qid, qr)
    check("S3. il riepilogo della SAE e' libero", out.get("outcome") == "CLEAR", out.get("outcome"))
    before = set(mailpit_ids(base.USERS["sper"]["email"]))
    c, code, b = sae_call(sper, qr, "sign")
    check("S3. il medico avvia la firma (202, sfida OTP)", c == 202, (c, code))
    otp = mailpit_otp(base.USERS["sper"]["email"], before)
    check("S3. il codice OTP arriva su Mailpit", otp is not None)
    if otp:
        c, code, b = sae_call(sper, qr, "sign", {"X-OTP-Code": otp})
        check("S3. la SAE e' firmata (200)", c == 200 and b.get("status") == "signed", (c, code, b.get("status")))

    # S4 ticket aperto dopo la firma: la SAE resta firmata
    c, tid2 = ex.open_crf_ticket(admin, zids["admin"], gid, sae_qid, qr, "E2E %s: query dopo firma" % base.RUN)
    check("S4. una nuova query dopo la firma", c == 201 and tid2, (c, tid2))
    c, s = sae_state(sper, qr)
    check("S4. la SAE resta firmata", s.get("status") == "signed" and (s.get("signature") or {}).get("current") is True, (s.get("status"), (s.get("signature") or {}).get("current")))

    # S5 SAE corretta dopo la firma: nuova abilitazione e nuova firma
    cq, body = hapi("GET", "QuestionnaireResponse/" + qr)
    body["item"][0]["answer"][0]["valueString"] = "evento avverso corretto dopo la firma"
    c, t = api(admin, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    check("S5. la SAE e' sempre modificabile (anche con il ticket aperto)", c == 200, c)
    time.sleep(3)
    c, s = sae_state(admin, qr)
    check("S5. la firma non e' piu' corrente e serve una nuova abilitazione", s.get("status") == "requested" and s.get("canEnable") is True, (s.get("status"), s.get("canEnable")))
    c, code, b = sae_call(admin, qr, "enable")
    check("S5. con il ticket aperto la nuova abilitazione e' bloccata (409 CRF_OPEN_TICKETS)", c == 409 and code == "CRF_OPEN_TICKETS", (c, code))
    c, code, b = sae_call(admin, qr, "enable", override("corto"))
    check("S5. abilitazione con deroga e motivo corto: 422", c == 422 and code == "CRF_OVERRIDE_REASON_INVALID", (c, code))
    c, code, b = sae_call(sper, qr, "enable", override(REASON_OK))
    check("S5. chi non ha il ruolo di abilitazione non abilita (403)", c == 403, (c, code))
    c, code, b = sae_call(admin, qr, "enable", override(REASON_OK))
    check("S5. abilitazione con deroga valida e ruolo (200, accepted)", c == 200 and b.get("status") == "accepted", (c, code, b.get("status")))
    c, code, b = sae_call(sper, qr, "sign")
    check("S5. con il ticket ancora aperto la nuova firma e' bloccata (409)", c == 409 and code == "CRF_OPEN_TICKETS", (c, code))
    check("S5. la query viene chiusa", close_ticket(admin, tid2) == 200)
    before = set(mailpit_ids(base.USERS["sper"]["email"]))
    c, code, b = sae_call(sper, qr, "sign")
    check("S5. chiuso il ticket la nuova firma parte (202, sfida OTP)", c == 202, (c, code))
    otp = mailpit_otp(base.USERS["sper"]["email"], before)
    if otp:
        c, code, b = sae_call(sper, qr, "sign", {"X-OTP-Code": otp})
        check("S5. la SAE e' firmata di nuovo (200)", c == 200 and b.get("status") == "signed", (c, code, b.get("status")))


def search_ids(resource_type, query):
    c, t = base.http("GET", "%s/%s?%s&_count=50&_elements=id" % (base.HAPI, resource_type, query), None, {"Accept": "application/fhir+json"})
    return [e["resource"]["id"] for e in (js(t) or {}).get("entry", [])]


def delete_dependents(refs):
    """Provenance e Task che puntano alla SAE di prova e appartenenze a gruppi del medico di prova: senza, HAPI rifiuta le cancellazioni (409)."""
    for ref in refs:
        if ref.startswith("QuestionnaireResponse/"):
            for pid in search_ids("Provenance", "target=" + ref):
                hapi("DELETE", "Provenance/" + pid)
            for tid in search_ids("Task", "focus=" + ref):
                hapi("DELETE", "Task/" + tid)
        elif ref.startswith("Practitioner/"):
            for gid in search_ids("Group", "member=" + ref):
                c, g = hapi("GET", "Group/" + gid)
                if isinstance(g, dict) and g.get("member"):
                    g["member"] = [m for m in g["member"] if (m.get("entity") or {}).get("reference") != ref]
                    hapi("PUT", "Group/" + gid, g)


if __name__ == "__main__":
    try:
        scenario()
    except SystemExit as e:
        check("esecuzione", False, e)
    except Exception as e:  # nessuna traccia con dati sensibili
        check("esecuzione", False, type(e).__name__)
    finally:
        try:
            revoke_granted()
        finally:
            if not base.KEEP:
                delete_dependents(list(base.CREATED["fhir"]))
            base.cleanup()
    print("RISULTATO %d/%d" % (sum(base.RESULTS), len(base.RESULTS)))
    sys.exit(0 if all(base.RESULTS) else 1)
