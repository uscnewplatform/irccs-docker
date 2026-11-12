#!/usr/bin/env python3
"""
Test E2E aggiuntivi dei ticket (staging), con due utenti veri (Keycloak temporanei, cancellati alla fine):

  X1  autore: il ticket e il suo primo messaggio risultano dell'utente che li apre (non del token di servizio); lo stesso per la risposta;
  X2  news di studio: un solo ticket nel gruppo annunci_tutti, anche con i segnaposto 00000 della dashboard; la leggono anche
      gli utenti che non l'hanno creata (sola lettura); chi pubblica aggiunge un aggiornamento, cambia scadenza e priorita',
      la chiude; una news chiusa non si riapre e sparisce dall'elenco;
  X3  blocco della conferma: con il flag SPENTO la conferma con un ticket aperto passa (200); con il flag ACCESO e' fermata (409)
      e la deroga funziona solo con il ruolo e con un motivo valido (10-500 caratteri);
  X4  (solo con --down) Zammad non raggiungibile: la conferma risponde 503 CRF_TICKET_STATE_UNVERIFIABLE, mai via libera.

Il flag si legge dal container di studio-clinico (CRF_CONFIRM_REQUIRE_CLOSED_TICKETS): per provare i due casi si cambia il
flag nel .env e si ricreano studio-clinico e ms Zammad, poi si rilancia lo script.

Usa le funzioni di e2e_ticket_workflow.py (stessa cartella). Variabili d'ambiente OBBLIGATORIE: E2E_PATIENT ed E2E_CAREPLAN.
Opzioni: --keep (non cancella i dati), --no-restart, --down.
    E2E_PATIENT=<id> E2E_CAREPLAN=<id> python3 -I e2e_ticket_extra.py --no-restart [--down]
"""
import datetime
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import e2e_ticket_workflow as base  # noqa: E402  (legge il .env del server e prepara gli helper)

check, js, api, zammad, hapi, sh = base.check, base.js, base.api, base.zammad, base.hapi, base.sh
PATIENT, CAREPLAN = base.PATIENT, base.CAREPLAN
DOWN = "--down" in sys.argv
ZAMMAD_RAILS = os.environ.get("E2E_ZAMMAD_RAILS", "zammad-ticketing_zammad-railsserver_1")
NEWS_GROUP = "annunci_tutti"


def summary(session, qid, qr):
    c, t = api(session, "GET", "/zammad/tickets/crf-summary?patient=%s&questionnaire=%s&careplan=%s&qr=%s" % (PATIENT, qid, CAREPLAN, qr))
    return js(t) or {}


def confirm(session, qr, extra_headers=None):
    cq, body = hapi("GET", "QuestionnaireResponse/" + qr)
    body["status"] = "completed"
    s = dict(session)
    s.update(extra_headers or {})
    c, t = api(s, "PUT", "/QuestionnaireResponse/" + qr, body, fhir=True)
    cq, now = hapi("GET", "QuestionnaireResponse/" + qr)
    return c, base.error_code(t), now.get("status")


def open_crf_ticket(session, customer, group, qid, qr, title):
    c, t = api(session, "POST", "/zammad/tickets", {
        "title": title, "group_id": group, "customer_id": customer, "state_id": 1, "priority_id": 2,
        "crf": qid, "crfscope": "CRF", "qrid": qr, "careplan": CAREPLAN, "patient": PATIENT, "crfdisplay": "E2E", "careplandisplay": "E2E",
        "patientdisplay": "E2E", "patientjourneydisplay": "E2E", "directlink": "https://example.org/e2e",
        "article": {"body": "Prova automatica: da verificare."}})
    tid = (js(t) or {}).get("id")
    if tid:
        base.CREATED["tickets"].append(tid)
    return c, tid


def flag_value():
    out = sh("docker exec irccs-studio-clinico printenv CRF_CONFIRM_REQUIRE_CLOSED_TICKETS 2>/dev/null")
    text = out[1] if isinstance(out, tuple) else out
    return str(text).strip().lower() == "true"


def zammad_up(timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        c, _ = zammad("GET", "/users/me")
        if c == 200:
            return True
        time.sleep(5)
    return False


def scenario():
    flag_on = flag_value()
    print("flag CRF_CONFIRM_REQUIRE_CLOSED_TICKETS = %s (informativo)" % flag_on, flush=True)
    caps_admin = base.group_capabilities(base.GROUP_ADMIN)
    base.create_keycloak_users()
    qid, qr = base.create_fhir_crf()
    zids = base.wait_zammad_users()
    if not check("preparazione: i due utenti sono collegati a Zammad (sync)", len(zids) == 2, zids):
        return
    admin, sper = base.user_session("admin"), base.user_session("sper")
    c, t = api(admin, "GET", "/zammad/tickets/groups-for-patient?patient=" + PATIENT)
    groups = js(t) or []
    sper_gid = next((g["id"] for g in groups if "Sperimentatori" in (g.get("label") or "")), groups[0]["id"] if groups else 7)

    # X1 autore
    c, tid = open_crf_ticket(admin, zids["admin"], sper_gid, qid, qr, "E2E %s: autore" % base.RUN)
    check("X1. l'admin apre il ticket", c == 201 and tid, (c, tid))
    if tid:
        c, t = zammad("GET", "/tickets/%s" % tid)
        z = js(t) or {}
        check("X1. il ticket risulta creato dall'admin, non dal token di servizio", z.get("created_by_id") == zids["admin"], z.get("created_by_id"))
        c, t = zammad("GET", "/ticket_articles/by_ticket/%s" % tid)
        arts = js(t) or []
        check("X1. il primo messaggio e' dell'admin", bool(arts) and arts[0].get("created_by_id") == zids["admin"], [a.get("created_by_id") for a in arts])
        c, t = api(sper, "POST", "/zammad/tickets/%s/articles" % tid, {"body": "Risposta di prova dello sperimentatore."})
        check("X1. lo sperimentatore risponde", c in (200, 201), c)
        c, t = zammad("GET", "/ticket_articles/by_ticket/%s" % tid)
        arts = js(t) or []
        check("X1. la risposta e' dello sperimentatore", len(arts) >= 2 and arts[-1].get("created_by_id") == zids["sper"], [a.get("created_by_id") for a in arts])

    # X3 blocco
    if tid:
        out = summary(admin, qid, qr)
        if flag_on:
            check("X3. flag acceso: con il ticket aperto il riepilogo blocca", out.get("outcome") == "BLOCKED", out.get("outcome"))
            c, code, st = confirm(admin, qr)
            check("X3. flag acceso: la conferma e' fermata (409 CRF_OPEN_TICKETS)", c == 409 and code == "CRF_OPEN_TICKETS" and st == "in-progress", (c, code, st))
            if "internal:override:ticket-gate" in caps_admin:
                c, code, st = confirm(admin, qr, {"X-Ticket-Gate-Override-Reason": "corto"})
                check("X3. deroga con motivo troppo corto: 422 CRF_OVERRIDE_REASON_INVALID", c == 422 and code == "CRF_OVERRIDE_REASON_INVALID", (c, code))
                c, code, st = confirm(admin, qr, {"X-Ticket-Gate-Override-Reason": "Deroga di prova automatica del test E2E"})
                check("X3. deroga valida con il ruolo: la conferma passa (200)", c == 200 and st == "completed", (c, code, st))
            else:
                print("INFO X3. l'admin non ha il ruolo di deroga: prova della deroga saltata", flush=True)
            if DOWN:
                qid2, qr2 = base.create_fhir_crf()
                c2, tid2 = open_crf_ticket(admin, zids["admin"], sper_gid, qid2, qr2, "E2E %s: zammad giu'" % base.RUN)
                try:
                    sh("docker stop %s >/dev/null 2>&1" % ZAMMAD_RAILS)
                    time.sleep(8)
                    c, code, st = confirm(admin, qr2)
                    check("X4. Zammad non raggiungibile: conferma 503 CRF_TICKET_STATE_UNVERIFIABLE, mai via libera",
                          c == 503 and code == "CRF_TICKET_STATE_UNVERIFIABLE" and st == "in-progress", (c, code, st))
                finally:
                    sh("docker start %s >/dev/null 2>&1" % ZAMMAD_RAILS)
                    check("X4. Zammad torna disponibile", zammad_up(), "")
        else:
            check("X3. flag spento: il riepilogo non blocca", out.get("outcome") in ("CLEAR", "OFF", None) or out.get("count", 0) == 0 or out.get("outcome") != "BLOCKED", out)
            c, code, st = confirm(admin, qr)
            check("X3. flag spento: la conferma con un ticket aperto passa (200)", c == 200 and st == "completed", (c, code, st))

    # X2 news di studio
    c, t = zammad("GET", "/groups")
    gid = next((g["id"] for g in (js(t) or []) if g.get("name") == NEWS_GROUP), None)
    if not check("X2. il gruppo %s esiste" % NEWS_GROUP, gid is not None, gid):
        return
    title = "E2E %s: news" % base.RUN
    news = {"title": title, "group_id": gid, "customer_id": zids["admin"], "state_id": 7, "priority_id": 2, "crf": "00000", "crfscope": "STUDY",
            "pending_time": (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "crfdisplay": "00000", "careplan": "00000", "careplandisplay": "00000", "patient": "", "patientdisplay": "00000",
            "patientjourneydisplay": "E2E studio", "directlink": "https://example.org/e2e", "article": {"body": "News di prova automatica."}}
    # l'admin del centro (ruolo internal:manage:center-tickets) riceve 'full' su annunci_tutti dal sync: pubblica senza interventi
    c, t = zammad("GET", "/users/%s" % zids["admin"])
    perms = ((js(t) or {}).get("group_ids") or {}).get(str(gid)) or []
    if not check("X2. il sync da' full su annunci_tutti all'admin del centro", "full" in perms, perms):
        # ripiego per ambienti con il sync precedente: full dato direttamente in Zammad, solo per questa prova
        gids = dict((js(t) or {}).get("group_ids") or {})
        gids[str(gid)] = ["full"]
        c, t = zammad("PUT", "/users/%s" % zids["admin"], {"group_ids": gids})
        check("preparazione: l'admin di prova ha full su annunci_tutti (ripiego)", c == 200, c)
    c, t = api(sper, "POST", "/zammad/tickets", dict(news, customer_id=zids["sper"]))
    check("X2. chi non e' admin non pubblica (403 su annunci_tutti)", c == 403, c)
    c, t = api(admin, "POST", "/zammad/tickets", news)
    nid = (js(t) or {}).get("id")
    if nid:
        base.CREATED["tickets"].append(nid)
    check("X2. l'admin pubblica la news (segnaposto 00000 accettati)", c == 201 and nid, (c, t[:120] if isinstance(t, str) else t))
    if not nid:
        return
    c, t = zammad("GET", "/tickets/search?query=%s&limit=10" % base.urllib.parse.quote("title:\"%s\"" % title))
    found = js(t) or []
    count = len([x for x in (found if isinstance(found, list) else []) if x.get("title") == title])
    check("X2. la news e' un solo ticket", count in (0, 1), count)  # 0 se l'indice di ricerca non e' ancora aggiornato
    c, t = zammad("GET", "/tickets/%s" % nid)
    z = js(t) or {}
    check("X2. la news e' nel gruppo annunci_tutti, creata dall'admin", z.get("group_id") == gid and z.get("created_by_id") == zids["admin"], (z.get("group_id"), z.get("created_by_id")))
    c, t = api(sper, "GET", "/zammad/tickets/%s/myTicket" % zids["sper"])
    mine = js(t) or []
    check("X2. lo sperimentatore, che non l'ha creata, la vede nell'elenco", c == 200 and any(x.get("id") == nid for x in mine if isinstance(x, dict)), (c, len(mine) if isinstance(mine, list) else mine))
    c, t = api(sper, "GET", "/zammad/tickets/%s/articles" % nid)
    th = js(t) or {}
    check("X2. lo sperimentatore legge il testo", c == 200 and len(th.get("articles", [])) >= 1, c)
    check("X2. lo sperimentatore non puo' rispondere ne' chiudere (sola lettura)", th.get("canReply") is False and th.get("canClose") is False, (th.get("canReply"), th.get("canClose")))
    c, t = api(sper, "POST", "/zammad/tickets/%s/articles" % nid, {"body": "non dovrebbe passare"})
    check("X2. risposta dello sperimentatore alla news: 403", c == 403, c)
    c, t = api(sper, "POST", "/zammad/tickets/%s/close" % nid, {"reason": "non dovrebbe passare"})
    check("X2. chiusura dello sperimentatore: 403", c == 403, c)
    c, t = api(admin, "GET", "/zammad/tickets/%s/articles" % nid)
    th = js(t) or {}
    check("X2. chi pubblica puo' rispondere e chiudere (canReply, canClose)", th.get("canReply") is True and th.get("canClose") is True, (th.get("canReply"), th.get("canClose")))
    c, t = api(admin, "POST", "/zammad/tickets/%s/articles" % nid, {"body": "Aggiornamento: nuovo orario."})
    check("X2. aggiunge un aggiornamento", c in (200, 201), c)
    new_pending = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=3)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    c, t = api(admin, "PUT", "/zammad/tickets/%s" % nid, {"priority_id": 3, "pending_time": new_pending})
    check("X2. cambia scadenza e priorita'", c == 200, c)
    c, t = zammad("GET", "/tickets/%s" % nid)
    z = js(t) or {}
    check("X2. scadenza e priorita' risultano cambiate in Zammad", z.get("priority_id") == 3 and str(z.get("pending_time", "")).startswith(new_pending[:10]), (z.get("priority_id"), z.get("pending_time")))
    c, t = api(admin, "POST", "/zammad/tickets/%s/close" % nid, {"reason": "Evento concluso (prova automatica)"})
    check("X2. chiude la news", c == 200, c)
    c, t = zammad("GET", "/tickets/%s" % nid)
    check("X2. la news risulta chiusa", (js(t) or {}).get("state_id") == 4, (js(t) or {}).get("state_id"))
    c, t = api(admin, "POST", "/zammad/tickets/%s/reopen" % nid, {"reason": "no"})
    check("X2. una news chiusa non si riapre (403)", c == 403, c)
    c, t = api(sper, "GET", "/zammad/tickets/%s/myTicket" % zids["sper"])
    check("X2. la news chiusa non e' piu' nell'elenco dello sperimentatore", not any(x.get("id") == nid for x in (js(t) or []) if isinstance(x, dict)))


if __name__ == "__main__":
    try:
        scenario()
    except SystemExit as e:
        check("esecuzione", False, e)
    except Exception as e:  # nessuna traccia con dati sensibili
        check("esecuzione", False, type(e).__name__)
    finally:
        if DOWN:
            sh("docker start %s >/dev/null 2>&1" % ZAMMAD_RAILS)
        base.cleanup()
    print("RISULTATO %d/%d" % (sum(base.RESULTS), len(base.RESULTS)))
    sys.exit(0 if all(base.RESULTS) else 1)
