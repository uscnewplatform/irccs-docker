#!/usr/bin/env python3
"""
Test E2E della VISIBILITA' dei ticket per gruppo (staging), con quattro utenti veri dello stesso centro:
  admin (Admins), sper (Sperimentatori), sper2 (altro sperimentatore), farmaco (Farmacovigilanza).

Regola attesa: un ticket lo vedono (elenco della CRF, elenco del paziente, "I miei ticket", conversazione) SOLO
  - il gruppo a cui e' assegnato (permesso di lettura sul gruppo Zammad),
  - chi lo ha aperto,
  - chi per ruolo vede tutta la famiglia di gruppi del centro (admin del centro).
Chi vede il paziente ma non e' in quel gruppo e non l'ha aperto NON lo vede. La conferma della CRF resta bloccata per
tutti finche' c'e' un ticket aperto (decide il server, indipendentemente da chi lo vede).

Scenari:
  V1  l'admin apre un ticket al gruppo Sperimentatori: lo vedono sper e sper2, NON lo vede farmaco;
  V2  l'admin lo apre ANCHE a Farmacovigilanza (un ticket per gruppo): ognuno vede il proprio, non quello dell'altro;
  V3  lo sperimentatore apre un ticket SOLO a Farmacovigilanza: lo vedono farmaco e chi l'ha aperto, NON sper2;
      poi Farmacovigilanza lo chiude.

Usa le funzioni di e2e_ticket_workflow.py (stessa cartella). Opzioni: --keep (non cancella i dati), --no-restart.
Il gruppo Farmacovigilanza deve avere la capability internal:close:ticket (su staging assegnata a regime il 2026-10-24).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_ticket_workflow as base  # noqa: E402  (legge il .env del server e prepara gli helper)

PATIENT, CAREPLAN, ORG = base.PATIENT, base.CAREPLAN, base.ORG
FARMACO_PATH = os.environ.get("E2E_FARMACO_PATH", "/IRCCS Istituto Nazionale Tumori/IRCCS Istituto Nazionale Tumori Farmacovigilanza")
check = base.check


def farmaco_group_id():
    import urllib.parse
    c, t = base.kc_admin("GET", "/group-by-path/" + urllib.parse.quote(FARMACO_PATH.lstrip("/"), safe="/"))
    g = base.js(t) or {}
    return g.get("id")


def sees(session, tid, qid):
    """Come vede il ticket un utente: elenco della CRF, elenco del paziente, I miei ticket, conversazione."""
    r = {}
    c, t = base.api(session, "GET", "/zammad/tickets/by-crf?patient=%s&questionnaire=%s&careplan=%s&all=true" % (PATIENT, qid, CAREPLAN))
    r["crf"] = c == 200 and any(x.get("id") == tid for x in (base.js(t) or []))
    c, t = base.api(session, "GET", "/zammad/tickets/by-patient?patient=%s&all=true" % PATIENT)
    r["paziente"] = c == 200 and any(x.get("id") == tid for x in (base.js(t) or []))
    c, t = base.api(session, "GET", "/zammad/tickets/mine?all=true")
    r["miei"] = c == 200 and any(x.get("id") == tid for x in (base.js(t) or []))
    c, t = base.api(session, "GET", "/zammad/tickets/%s/articles" % tid)
    r["conversazione"] = c == 200
    return r


def assert_sees(name, session, tid, qid, expected):
    r = sees(session, tid, qid)
    ok = all(v == expected for v in r.values())
    check("%s %s" % (name, "VEDE" if expected else "NON vede"), ok, "" if ok else r)
    return ok


def open_ticket(session, zid, group_id, qid, qr, title):
    c, t = base.api(session, "POST", "/zammad/tickets", {
        "title": title, "group_id": group_id, "customer_id": zid, "state_id": 1, "priority_id": 2,
        "crf": qid, "crfscope": "CRF", "qrid": qr, "careplan": CAREPLAN, "patient": PATIENT, "crfdisplay": "E2E",
        "careplandisplay": "E2E", "patientdisplay": "E2E", "patientjourneydisplay": "E2E", "directlink": "https://example.org/e2e",
        "article": {"body": "Verifica della visibilita' per gruppo."}})
    tid = (base.js(t) or {}).get("id")
    if tid:
        base.CREATED["tickets"].append(tid)
    return c, tid, t


def scenario():
    gid_farmaco = farmaco_group_id()
    if not check("prerequisito: gruppo Farmacovigilanza trovato", bool(gid_farmaco), FARMACO_PATH):
        return
    base.USERS["sper2"] = {"username": "e2e.sper2.%s" % base.RUN, "email": "e2e.sper2.%s@example.org" % base.RUN, "last": "Sperimentatore2", "group": base.GROUP_SPER}
    base.USERS["farmaco"] = {"username": "e2e.farmaco.%s" % base.RUN, "email": "e2e.farmaco.%s@example.org" % base.RUN, "last": "Farmacovigilanza", "group": gid_farmaco}
    caps_f = base.group_capabilities(gid_farmaco)
    print("capacita' (informativo): farmacovigilanza chiude=%s conferma=%s" % ("internal:close:ticket" in caps_f, "internal:confirm:crf" in caps_f), flush=True)

    base.create_keycloak_users()
    zids = base.wait_zammad_users_for(base.USERS.keys()) if hasattr(base, "wait_zammad_users_for") else None
    if zids is None:
        zids = base.wait_zammad_users()
    if not check("preparazione: i quattro utenti sono collegati a Zammad", len(zids) == len(base.USERS), zids):
        return
    S = {k: base.user_session(k) for k in base.USERS}
    check("preparazione: accesso dei quattro utenti riuscito", True)

    # controllo positivo: tutti vedono il paziente (altrimenti un "non vede" potrebbe dipendere dal paziente)
    for k in ("admin", "sper", "sper2", "farmaco"):
        c, _ = base.api(S[k], "GET", "/Patient/" + PATIENT, fhir=True)
        check("controllo: %s vede il paziente" % k, c == 200, c)

    c, t = base.api(S["admin"], "GET", "/zammad/tickets/groups-for-patient?patient=" + PATIENT)
    gmap = {g["label"]: g["id"] for g in (base.js(t) or [])}
    gid_sper_z = next((v for k, v in gmap.items() if "Sperimentatori" in k), None)
    gid_farm_z = next((v for k, v in gmap.items() if "Farmacovigilanza" in k), None)
    check("controllo: l'admin puo' aprire ticket ai gruppi Sperimentatori e Farmacovigilanza", bool(gid_sper_z and gid_farm_z), list(gmap))
    c, t = base.api(S["sper"], "GET", "/zammad/tickets/groups-for-patient?patient=" + PATIENT)
    smap = {g["label"]: g["id"] for g in (base.js(t) or [])}
    check("controllo: lo sperimentatore puo' aprire ticket anche a Farmacovigilanza", any("Farmacovigilanza" in k for k in smap), list(smap))

    # ---------------------------------------------------------------- V1
    q1, r1 = base.create_fhir_crf()
    c, tid1, _ = open_ticket(S["admin"], zids["admin"], gid_sper_z, q1, r1, "E2E-VIS %s V1" % base.RUN)
    check("V1. l'admin apre il ticket al gruppo Sperimentatori", c == 201 and tid1, c)
    if tid1:
        assert_sees("V1. sper (nel gruppo)", S["sper"], tid1, q1, True)
        assert_sees("V1. sper2 (nel gruppo)", S["sper2"], tid1, q1, True)
        assert_sees("V1. admin del centro", S["admin"], tid1, q1, True)
        assert_sees("V1. farmaco (altro gruppo, stesso centro)", S["farmaco"], tid1, q1, False)
        c, t = base.api(S["farmaco"], "POST", "/zammad/tickets/%s/articles" % tid1, {"body": "non dovrei poter scrivere"})
        check("V1. farmaco non puo' rispondere al ticket (403)", c == 403, c)
        c, t = base.api(S["farmaco"], "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, q1, CAREPLAN, r1))
        s = base.js(t) or {}
        check("V1. per tutti la conferma e' comunque bloccata dal ticket (il blocco non dipende da chi lo vede)", s.get("outcome") == "BLOCKED", s.get("outcome"))
        rows = s.get("tickets") or []
        check("V1. a farmaco il riepilogo non rivela titolo o testo del ticket", all(set(x.keys()) <= {"id", "status"} for x in rows), rows)

    # ---------------------------------------------------------------- V2
    q2, r2 = base.create_fhir_crf()
    c, tid2s, _ = open_ticket(S["admin"], zids["admin"], gid_sper_z, q2, r2, "E2E-VIS %s V2 sper" % base.RUN)
    c2, tid2f, _ = open_ticket(S["admin"], zids["admin"], gid_farm_z, q2, r2, "E2E-VIS %s V2 farmaco" % base.RUN)
    check("V2. l'admin apre un ticket a Sperimentatori e uno a Farmacovigilanza sulla stessa CRF", c == 201 and c2 == 201 and tid2s and tid2f, (c, c2))
    if tid2s and tid2f:
        assert_sees("V2. sper vede il suo ticket", S["sper"], tid2s, q2, True)
        assert_sees("V2. sper NON vede quello di farmaco", S["sper"], tid2f, q2, False)
        assert_sees("V2. farmaco vede il suo ticket", S["farmaco"], tid2f, q2, True)
        assert_sees("V2. farmaco NON vede quello di sper", S["farmaco"], tid2s, q2, False)
        assert_sees("V2. admin vede entrambi (1)", S["admin"], tid2s, q2, True)
        assert_sees("V2. admin vede entrambi (2)", S["admin"], tid2f, q2, True)
        c, t = base.api(S["admin"], "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, q2, CAREPLAN, r2))
        check("V2. la conferma e' bloccata da entrambi i ticket (conteggio 2)", (base.js(t) or {}).get("count") == 2, (base.js(t) or {}).get("count"))

    # ---------------------------------------------------------------- V3
    q3, r3 = base.create_fhir_crf()
    c, tid3, t3 = open_ticket(S["sper"], zids["sper"], gid_farm_z, q3, r3, "E2E-VIS %s V3 sper->farmaco" % base.RUN)
    check("V3. lo sperimentatore apre il ticket SOLO a Farmacovigilanza", c == 201 and tid3, (c, base.error_code(t3) if c != 201 else ""))
    if tid3:
        assert_sees("V3. sper (ha aperto il ticket)", S["sper"], tid3, q3, True)
        assert_sees("V3. farmaco (gruppo destinatario)", S["farmaco"], tid3, q3, True)
        assert_sees("V3. sper2 (stesso gruppo di chi l'ha aperto, ma non destinatario)", S["sper2"], tid3, q3, False)
        r = sees(S["admin"], tid3, q3)
        print("INFO V3. admin del centro: %s (atteso: vede, perche' amministra tutta la famiglia di gruppi)" % ("vede" if all(r.values()) else r), flush=True)
        c, t = base.api(S["farmaco"], "GET", "/zammad/tickets/%s/articles" % tid3)
        th = base.js(t) or {}
        can_close = th.get("canClose") is True
        print("INFO V3. farmaco puo' chiudere (capability del gruppo): %s" % can_close, flush=True)
        c, t = base.api(S["farmaco"], "POST", "/zammad/tickets/%s/close" % tid3, {"reason": "Verificato da Farmacovigilanza"})
        check("V3. Farmacovigilanza chiude il ticket", c == 200, (c, "il gruppo non ha la capability internal:close:ticket" if not can_close else ""))
        cz, tz = base.zammad("GET", "/tickets/%s" % tid3)
        z = base.js(tz) or {}
        check("V3. il ticket risulta chiuso con il segno della piattaforma", z.get("state_id") == 4 and str(z.get("crfclosure", "")).startswith("v1|"), z.get("state_id"))
        assert_sees("V3. dopo la chiusura sper2 continua a NON vederlo", S["sper2"], tid3, q3, False)


def cleanup_or_keep():
    if base.KEEP:
        print("--keep: dati di prova LASCIATI (utenti, ticket, CRF, questionari). Prefisso titoli: E2E-VIS %s" % base.RUN, flush=True)
        return
    base.cleanup()


if __name__ == "__main__":
    try:
        scenario()
    except SystemExit as e:
        check("esecuzione", False, e)
    except Exception as e:
        check("esecuzione", False, type(e).__name__)
    finally:
        cleanup_or_keep()
    print("RISULTATO %d/%d" % (sum(base.RESULTS), len(base.RESULTS)))
    sys.exit(0 if all(base.RESULTS) else 1)
