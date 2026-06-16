#!/usr/bin/env python3
"""
Import farmaci AIFA a livello di CONFEZIONE come CodeSystem/ValueSet in HAPI FHIR.

Fonte unica: confezioni.csv (catalogo AIFA completo, ~159k confezioni).
A differenza di import-aifa-farmaci.py (solo Classe A/H, ~12k, ATC parziale),
qui la copertura e' completa e il codice ATC e' presente su ogni confezione.

Granularita': 1 concept per CODICE_AIC (confezione).

Risorse FHIR (URL NUOVI — non sovrascrivono quelle esistenti):
    CodeSystem  https://aifa.gov.it/fhir/CodeSystem/farmaci-confezioni-atc   (content: complete)
    ValueSet    https://aifa.gov.it/fhir/ValueSet/farmaci-confezioni-atc

Concept:
    code        = CODICE_AIC (9 cifre)
    display     = "PA — DENOMINAZIONE DESCRIZIONE"   (ricerca $expand?filter su display)
    designation = principio-attivo (PA), forma (FORMA), atc (CODICE_ATC)
    property    = principio-attivo, forma, atc, denominazione, descrizione

Le designation forma/atc servono al frontend: $expand restituisce le designation
ma NON le property. Vengono incluse fin dalla creazione del CS cosi' l'indice
Lucene le pubblica nell'$expand (a differenza di una designation aggiunta dopo).

Uso:
    python3 import-confezioni-atc.py [HAPI_URL] [--csv PATH] [--version YYYY-MM]
                                     [--dry-run] [--limit N] [--out FILE] [--list]

    --dry-run   Costruisce le risorse, scrive il JSON su file, NON fa PUT.
    --limit N   Usa solo le prime N confezioni (test di carico).
    --out FILE  Dove scrivere il CodeSystem JSON in dry-run (default: ./codesystem-confezioni-atc.json)
    --list      Elenca le versioni gia' su HAPI ed esce.
"""

import argparse
import csv
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
from datetime import date

# ── costanti ──────────────────────────────────────────────────────────────────

HAPI_URL_DEFAULT = "http://localhost:8080/fhir"

CS_URL  = "https://aifa.gov.it/fhir/CodeSystem/farmaci-confezioni-atc"
VS_URL  = "https://aifa.gov.it/fhir/ValueSet/farmaci-confezioni-atc"
DES_USE = "https://aifa.gov.it/fhir/CodeSystem/designation-use"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

FHIR_HEADERS = {
    "Content-Type": "application/fhir+json",
    "Accept":       "application/fhir+json",
}

# PUT di ~159k concept content=complete: il server deve parsare + indicizzare
# (Lucene) in UNA transazione. Timeout ampio (60 min).
PUT_TIMEOUT = 3600


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="Import farmaci AIFA per confezione (con ATC) in HAPI FHIR.")
    p.add_argument("hapi_url", nargs="?", default=HAPI_URL_DEFAULT,
                   help=f"URL base HAPI FHIR (default: {HAPI_URL_DEFAULT})")
    p.add_argument("--csv", default=None,
                   help="Path di confezioni.csv (default: ricerca standard)")
    p.add_argument("--version", default=None,
                   help="Versione YYYY-MM (default: mese corrente)")
    p.add_argument("--cs-url", default=None,
                   help=f"Override URL CodeSystem (default: {CS_URL}). "
                        "Usa un url vuoto per forzare una CREATE pulita (deferred storage).")
    p.add_argument("--vs-url", default=None,
                   help=f"Override URL ValueSet (default: {VS_URL}).")
    p.add_argument("--dry-run", action="store_true",
                   help="Costruisce e scrive il JSON, nessun PUT su HAPI")
    p.add_argument("--limit", type=int, default=None,
                   help="Usa solo le prime N confezioni (test)")
    p.add_argument("--slim", action="store_true",
                   help="Droppa le property dai concept (tiene solo display + designation). "
                        "Meno righe da indicizzare -> PUT piu' leggera. Le designation "
                        "(pa/forma/atc) restano, il frontend usa quelle.")
    p.add_argument("--out", default=None,
                   help="File di output del CodeSystem in dry-run")
    p.add_argument("--list", action="store_true",
                   help="Elenca le versioni su HAPI ed esce")
    return p.parse_args()


# ── path csv ──────────────────────────────────────────────────────────────────

def resolve_csv(arg: str | None, version: str) -> str:
    if arg:
        return arg
    candidates = [
        os.path.join(SCRIPT_DIR, version, "confezioni.csv"),
        os.path.join(SCRIPT_DIR, "..", "import-atc-principi-attivi", version, "confezioni.csv"),
        os.path.join(SCRIPT_DIR, "..", "import-atc-principi-attivi", "2026-06", "confezioni.csv"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return os.path.abspath(c)
    print("ERRORE: confezioni.csv non trovato. Cercato in:")
    for c in candidates:
        print(f"  - {os.path.abspath(c)}")
    print("Specifica il path con --csv PATH")
    sys.exit(1)


# ── parse ─────────────────────────────────────────────────────────────────────

def parse_confezioni(path: str, limit: int | None = None) -> list[dict]:
    """Legge confezioni.csv. Una confezione (AIC) per riga."""
    out = []
    skipped = 0
    with open(path, encoding="utf-8") as fh:
        reader = csv.DictReader(fh, delimiter=";")
        for row in reader:
            aic = (row.get("CODICE_AIC") or "").strip().zfill(9)
            pa  = (row.get("PA_ASSOCIATI") or "").strip()
            if not aic or not pa:
                skipped += 1
                continue
            out.append({
                "code":          aic,
                "pa":            pa,
                "denominazione": (row.get("DENOMINAZIONE") or "").strip(),
                "descrizione":   (row.get("DESCRIZIONE") or "").strip(),
                "forma":         (row.get("FORMA") or "").strip(),
                "atc":           (row.get("CODICE_ATC") or "").strip(),
            })
            if limit and len(out) >= limit:
                break
    print(f"  Confezioni valide: {len(out)} (scartate: {skipped})")
    return out


# ── FHIR build ─────────────────────────────────────────────────────────────────

def _designation(code: str, display: str, value: str) -> dict:
    return {"use": {"system": DES_USE, "code": code, "display": display},
            "value": value}


def build_codesystem(confezioni: list[dict], version: str, slim: bool = False) -> dict:
    seen: set[str] = set()
    concepts = []
    n_forma = n_atc = 0
    for d in confezioni:
        if d["code"] in seen:
            continue
        seen.add(d["code"])

        pa    = d["pa"]
        denom = d["denominazione"]
        descr = d["descrizione"]
        forma = d["forma"]
        atc   = d["atc"]

        nome_completo = " ".join(x for x in (denom, descr) if x).strip()
        display = f"{pa} — {nome_completo}" if (pa and nome_completo) else (nome_completo or pa)

        # property minime per $lookup (forma/atc). denom/descr restano solo nel display.
        props = [{"code": "principio-attivo", "valueString": pa}]
        if forma: props.append({"code": "forma", "valueString": forma})
        if atc:   props.append({"code": "atc",   "valueCode":   atc})

        # le designation sono cio' che $expand restituisce al frontend
        designations = [_designation("principio-attivo", "Principio attivo", pa)]
        if forma:
            designations.append(_designation("forma", "Forma farmaceutica", forma))
            n_forma += 1
        if atc:
            designations.append(_designation("atc", "Codice ATC", atc))
            n_atc += 1

        concept = {
            "code":        d["code"],
            "display":     display,
            "designation": designations,
        }
        if not slim:
            concept["property"] = props
        concepts.append(concept)

    print(f"  Concept: {len(concepts)}  | con forma: {n_forma}  | con atc: {n_atc}")

    return {
        "resourceType": "CodeSystem",
        "url":          CS_URL,
        "version":      version,
        "name":         "AIFAFarmaciConfezioniATC",
        "title":        "Farmaci AIFA per confezione (con ATC)",
        "status":       "active",
        "experimental": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
        "description": (
            f"Catalogo completo AIFA a livello di confezione — versione {version}. "
            "Una confezione (AIC) per concept, codice ATC presente su ogni voce."
        ),
        "caseSensitive": False,
        "content":       "complete",
        "count":         len(concepts),
        "property": [
            {"code": "principio-attivo", "type": "string", "description": "Principio attivo"},
            {"code": "forma",            "type": "string", "description": "Forma farmaceutica"},
            {"code": "atc",              "type": "code",   "description": "Codice ATC"},
        ],
        "concept": concepts,
    }


def build_valueset(version: str) -> dict:
    return {
        "resourceType": "ValueSet",
        "url":          VS_URL,
        "version":      version,
        "name":         "AIFAFarmaciConfezioniATC",
        "title":        "Farmaci AIFA per confezione (con ATC)",
        "status":       "active",
        "experimental": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
        "description":  f"Tutte le confezioni AIFA con codice ATC — versione {version}.",
        "compose":      {"include": [{"system": CS_URL, "version": version}]},
    }


# ── HAPI (solo stdlib, niente requests) ──────────────────────────────────────

def http_json(method: str, url: str, params: dict | None = None,
              body: str | None = None, timeout: int = 30):
    """Ritorna (status_code, parsed_json_or_None, raw_text). Niente eccezioni su 4xx/5xx."""
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    data = body.encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=FHIR_HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
            text = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        status = e.code
        text = e.read().decode("utf-8", errors="replace")
    try:
        parsed = json.loads(text) if text else None
    except json.JSONDecodeError:
        parsed = None
    return status, parsed, text


def fhir_conditional_put(hapi_url: str, resource: dict) -> dict | None:
    rt      = resource["resourceType"]
    url     = resource["url"]
    version = resource["version"]
    title   = resource.get("title") or rt

    st, js, _ = http_json("GET", f"{hapi_url}/{rt}",
                          params={"url": url, "version": version, "_elements": "id"},
                          timeout=30)
    existing_id = None
    if st == 200 and js:
        entries = js.get("entry", [])
        if entries:
            existing_id = entries[0]["resource"]["id"]

    body = json.dumps(resource)
    print(f"  [{rt}] payload {len(body)/1024/1024:.1f} MB, invio (timeout {PUT_TIMEOUT}s)...")
    if existing_id:
        resource["id"] = existing_id
        body = json.dumps(resource)
        st, js, text = http_json("PUT", f"{hapi_url}/{rt}/{existing_id}",
                                 body=body, timeout=PUT_TIMEOUT)
        verb = "PUT"
    else:
        st, js, text = http_json("POST", f"{hapi_url}/{rt}",
                                 body=body, timeout=PUT_TIMEOUT)
        verb = "POST"

    if st not in (200, 201):
        print(f"  ERRORE [{verb}] {rt} '{title}': HTTP {st}")
        print(f"  {text[:500]}")
        return None
    print(f"  OK {rt}/{(js or {}).get('id')} v{version}  '{title}'  [{verb}]")
    return js


def list_versions(hapi_url: str) -> None:
    st, js, text = http_json("GET", f"{hapi_url}/CodeSystem",
                             params={"url": CS_URL, "_elements": "id,version,date,count",
                                     "_count": "50"}, timeout=30)
    if st != 200 or not js:
        print(f"Errore: {st} {text[:200]}")
        return
    entries = js.get("entry", [])
    if not entries:
        print(f"Nessuna versione di {CS_URL} su HAPI.")
        return
    print(f"\nVersioni CodeSystem su HAPI ({CS_URL}):")
    print(f"  {'Versione':<12} {'Data':<12} {'Concetti':<10} ID FHIR")
    for e in entries:
        res = e["resource"]
        print(f"  {res.get('version','?'):<12} {res.get('date','?')[:10]:<12} "
              f"{str(res.get('count','?')):<10} {res.get('id','?')}")


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    global CS_URL, VS_URL
    args    = parse_args()
    hapi    = args.hapi_url
    version = args.version or date.today().strftime("%Y-%m")
    if args.cs_url:
        CS_URL = args.cs_url
    if args.vs_url:
        VS_URL = args.vs_url

    if args.list:
        print(f"HAPI FHIR: {hapi}")
        list_versions(hapi)
        return

    csv_file = resolve_csv(args.csv, version)
    print(f"HAPI FHIR : {hapi}")
    print(f"Versione  : {version}")
    print(f"CSV       : {csv_file}")
    if args.limit:
        print(f"LIMIT     : {args.limit} confezioni")
    print()

    print("=== Lettura confezioni.csv ===")
    confezioni = parse_confezioni(csv_file, args.limit)

    print("\n=== Build risorse FHIR ===")
    if args.slim:
        print("  [SLIM] property droppate, solo display + designation")
    cs = build_codesystem(confezioni, version, slim=args.slim)
    vs = build_valueset(version)

    if args.dry_run:
        out = args.out or os.path.join(SCRIPT_DIR, "codesystem-confezioni-atc.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(cs, f, ensure_ascii=False)
        size = os.path.getsize(out)
        print(f"\n[DRY-RUN] CodeSystem scritto: {out} ({size/1024/1024:.1f} MB)")
        print("[DRY-RUN] Nessun PUT su HAPI.")
        return

    print("\n=== Upload su HAPI FHIR ===")
    if fhir_conditional_put(hapi, cs) is None:
        print("\nUpload CodeSystem fallito — interrotto (ValueSet non caricato).")
        sys.exit(1)
    fhir_conditional_put(hapi, vs)

    print(f"\nFatto! (versione {version})")
    list_versions(hapi)
    print("\nQuery utili:")
    print(f"  Cerca PA   : GET {hapi}/ValueSet/$expand?url={VS_URL}&filter=<PA>&includeDesignations=true")
    print(f"  Lookup AIC : GET {hapi}/CodeSystem/$lookup?system={CS_URL}&code=<AIC>")


if __name__ == "__main__":
    main()
