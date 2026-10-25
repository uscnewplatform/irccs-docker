#!/usr/bin/env python3
"""
Test E2E su staging: due ticket aperti da uno sperimentatore a Farmacovigilanza, con utenti veri (Keycloak temporanei).

  R1  lo sperimentatore apre il ticket a Farmacovigilanza; Farmacovigilanza risponde e lo chiude; la CRF si conferma.
  R2  lo sperimentatore apre il ticket a Farmacovigilanza; Farmacovigilanza risponde; risponde e chiude anche l'admin
      del centro (che vede tutti i ticket del centro); la CRF si conferma.

Prerequisiti sul server: ruolo internal:close:ticket su Farmacovigilanza e internal:manage:center-tickets sul gruppo Admins.
Usa e2e_ticket_workflow.py e e2e_ticket_visibility.py (stessa cartella). Opzioni: --keep (non cancella i dati), --no-restart.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_ticket_visibility as vis  # noqa: E402

base = vis.base
check = base.check
PATIENT, CAREPLAN = base.PATIENT, base.CAREPLAN


def texts(session, tid):
    c, t = base.api(session, "GET", "/zammad/tickets/%s/articles" % tid)
    th = base.js(t) or {}
    return c, [a.get("body", "") for a in th.get("articles", [])], th


def summary_outcome(session, qid, qr):
    c, t = base.api(session, "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, qid, CAREPLAN, qr))
    return (base.js(t) or {}).get("outcome")


def closed_with_mark(tid):
    cz, tz = base.zammad("GET", "/tickets/%s" % tid)
    z = base.js(tz) or {}
    return z.get("state_id") == 4 and str(z.get("crfclosure", "")).startswith("v1|"), z.get("state_id")


def confirm_crf(session, qr):
    cq, body = base.hapi("GET", "QuestionnaireResponse/" + qr)
    body["status"] = "completed"
    c, t = base.api(session, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    cq, now = base.hapi("GET", "QuestionnaireResponse/" + qr)
    return c, now.get("status"), base.error_code(t)


def scenario():
    gid_farmaco = vis.farmaco_group_id()
    if not check("prerequisito: gruppo Farmacovigilanza trovato", bool(gid_farmaco), vis.FARMACO_PATH):
        return
    base.USERS["farmaco"] = {"username": "e2e.farmaco.%s" % base.RUN, "email": "e2e.farmaco.%s@example.org" % base.RUN,
                             "last": "Farmacovigilanza", "group": gid_farmaco}
    check("prerequisito: Farmacovigilanza puo' chiudere i ticket", "internal:close:ticket" in base.group_capabilities(gid_farmaco))
    check("prerequisito: gli admin del centro gestiscono i ticket di tutto il centro",
          "internal:manage:center-tickets" in base.group_capabilities(base.GROUP_ADMIN))
    base.create_keycloak_users()
    zids = base.wait_zammad_users()
    if not check("preparazione: gli utenti sono collegati a Zammad", len(zids) == len(base.USERS), zids):
        return
    S = {k: base.user_session(k) for k in base.USERS}
    c, t = base.api(S["sper"], "GET", "/zammad/tickets/groups-for-patient?patient=" + PATIENT)
    gid_farm_z = next((g["id"] for g in (base.js(t) or []) if "Farmacovigilanza" in g["label"]), None)
    check("preparazione: lo sperimentatore puo' aprire ticket a Farmacovigilanza", bool(gid_farm_z))
    if not gid_farm_z:
        return

    for n, label in (("R1", "chiude Farmacovigilanza"), ("R2", "rispondono e chiude anche l'admin")):
        q, r = base.create_fhir_crf()
        c, tid, t = vis.open_ticket(S["sper"], zids["sper"], gid_farm_z, q, r, "E2E-ROLES %s %s" % (base.RUN, n))
        if not check("%s. lo sperimentatore apre il ticket SOLO a Farmacovigilanza (%s)" % (n, label), c == 201 and tid, (c, base.error_code(t))):
            continue
        vis.assert_sees("%s. farmaco (gruppo destinatario)" % n, S["farmaco"], tid, q, True)
        vis.assert_sees("%s. sper (ha aperto)" % n, S["sper"], tid, q, True)
        check("%s. con il ticket aperto la conferma e' bloccata" % n, summary_outcome(S["admin"], q, r) == "BLOCKED")

        c, _ = base.api(S["farmaco"], "POST", "/zammad/tickets/%s/articles" % tid, {"body": "%s: Farmacovigilanza ha verificato la segnalazione." % n})
        check("%s. Farmacovigilanza risponde al ticket" % n, c in (200, 201), c)
        c, _ = base.api(S["sper"], "POST", "/zammad/tickets/%s/close" % tid, {"reason": "Chiusura dallo sperimentatore"})
        check("%s. lo sperimentatore NON puo' chiudere (403)" % n, c == 403, c)

        if n == "R1":
            c, _ = base.api(S["farmaco"], "POST", "/zammad/tickets/%s/close" % tid, {"reason": "R1: valutazione di farmacovigilanza completata"})
            check("R1. Farmacovigilanza chiude il ticket", c == 200, c)
        else:
            c, tx, th = texts(S["admin"], tid)
            check("R2. l'admin del centro vede la risposta di Farmacovigilanza", c == 200 and any("Farmacovigilanza ha verificato" in x for x in tx), c)
            check("R2. l'admin del centro puo' rispondere e chiudere (canWrite, canClose)", th.get("canClose") is True)
            c, _ = base.api(S["admin"], "POST", "/zammad/tickets/%s/articles" % tid, {"body": "R2: l'admin del centro conferma la presa in carico."})
            check("R2. l'admin risponde al ticket", c in (200, 201), c)
            c, _ = base.api(S["admin"], "POST", "/zammad/tickets/%s/close" % tid, {"reason": "R2: chiuso dall'admin dopo la risposta di Farmacovigilanza"})
            check("R2. l'admin chiude il ticket", c == 200, c)

        ok, state = closed_with_mark(tid)
        check("%s. il ticket risulta chiuso con il segno firmato della piattaforma" % n, ok, state)
        c, tx, _ = texts(S["sper"], tid)
        want = ["Farmacovigilanza ha verificato"] + (["conferma la presa in carico"] if n == "R2" else [])
        check("%s. lo sperimentatore legge la conversazione completa" % n, c == 200 and all(any(w in x for x in tx) for w in want), (c, len(tx)))
        check("%s. dopo la chiusura il riepilogo e' libero" % n, summary_outcome(S["admin"], q, r) == "CLEAR")
        c, status, err = confirm_crf(S["admin"], r)
        check("%s. l'admin conferma la CRF" % n, c == 200 and status == "completed", (c, err, status))


if __name__ == "__main__":
    try:
        scenario()
    except SystemExit as e:
        check("esecuzione", False, e)
    except Exception as e:
        check("esecuzione", False, type(e).__name__)
    finally:
        if base.KEEP:
            print("--keep: dati di prova LASCIATI (utenti, ticket, CRF). Prefisso titoli: E2E-ROLES %s" % base.RUN, flush=True)
        else:
            base.cleanup()
    print("RISULTATO %d/%d" % (sum(base.RESULTS), len(base.RESULTS)))
    sys.exit(0 if all(base.RESULTS) else 1)
