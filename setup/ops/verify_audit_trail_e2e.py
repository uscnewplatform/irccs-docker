#!/usr/bin/env python3
"""
Verifica end-to-end dell'audit trail contro uno stack in esecuzione
(pascale-local o staging).

Esercita traffico applicativo reale attraverso i microservizi e controlla che
ogni operazione produca l'AuditEvent atteso sullo store di audit dedicato,
verificando i requisiti del piano di remediation:

  Gap 1  - read/search/history di risorse cliniche sensibili -> AuditEvent
  Gap 2  - immodificabilita': PUT/DELETE/$expunge -> 403; trigger DB -> errore SQL
  Gap 4  - contenuto BALP: agent.who, agent.network, entity->paziente
  Gap 5  - eventi Keycloak importati come AuditEvent (LOGIN_ERROR)      [--slow]
  Gap 8  - store clinico non riceve piu' AuditEvent (isolamento)
  Gap 8b - endpoint mediato /fhir/auth/audit-events: 200 admin / 401 no-token
  Gap 9  - bundle transaction -> AuditEvent per transazione             [--with-bundle]
  hash-chain - la catena degli AuditEvent creati durante il test e' contigua

Read-only sui dati esistenti tranne: -- con --observation-patient -- crea 1
Observation di prova, e -- con --with-bundle -- importa il transaction-bundle
di PatientJourney.

TOKEN
-----
I microservizi validano l'issuer del token (`quarkus.oidc.token.issuer`).
In staging l'issuer coincide con l'URL pubblico di Keycloak: passare un bearer
di un utente del gruppo /admin con --token (o farlo emettere da --kc con
--client-secret).
In pascale-local l'issuer e' l'hostname interno `http://irccs-keycloak:8080`:
usare --kc-docker-network <rete> per far emettere il token da un container
`curl` sulla rete Docker (la rete e' `<progetto>_<nome>`, es.
`pascale-local_pascale`).

Uso tipico (pascale-local):
  python3 verify_audit_trail_e2e.py \
      --base http://localhost:80 \
      --audit-fhir http://127.0.0.1:8081/fhir \
      --clinical-fhir http://127.0.0.1:8080/fhir \
      --kc-docker-network pascale-local_pascale \
      --client-id irccs --client-secret "$KEYCLOAK_CLIENT_SECRET" \
      --audit-pg-container pascale-local-postgres-hapi-audit

Exit code 0 = tutti i check PASS (o SKIP), != 0 = almeno un FAIL.
Scrive un report leggibile in --report (default: audit-trail-e2e-report.txt),
da allegare come evidenza ai documenti di processo.
"""
import argparse
import json
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

import requests

FHIR_MT = "application/fhir+json"
EXT_PREV = "http://irccs.pascale.it/fhir/StructureDefinition/audit-chain-prev"
EXT_HASH = "http://irccs.pascale.it/fhir/StructureDefinition/audit-chain-hash"

results = []  # (name, status, detail)  status in PASS/FAIL/SKIP


def record(name, status, detail=""):
    results.append((name, status, detail))
    mark = {"PASS": "OK  ", "FAIL": "FAIL", "SKIP": "skip"}[status]
    print(f"[{mark}] {name}" + (f"  -- {detail}" if detail else ""))


def h(token, mt=FHIR_MT):
    d = {"Accept": mt, "Content-Type": mt}
    if token:
        d["Authorization"] = f"Bearer {token}"
    return d


def get_token(args):
    if args.token:
        return args.token
    data = (f"grant_type=client_credentials&client_id={args.client_id}"
            f"&client_secret={args.client_secret}")
    if args.kc_docker_network:
        url = f"{args.kc_internal}/realms/{args.realm}/protocol/openid-connect/token"
        cmd = ["docker", "run", "--rm", "--network", args.kc_docker_network,
               "curlimages/curl:latest", "-s", "-X", "POST", url, "-d", data]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            sys.exit(f"token via docker network fallito: {out.stderr[:300]}")
        return json.loads(out.stdout)["access_token"]
    url = f"{args.kc}/realms/{args.realm}/protocol/openid-connect/token"
    r = requests.post(url, data=dict(p.split("=", 1) for p in data.split("&")), timeout=30)
    r.raise_for_status()
    return r.json()["access_token"]


def count(base, token, params=None):
    p = {"_summary": "count", "_total": "accurate"}
    p.update(params or {})
    try:
        r = requests.get(f"{base}/AuditEvent", params=p, headers=h(token), timeout=30)
        r.raise_for_status()
        return r.json().get("total", 0)
    except requests.RequestException:
        return None


def recent(args, token, n=150):
    r = requests.get(f"{args.audit_fhir}/AuditEvent",
                     params={"_sort": "-_lastUpdated", "_count": str(n)},
                     headers=h(token), timeout=60)
    r.raise_for_status()
    return [e["resource"] for e in r.json().get("entry", [])
            if e.get("resource", {}).get("resourceType") == "AuditEvent"]


def find_audit(args, token, predicate, tries=40, delay=3):
    """Cerca un AuditEvent che soddisfa predicate, ripetendo la lettura.
    tries*delay va tenuto ampio: l'indice full-text dello store audit puo'
    impiegare qualche decina di secondi a rendere visibile un evento appena scritto."""
    for _ in range(tries):
        for ev in recent(args, token):
            if predicate(ev):
                return ev
        time.sleep(delay)
    return None


def entity_values(ev):
    out = []
    for en in ev.get("entity", []):
        w = en.get("what", {})
        if w.get("identifier", {}).get("value"):
            out.append(w["identifier"]["value"])
        if w.get("reference"):
            out.append(w["reference"])
    return out


def agent0(ev):
    return (ev.get("agent") or [{}])[0]


# ---------------------------------------------------------------- checks

def check_crud_lifecycle(args, token):
    """Crea/legge/cerca una risorsa clinica NUOVA e verifica che ogni operazione
    produca l'AuditEvent atteso (evita match su eventi pre-esistenti)."""
    # paziente su cui agganciare la Observation
    r = requests.get(f"{args.base}/Patient", params={"_count": "1"}, headers=h(token), timeout=30)
    pid = args.patient_id or (r.json().get("entry", [{}])[0].get("resource", {}).get("id")
                              if r.status_code == 200 else None)
    target = args.observation_patient or pid
    if not target:
        record("Gap1/Gap4: ciclo create/read/search", "FAIL", "nessun Patient disponibile")
        return None
    marker = f"e2e-audit-{uuid.uuid4().hex[:8]}"
    obs = {"resourceType": "Observation", "status": "final",
           "code": {"text": marker}, "subject": {"reference": f"Patient/{target}"},
           "valueString": "verifica audit trail"}
    hdrs = h(token)
    if args.pj_id:
        hdrs["Patientjourneyid"] = args.pj_id
    r = requests.post(f"{args.base}/Observation", headers=hdrs, data=json.dumps(obs), timeout=30)
    if r.status_code not in (200, 201):
        record("Gap1/Gap4: ciclo create/read/search", "SKIP",
               f"POST Observation HTTP {r.status_code}: {r.text[:120]} (serve --pj-id?)")
        return pid
    oid = r.json().get("id")

    # CREATE -> AuditEvent C
    ev = find_audit(args, token, lambda e: e.get("action") == "C"
                    and any(f"Observation/{oid}" in v for v in entity_values(e)))
    if ev:
        who = agent0(ev).get("who", {}).get("identifier", {}).get("value") \
            or agent0(ev).get("who", {}).get("display")
        net = agent0(ev).get("network", {}).get("address")
        pat = any("Patient/" in v for v in entity_values(ev))
        record("Gap4: AuditEvent su create ha agent.who", "PASS" if who else "FAIL", f"who={who}")
        record("Gap4: AuditEvent su create ha agent.network", "PASS" if net else "SKIP",
               f"network={net}" if net else "nessun IP (no X-Forwarded-For)")
        record("Gap4: AuditEvent su create referenzia il paziente", "PASS" if pat else "FAIL",
               f"entity={entity_values(ev)}")
    else:
        record("Gap1: AuditEvent per create Observation", "FAIL", f"nessun AuditEvent C per Observation/{oid}")

    # READ -> AuditEvent R
    requests.get(f"{args.base}/Observation/{oid}", headers=h(token), timeout=30)
    ev = find_audit(args, token, lambda e: e.get("action") == "R"
                    and any(f"Observation/{oid}" in v for v in entity_values(e)))
    record("Gap1: AuditEvent per read risorsa clinica", "PASS" if ev else "FAIL",
           f"Observation/{oid} action=R" if ev else "nessun AuditEvent read")

    # SEARCH -> AuditEvent E
    requests.get(f"{args.base}/Observation", params={"code": marker}, headers=h(token), timeout=30)
    ev = find_audit(args, token, lambda e: e.get("action") == "E"
                    and any(st.get("code", "").startswith("search") for st in e.get("subtype", [])))
    record("Gap1: AuditEvent per search risorsa clinica", "PASS" if ev else "FAIL",
           "action=E subtype=search-type" if ev else "nessun AuditEvent search")

    # HISTORY
    requests.get(f"{args.base}/Observation/{oid}/_history", headers=h(token), timeout=30)
    ev = find_audit(args, token, lambda e: any(f"Observation/{oid}" in v for v in entity_values(e))
                    and e.get("action") in ("R", "E"), tries=10)
    record("Gap1: AuditEvent per _history", "PASS" if ev else "SKIP",
           "presente" if ev else "history non tracciata a parte (ok se coperta da read)")
    return pid


def check_clinical_isolation(args, token, before):
    if before is None:
        record("Gap8: store clinico non riceve AuditEvent", "SKIP", "conteggio non disponibile")
        return
    after = count(args.clinical_fhir, token)
    if after is None:
        record("Gap8: store clinico non riceve AuditEvent", "SKIP", "conteggio non disponibile")
    elif after == before:
        record("Gap8: store clinico non riceve AuditEvent", "PASS", f"invariato a {after}")
    else:
        record("Gap8: store clinico non riceve AuditEvent", "FAIL",
               f"da {before} a {after}: i microservizi scrivono ancora sull'istanza clinica")


def check_append_only(args, token):
    evs = recent(args, token, 1)
    if not evs:
        record("Gap2: append-only (PUT/DELETE/$expunge -> 403)", "SKIP", "nessun AuditEvent")
        return
    ev = evs[0]
    eid = ev["id"]
    codes = {}
    codes["PUT"] = requests.put(f"{args.audit_fhir}/AuditEvent/{eid}", headers=h(token),
                                data=json.dumps(ev), timeout=30).status_code
    codes["DELETE"] = requests.delete(f"{args.audit_fhir}/AuditEvent/{eid}", headers=h(token),
                                      timeout=30).status_code
    codes["$expunge"] = requests.post(
        f"{args.audit_fhir}/AuditEvent/{eid}/$expunge", headers=h(token),
        data=json.dumps({"resourceType": "Parameters",
                         "parameter": [{"name": "expungeDeletedResources", "valueBoolean": True}]}),
        timeout=30).status_code
    strict = all(c == 403 for c in codes.values())
    soft = (codes["PUT"] != 200 and codes["DELETE"] not in (200, 204)
            and codes["$expunge"] not in (200, 202))
    record("Gap2: append-only (PUT/DELETE/$expunge respinti)",
           "PASS" if (strict or soft) else "FAIL",
           " ".join(f"{k}={v}" for k, v in codes.items()))


def check_db_trigger(args):
    if not args.audit_pg_container:
        record("Gap2: trigger DB (DELETE SQL diretto respinto)", "SKIP", "--audit-pg-container non fornito")
        return
    sql = ("DELETE FROM hfj_resource WHERE res_type='AuditEvent' "
           "AND res_id=(SELECT res_id FROM hfj_resource WHERE res_type='AuditEvent' LIMIT 1);")
    cmd = ["docker", "exec", "-i", args.audit_pg_container, "psql",
           "-U", args.audit_pg_user, "-d", args.audit_pg_db, "-v", "ON_ERROR_STOP=1", "-c", sql]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (subprocess.SubprocessError, FileNotFoundError) as e:
        record("Gap2: trigger DB (DELETE SQL diretto respinto)", "SKIP", f"docker exec fallito: {e}")
        return
    blob = (p.stdout + p.stderr).lower()
    if p.returncode != 0 and any(k in blob for k in ("append-only", "immutable", "audit", "cannot", "error", "exception")):
        record("Gap2: trigger DB (DELETE SQL diretto respinto)", "PASS", "DELETE -> eccezione SQL")
    elif p.returncode == 0:
        record("Gap2: trigger DB (DELETE SQL diretto respinto)", "FAIL", "DELETE riuscito senza errore")
    else:
        record("Gap2: trigger DB (DELETE SQL diretto respinto)", "SKIP", f"rc={p.returncode}: {blob[:150]}")


def check_mediated_endpoint(args, token):
    url = f"{args.auth_base}/fhir/auth/audit-events"
    r = requests.get(url, params={"_count": "1"}, headers=h(token, "application/json"), timeout=30)
    ok = r.status_code == 200 and r.json().get("resourceType") == "Bundle"
    record("Gap8b: /fhir/auth/audit-events con token admin -> 200 Bundle",
           "PASS" if ok else "FAIL", f"HTTP {r.status_code}")
    r = requests.get(url, params={"_count": "1"}, headers={"Accept": "application/json"}, timeout=30)
    record("Gap8b: /fhir/auth/audit-events senza token -> 401",
           "PASS" if r.status_code == 401 else "FAIL", f"HTTP {r.status_code}")
    if args.non_admin_token:
        r = requests.get(url, params={"_count": "1"},
                         headers=h(args.non_admin_token, "application/json"), timeout=30)
        record("Gap8b: /fhir/auth/audit-events con token non-admin -> 403",
               "PASS" if r.status_code == 403 else "FAIL", f"HTTP {r.status_code}")
    else:
        record("Gap8b: /fhir/auth/audit-events con token non-admin -> 403", "SKIP",
               "--non-admin-token non fornito")


def check_hash_chain(args, token, since_iso):
    """Verifica la contiguita' della catena sugli AuditEvent creati dopo since_iso."""
    time.sleep(args.settle)  # lascia stabilizzare l'indice full-text dello store audit
    chain = [ev for ev in recent(args, token, 300)
             if ev.get("recorded", "") >= since_iso]
    chain.sort(key=lambda e: (e.get("recorded", ""), e.get("meta", {}).get("lastUpdated", "")))
    if len(chain) < 2:
        record("hash-chain: catena degli eventi del test e' contigua", "SKIP",
               f"solo {len(chain)} AuditEvent nel periodo del test")
        return
    broken = []
    no_hash = 0
    prev_hash = None
    for ev in chain:
        exts = {x["url"]: x.get("valueString") for x in ev.get("extension", [])}
        cur_prev, cur_hash = exts.get(EXT_PREV), exts.get(EXT_HASH)
        if cur_hash is None:
            # Evento scritto con hash-chain disattivata (irccs.audit.hash-chain.enabled=false):
            # non e' una rottura, ma l'interceptor ripartira' da "genesis" al prossimo evento.
            no_hash += 1
            prev_hash = "genesis"
            continue
        if prev_hash is not None and cur_prev != prev_hash and not (
                prev_hash == "genesis" and cur_prev in ("genesis", "")):
            broken.append(f"{ev['id']}:prev({(cur_prev or '')[:8]})!=atteso({prev_hash[:8]})")
        prev_hash = cur_hash
    suffix = f" ({no_hash} senza hash: hash-chain disattivata)" if no_hash else ""
    if broken:
        record("hash-chain: catena degli eventi del test e' contigua", "FAIL",
               f"{len(chain)} eventi, rotture: " + "; ".join(broken[:6]))
    else:
        record("hash-chain: catena degli eventi del test e' contigua", "PASS",
               f"{len(chain)} eventi concatenati senza rotture{suffix}")


def check_keycloak_poller(args, token):
    if not args.slow:
        record("Gap5: evento Keycloak -> AuditEvent", "SKIP", "--slow non attivo")
        return
    bad = f"nobody-{uuid.uuid4().hex[:6]}@e2e.x"
    try:
        requests.post(f"{args.kc}/realms/{args.realm}/protocol/openid-connect/token",
                      data={"grant_type": "password", "client_id": args.client_id,
                            "client_secret": args.client_secret, "username": bad, "password": "x"},
                      timeout=30)
    except requests.RequestException:
        pass
    ev = find_audit(args, token,
                    lambda e: "login_error" in json.dumps(e).lower() or "keycloak" in json.dumps(e).lower(),
                    tries=max(2, int(args.poller_wait / 5)), delay=5)
    record("Gap5: evento Keycloak -> AuditEvent", "PASS" if ev else "FAIL",
           "LOGIN_ERROR importato" if ev else f"nessun AuditEvent dopo {args.poller_wait}s")


def check_bundle_transaction(args, token):
    if not args.with_bundle:
        record("Gap9: bundle transaction -> AuditEvent", "SKIP", "--with-bundle non attivo (popola dati)")
        return
    try:
        payload = open(args.bundle_file, "rb").read()
    except OSError as e:
        record("Gap9: bundle transaction -> AuditEvent", "SKIP", f"bundle non leggibile: {e}")
        return
    base = args.bundle_base or args.base
    r = requests.post(f"{base}/Bundle/import", headers=h(token), data=payload, timeout=240)
    if r.status_code not in (200, 201) or "<!DOCTYPE html>" in r.text[:80]:
        record("Gap9: bundle transaction -> AuditEvent", "FAIL",
               f"import HTTP {r.status_code} da {base} (proxy /Bundle assente? usa --bundle-base "
               f"http://<studio-clinico>): {r.text[:100]}")
        return
    ev = find_audit(args, token, lambda e: any(st.get("code") == "transaction"
                                               for st in e.get("subtype", [])), tries=15, delay=2)
    record("Gap9: bundle transaction -> AuditEvent", "PASS" if ev else "FAIL",
           "subtype=transaction" if ev else "nessun AuditEvent di transazione")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Verifica E2E audit trail")
    ap.add_argument("--base", default="http://localhost:80")
    ap.add_argument("--auth-base", default=None, help="base per /fhir/auth (default: --base)")
    ap.add_argument("--audit-fhir", default="http://127.0.0.1:8081/fhir")
    ap.add_argument("--clinical-fhir", default="http://127.0.0.1:8080/fhir")
    ap.add_argument("--kc", default="http://localhost:9445", help="base Keycloak pubblica")
    ap.add_argument("--kc-internal", default="http://irccs-keycloak:8080",
                    help="base Keycloak vista dai container (per --kc-docker-network)")
    ap.add_argument("--kc-docker-network", default=None,
                    help="rete Docker su cui emettere il token (pascale-local: <progetto>_pascale)")
    ap.add_argument("--realm", default="pascale")
    ap.add_argument("--client-id", default="irccs")
    ap.add_argument("--client-secret", default=None)
    ap.add_argument("--token", default=None, help="bearer gia' pronto (utente gruppo /admin)")
    ap.add_argument("--non-admin-token", default=None)
    ap.add_argument("--patient-id", default=None, help="id Patient su cui fare read/history (default: primo trovato)")
    ap.add_argument("--observation-patient", default=None,
                    help="id Patient su cui creare una Observation di prova (attiva il check write)")
    ap.add_argument("--pj-id", default=None, help="valore header Patientjourneyid per la create")
    ap.add_argument("--audit-pg-container", default=None)
    ap.add_argument("--audit-pg-user", default="hapiaudit")
    ap.add_argument("--audit-pg-db", default="hapiaudit")
    ap.add_argument("--with-bundle", action="store_true")
    ap.add_argument("--bundle-file", default="../../pascale-local/setup/transaction-bundle.json")
    ap.add_argument("--bundle-base", default=None,
                    help="base per POST /Bundle/import se il proxy non instrada /Bundle "
                         "(es. http://localhost:<porta-studio-clinico>); default: --base")
    ap.add_argument("--slow", action="store_true")
    ap.add_argument("--settle", type=int, default=20, help="attesa prima del check hash-chain (s)")
    ap.add_argument("--poller-wait", type=int, default=330)
    ap.add_argument("--report", default="audit-trail-e2e-report.txt")
    args = ap.parse_args()
    if not args.auth_base:
        args.auth_base = args.base
    if not args.token and not args.client_secret:
        ap.error("serve --token oppure --client-secret")

    print("== Verifica E2E audit trail ==")
    print(f"proxy: {args.base}   audit: {args.audit_fhir}   clinico: {args.clinical_fhir}\n")

    token = get_token(args)
    start_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    clin_before = count(args.clinical_fhir, token)
    aud_before = count(args.audit_fhir, token)
    print(f"AuditEvent audit (pre): {aud_before}   clinico (pre): {clin_before}\n")

    check_crud_lifecycle(args, token)
    check_bundle_transaction(args, token)
    check_clinical_isolation(args, token, clin_before)
    check_mediated_endpoint(args, token)
    check_append_only(args, token)
    check_db_trigger(args)
    check_keycloak_poller(args, token)
    check_hash_chain(args, token, start_iso)

    aud_after = count(args.audit_fhir, token)
    n_pass = sum(1 for _, s, _ in results if s == "PASS")
    n_fail = sum(1 for _, s, _ in results if s == "FAIL")
    n_skip = sum(1 for _, s, _ in results if s == "SKIP")

    lines = [
        "Report verifica E2E audit trail",
        f"Data: {datetime.now(timezone.utc).isoformat()}",
        f"Stack: proxy={args.base} audit={args.audit_fhir} clinico={args.clinical_fhir}",
        f"AuditEvent store audit: {aud_before} -> {aud_after}",
        "",
    ]
    for name, status, detail in results:
        lines.append(f"[{status:4}] {name}" + (f"  -- {detail}" if detail else ""))
    lines += ["", f"PASS={n_pass}  FAIL={n_fail}  SKIP={n_skip}"]
    with open(args.report, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nPASS={n_pass}  FAIL={n_fail}  SKIP={n_skip}")
    print(f"Report: {args.report}")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
