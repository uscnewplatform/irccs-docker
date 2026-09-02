#!/usr/bin/env python3
"""
Validazione statica delle query LogQL del gruppo `irccs-audit-anomalie`
(rules.yaml): spinge righe di log REALI dei microservizi in un Loki effimero
e verifica che ogni query estragga i campi giusti, aggreghi correttamente e
ritorni valori non nulli. NON tara le soglie (serve traffico reale), verifica
che le regole "funzionino" invece di scattare a vuoto o mai.

Ha trovato (2026-08-31) che 2 regole su 4 non sarebbero mai scattate:
`| json` senza path appiattisce `mdc.auditAction` in `mdc_auditAction`.

Uso:
  # raccogli righe di audit reali da uno stack in esecuzione:
  for c in anagrafica-pazienti studio-clinico auth centro-ricerca; do \
    docker logs pascale-local-$c --since 30m 2>&1 | grep -F '"auditAction"'; \
  done > /tmp/audit_lines.jsonl
  docker logs pascale-local-hapi-audit --since 30m 2>&1 | grep -E 'AUDIT-TRAIL|AUDIT-APPEND-ONLY' >> /tmp/audit_lines.jsonl

  python3 validate_audit_queries.py /tmp/audit_lines.jsonl

Richiede Docker (avvia grafana/loki:3.5 su una porta effimera e lo rimuove).
"""
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PORT = 3199
LOKI = f"http://localhost:{PORT}"
USERS = ["mrossi@irccs.it", "gverdi@irccs.it", "abianchi@irccs.it"]

QUERIES = {
    "read-volume-per-user (soglia: gt 500 / utente / 1h)":
        ('max(sum by (auditUser) (count_over_time({audit_trail="true"} '
         '| json auditAction="mdc.auditAction", auditOutcome="mdc.auditOutcome", auditUser="mdc.auditUser" '
         '| auditAction=~"R|E" | auditOutcome="success" | auditUser!="" [1h])))', "non nullo"),
    "off-hours-access (soglia: gt 50 / 5m)":
        ('sum(count_over_time({audit_trail="true"} '
         '| json auditAction="mdc.auditAction", auditOutcome="mdc.auditOutcome" '
         '| auditAction=~"R|E" | auditOutcome="success" [5m]))', "non nullo"),
    "write-failures (soglia: gt 0 / 15m)":
        ('sum(count_over_time({container_name=~"irccs-.+"} '
         '|~ "createAuditEvent: (scrittura AuditEvent fallita|errore non gestito)" [15m]))', "match se presenti"),
    "append-only-violation (soglia: gt 0 / 5m)":
        ('sum by (user, clientIp) (count_over_time('
         '{audit_trail="true", audit_marker="append-only-violation"} | logfmt [5m]))', "match se presenti"),
    "hash-chain-reject (soglia: gt 0 / 15m)":
        ('sum by (user) (count_over_time('
         '{audit_trail="true", audit_marker="hash-chain-reject"} | logfmt [15m]))', "match se presenti"),
    "[controllo negativo] `| json` senza path -> DEVE essere vuoto":
        ('sum(count_over_time({audit_trail="true"} | json | auditAction=~"R|E" [1h]))', "atteso VUOTO"),
}


def start_loki():
    subprocess.run(["docker", "rm", "-f", "audit-query-loki"], capture_output=True)
    subprocess.run(["docker", "run", "-d", "--name", "audit-query-loki",
                    "-p", f"{PORT}:3100", "grafana/loki:3.5"], check=True, capture_output=True)
    for _ in range(40):
        try:
            if urllib.request.urlopen(f"{LOKI}/ready").status == 200:
                return
        except Exception:
            pass
        time.sleep(2)
    sys.exit("Loki non pronto")


def push(lines):
    now = int(time.time() * 1e9)
    hour = 3_600_000_000_000
    streams = {}
    for i, ln in enumerate(lines):
        ln = ln.strip()
        if not ln:
            continue
        is_json = ln.startswith("{")
        host = "irccs-unknown"
        audit = False
        # Label extra che Alloy assegnerebbe alle righe "AUDIT-TRAIL marker=...".
        extra_labels = {}
        if is_json:
            try:
                rec = json.loads(ln)
            except json.JSONDecodeError:
                continue
            host = rec.get("hostName", host)
            audit = "auditAction" in rec.get("mdc", {})
        elif "AUDIT-TRAIL marker=" in ln:
            host = "irccs-hapi-audit"
            extra_labels["audit_trail"] = "true"
            m = re.search(r"AUDIT-TRAIL marker=(\S+)", ln)
            if m:
                extra_labels["audit_marker"] = m.group(1)
            mo = re.search(r"\boutcome=(\S+)", ln)
            if mo:
                extra_labels["audit_outcome"] = mo.group(1)
        elif "AUDIT-APPEND-ONLY" in ln:  # righe legacy pre-AUDIT-TRAIL
            host = "irccs-hapi-audit"
        elif "createAuditEvent:" in ln:
            host = "irccs-anagrafica-pazienti"
        variants = USERS if audit else [None]
        for u in variants:
            if u and is_json:
                rec2 = json.loads(ln)
                rec2["mdc"]["auditUser"] = u
                rec2["mdc"]["userId"] = u
                body = json.dumps(rec2)
            else:
                body = ln
            if audit:
                # traffico di volume: spalmato nell'ultima ora
                ts = str(now - ((i * 37 + (hash(u or "") % 50)) * 1_000_000_000) % hour)
            else:
                # eventi puntuali (fallimenti, violazioni append-only): ultimi 2 minuti,
                # dentro le finestre [15m]/[5m] delle rispettive regole
                ts = str(now - (i % 60) * 1_000_000_000)
            labels = {"container_name": host}
            if audit:
                labels["audit_trail"] = "true"
            labels.update(extra_labels)
            key = tuple(sorted(labels.items()))
            streams.setdefault(key, []).append([ts, body])
    payload = {"streams": [
        {"stream": dict(k), "values": v} for k, v in streams.items()]}
    req = urllib.request.Request(f"{LOKI}/loki/api/v1/push", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req)
    return sum(len(v) for v in streams.values())


def query(expr):
    u = f"{LOKI}/loki/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    return json.load(urllib.request.urlopen(u)).get("data", {}).get("result", [])


def main():
    lines = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/audit_lines.jsonl").read().splitlines()
    start_loki()
    try:
        n = push(lines)
        print(f"push: {n} righe\n")
        time.sleep(2)
        fail = 0
        for name, (expr, expect) in QUERIES.items():
            res = query(expr)
            vals = [r.get("value", [None, None])[1] for r in res]
            empty = not res
            ok = (empty if "VUOTO" in expect else not empty)
            print(f"[{'OK  ' if ok else 'FAIL'}] {name}\n       -> {'(vuoto)' if empty else vals}")
            if not ok:
                fail += 1
        sys.exit(1 if fail else 0)
    finally:
        subprocess.run(["docker", "rm", "-f", "audit-query-loki"], capture_output=True)


if __name__ == "__main__":
    main()
