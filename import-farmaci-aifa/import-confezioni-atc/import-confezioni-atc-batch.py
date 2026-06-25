#!/usr/bin/env python3
"""
Import farmaci AIFA per confezione (con ATC) in HAPI FHIR — APPROCCIO A BATCH.

Alternativa alla PUT gigante (import-confezioni-atc.py): invece di un singolo
PUT da ~122MB/159k concept (singola transazione enorme, va in OOM/timeout),
carica i concept a LOTTI via $apply-codesystem-delta-add.

Vantaggi:
  - tante transazioni piccole e veloci (niente tx monster, niente OOM)
  - progresso visibile: "batch i/N, +X concept, Ys"
  - ripartenza con --skip se interrotto

CodeSystem content=not-present (delta-add lo richiede). La ricerca $expand?filter
e le designation funzionano lo stesso DOPO la pre-espansione (pre_expand_value_sets).

Risorse FHIR (URL NUOVI, content not-present — separati dalla versione complete):
    CodeSystem  https://aifa.gov.it/fhir/CodeSystem/farmaci-confezioni-atc-np
    ValueSet    https://aifa.gov.it/fhir/ValueSet/farmaci-confezioni-atc-np

Concept:
    code     = CODICE_AIC
    display  = "PA — DENOMINAZIONE DESCRIZIONE"  (ricerca via $expand?filter sul display)
    property = principio-attivo (PA), forma (FORMA), atc (CODICE_ATC)  (lette via $lookup)
    NB: delta-add scarta le designation ma tiene le property → si usano le property.

Uso:
    python3 import-confezioni-atc-batch.py [HAPI_URL] [--csv PATH] [--version YYYY-MM]
            [--batch-size N] [--limit N] [--skip N] [--cs-url URL] [--vs-url URL]

    --batch-size N  concept per lotto (default 2000)
    --limit N       carica solo i primi N concept (test)
    --skip N        salta i primi N (ripartenza dopo interruzione)
"""

import argparse
import csv
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from datetime import date

HAPI_URL_DEFAULT = "http://localhost:8080/fhir"

CS_URL  = "https://aifa.gov.it/fhir/CodeSystem/farmaci-confezioni-atc-np"
VS_URL  = "https://aifa.gov.it/fhir/ValueSet/farmaci-confezioni-atc-np"
DES_USE = "https://aifa.gov.it/fhir/CodeSystem/designation-use"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FHIR_HEADERS = {"Content-Type": "application/fhir+json", "Accept": "application/fhir+json"}

BATCH_TIMEOUT = 300   # ogni batch è piccolo: 5 min abbondano


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Import farmaci AIFA per confezione a batch (delta-add).")
    p.add_argument("hapi_url", nargs="?", default=HAPI_URL_DEFAULT)
    p.add_argument("--csv", default=None)
    p.add_argument("--version", default=None)
    p.add_argument("--batch-size", type=int, default=2000)
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--skip", type=int, default=0)
    p.add_argument("--cs-url", default=None)
    p.add_argument("--vs-url", default=None)
    return p.parse_args()


# ── csv ───────────────────────────────────────────────────────────────────────

def resolve_csv(arg, version):
    if arg:
        return arg
    candidates = [
        os.path.join(SCRIPT_DIR, version, "confezioni.csv"),
        os.path.join(SCRIPT_DIR, "2026-06", "confezioni.csv"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return os.path.abspath(c)
    print("ERRORE: confezioni.csv non trovato. Usa --csv PATH")
    sys.exit(1)


def parse_confezioni(path, limit=None):
    out, skipped = [], 0
    with open(path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter=";"):
            aic = (row.get("CODICE_AIC") or "").strip().zfill(9)
            pa  = (row.get("PA_ASSOCIATI") or "").strip()
            if not aic or not pa:
                skipped += 1
                continue
            out.append({
                "code":  aic,
                "pa":    pa,
                "denom": (row.get("DENOMINAZIONE") or "").strip(),
                "descr": (row.get("DESCRIZIONE") or "").strip(),
                "forma": (row.get("FORMA") or "").strip(),
                "atc":   (row.get("CODICE_ATC") or "").strip(),
            })
            if limit and len(out) >= limit:
                break
    print(f"  Confezioni valide: {len(out)} (scartate: {skipped})")
    return out


# ── concept ───────────────────────────────────────────────────────────────────

def _des(code, display, value):
    return {"use": {"system": DES_USE, "code": code, "display": display}, "value": value}


def build_concept(d):
    # NB: $apply-codesystem-delta-add SCARTA le designation ma TIENE le property.
    # Ricerca = via display. forma/atc/pa = property, recuperate dal frontend con
    # $lookup alla selezione del farmaco (non da $expand, che non ritorna le property).
    pa, denom, descr, forma, atc = d["pa"], d["denom"], d["descr"], d["forma"], d["atc"]
    nome = " ".join(x for x in (denom, descr) if x).strip()
    display = f"{pa} — {nome}" if (pa and nome) else (nome or pa)
    props = [{"code": "principio-attivo", "valueString": pa}]
    if forma: props.append({"code": "forma", "valueString": forma})
    if atc:   props.append({"code": "atc", "valueString": atc})
    return {"code": d["code"], "display": display, "property": props}


# ── HAPI ─────────────────────────────────────────────────────────────────────

def http_json(method, url, params=None, body=None, timeout=60):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    data = body.encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=FHIR_HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.getcode(), resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")


def put_shell(hapi, version):
    """PUT CodeSystem shell content=not-present (no concept inline)."""
    cs = {
        "resourceType": "CodeSystem",
        "url":          CS_URL,
        "version":      version,
        "name":         "AIFAFarmaciConfezioniATCNotPresent",
        "title":        "Farmaci AIFA per confezione (con ATC) - delta",
        "status":       "active",
        "content":      "not-present",
        "caseSensitive": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
    }
    # cerca esistente per url+version
    st, txt = http_json("GET", f"{hapi}/CodeSystem",
                        params={"url": CS_URL, "version": version, "_elements": "id"}, timeout=30)
    eid = None
    try:
        j = json.loads(txt)
        if j.get("entry"):
            eid = j["entry"][0]["resource"]["id"]
    except Exception:
        pass
    if eid:
        cs["id"] = eid
        st, txt = http_json("PUT", f"{hapi}/CodeSystem/{eid}", body=json.dumps(cs), timeout=60)
    else:
        st, txt = http_json("POST", f"{hapi}/CodeSystem", body=json.dumps(cs), timeout=60)
    if st not in (200, 201):
        print(f"  ERRORE shell CodeSystem: HTTP {st}\n  {txt[:400]}")
        sys.exit(1)
    print(f"  Shell CodeSystem OK (content=not-present)  HTTP {st}")


def put_valueset(hapi, version):
    vs = {
        "resourceType": "ValueSet",
        "url":          VS_URL,
        "version":      version,
        "name":         "AIFAFarmaciConfezioniATCNotPresent",
        "title":        "Farmaci AIFA per confezione (con ATC) - delta",
        "status":       "active",
        "date":         str(date.today()),
        "compose":      {"include": [{"system": CS_URL}]},
    }
    st, txt = http_json("GET", f"{hapi}/ValueSet",
                        params={"url": VS_URL, "version": version, "_elements": "id"}, timeout=30)
    eid = None
    try:
        j = json.loads(txt)
        if j.get("entry"):
            eid = j["entry"][0]["resource"]["id"]
    except Exception:
        pass
    if eid:
        vs["id"] = eid
        st, txt = http_json("PUT", f"{hapi}/ValueSet/{eid}", body=json.dumps(vs), timeout=60)
    else:
        st, txt = http_json("POST", f"{hapi}/ValueSet", body=json.dumps(vs), timeout=60)
    if st not in (200, 201):
        print(f"  ERRORE ValueSet: HTTP {st}\n  {txt[:400]}")
        sys.exit(1)
    print(f"  ValueSet OK  HTTP {st}")


def _delta(hapi, op, concepts):
    params = {
        "resourceType": "Parameters",
        "parameter": [
            {"name": "system", "valueUri": CS_URL},
            {"name": "codeSystem",
             "resource": {"resourceType": "CodeSystem", "concept": concepts}},
        ],
    }
    return http_json("POST", f"{hapi}/CodeSystem/$apply-codesystem-delta-{op}",
                     body=json.dumps(params), timeout=BATCH_TIMEOUT)


def delta_remove(hapi, concepts):
    """Rimuove i concept (per code) dal CodeSystem. Tollera code assenti (HTTP 200)."""
    return _delta(hapi, "remove", concepts)


def delta_add(hapi, concepts):
    """POST $apply-codesystem-delta-add con un lotto di concept.

    Auto-heal: se HAPI risponde HTTP 500 con il TransientObjectException su TermConcept
    (HAPI-0389), significa che uno o più code del lotto sono già presenti ma in stato
    corrotto da un run precedente interrotto. delta-remove li purga (tollera gli assenti),
    poi si ritenta la delta-add. Sul happy-path (code nuovi) il remove non scatta mai.
    """
    st, txt = _delta(hapi, "add", concepts)
    if st == 500 and "TransientObjectException" in txt:
        print("    [auto-heal] HAPI-0389: purge code corrotti/esistenti + retry...", flush=True)
        rst, rtxt = delta_remove(hapi, concepts)
        if rst not in (200, 201):
            return rst, rtxt
        st, txt = _delta(hapi, "add", concepts)
    return st, txt


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    global CS_URL, VS_URL
    args = parse_args()
    hapi = args.hapi_url
    version = args.version or date.today().strftime("%Y-%m")
    if args.cs_url: CS_URL = args.cs_url
    if args.vs_url: VS_URL = args.vs_url

    csv_file = resolve_csv(args.csv, version)
    print(f"HAPI FHIR : {hapi}")
    print(f"Versione  : {version}")
    print(f"CSV       : {csv_file}")
    print(f"CS url    : {CS_URL}")
    print(f"Batch     : {args.batch_size}  | skip: {args.skip}  | limit: {args.limit}\n")

    print("=== Lettura confezioni.csv ===")
    rows = parse_confezioni(csv_file, args.limit)

    print("\n=== Build concept ===")
    seen = set()
    concepts = []
    for d in rows:
        if d["code"] in seen:
            continue
        seen.add(d["code"])
        concepts.append(build_concept(d))
    print(f"  Concept unici: {len(concepts)}")

    if args.skip:
        concepts = concepts[args.skip:]
        print(f"  Dopo --skip {args.skip}: restano {len(concepts)}")

    print("\n=== Shell CodeSystem + ValueSet ===")
    put_shell(hapi, version)
    put_valueset(hapi, version)

    print(f"\n=== Delta-add a batch da {args.batch_size} ===")
    total = len(concepts)
    n_batch = (total + args.batch_size - 1) // args.batch_size
    loaded = 0
    t_start = time.monotonic()
    for i in range(0, total, args.batch_size):
        batch = concepts[i:i + args.batch_size]
        bi = i // args.batch_size + 1
        t0 = time.monotonic()
        st, txt = delta_add(hapi, batch)
        dt = time.monotonic() - t0
        if st not in (200, 201):
            print(f"  ERRORE batch {bi}/{n_batch} (offset {args.skip + i}): HTTP {st}")
            print(f"  {txt[:500]}")
            print(f"\n  Caricati {loaded} concept prima dell'errore.")
            print(f"  Riparti con:  --skip {args.skip + i}")
            sys.exit(1)
        loaded += len(batch)
        elapsed = time.monotonic() - t_start
        rate = loaded / elapsed if elapsed else 0
        eta = (total - loaded) / rate if rate else 0
        print(f"  batch {bi:>3}/{n_batch}  +{len(batch)}  tot {args.skip+loaded:>6}/{args.skip+total}  "
              f"{dt:4.1f}s  | {rate:5.0f} c/s  ETA {eta/60:4.1f}min", flush=True)

    print(f"\nFatto! {loaded} concept caricati in {(time.monotonic()-t_start)/60:.1f}min")
    print("\nOra la PRE-ESPANSIONE del ValueSet parte in background (scheduled).")
    print("Controlla i log HAPI per:  Pre-expanded ... Saved <N> concepts")
    print(f"Poi cerca:  GET {hapi}/ValueSet/$expand?url={VS_URL}&filter=<testo>&includeDesignations=true")


if __name__ == "__main__":
    main()
