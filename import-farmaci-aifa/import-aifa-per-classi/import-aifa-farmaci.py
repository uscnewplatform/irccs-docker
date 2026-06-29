#!/usr/bin/env python3
"""
Import farmaci AIFA come CodeSystem e ValueSet versionati in HAPI FHIR.

Uso:
    python3 import-aifa-farmaci.py [HAPI_URL] [--version YYYY-MM] [--list]

Argomenti:
    HAPI_URL            URL base di HAPI FHIR (default: http://localhost:8080/fhir)
    --version YYYY-MM   Versione del catalogo (default: mese corrente, es. 2026-05)
    --list              Elenca le versioni già caricate su HAPI ed esce
    --force-download    Ignora i CSV locali e riscarica da aifa.gov.it

Struttura cartelle:
    import-farmaci-aifa/
    ├── import-aifa-farmaci.py
    ├── README.md
    ├── 2025-10/                 ← snapshot ottobre 2025
    │   ├── aifa_classe_a.csv
    │   ├── aifa_classe_h.csv
    │   └── aifa_equivalenti.csv
    └── 2026-05/                 ← snapshot maggio 2026
        ├── aifa_classe_a.csv
        ├── aifa_classe_h.csv
        └── aifa_equivalenti.csv

    Lo script legge i CSV dalla cartella con il nome uguale alla versione.
    Se la cartella non esiste la crea e scarica i CSV da aifa.gov.it.

Versionamento FHIR:
    Ogni import usa la stessa URL canonica con versione diversa.
    - Rieseguire la stessa versione  → PUT condizionale (aggiorna, no duplicati)
    - Eseguire con nuova versione    → crea nuove risorse, mantiene le vecchie

Risorse FHIR create/aggiornate:
    CodeSystem  https://aifa.gov.it/fhir/CodeSystem/farmaci
    ValueSet    https://aifa.gov.it/fhir/ValueSet/farmaci-classe-a
    ValueSet    https://aifa.gov.it/fhir/ValueSet/farmaci-classe-h
    ValueSet    https://aifa.gov.it/fhir/ValueSet/farmaci-aifa
    ValueSet    https://aifa.gov.it/fhir/ValueSet/farmaci-con-atc
"""

import argparse
import csv
import io
import json
import os
import sys
import warnings
from datetime import date

import requests
import urllib3

# ── costanti ──────────────────────────────────────────────────────────────────

HAPI_URL_DEFAULT = "http://localhost:8080/fhir"

CS_URL     = "https://aifa.gov.it/fhir/CodeSystem/farmaci"
VS_A_URL   = "https://aifa.gov.it/fhir/ValueSet/farmaci-classe-a"
VS_H_URL   = "https://aifa.gov.it/fhir/ValueSet/farmaci-classe-h"
VS_ALL_URL = "https://aifa.gov.it/fhir/ValueSet/farmaci-aifa"

# URL di download AIFA — aggiornare quando AIFA pubblica nuovi file
AIFA_BASE     = "https://www.aifa.gov.it/documents/20142/3635001"
CSV_A_URL     = f"{AIFA_BASE}/Classe_A_per_nome_commerciale_30-10-2025.csv"
CSV_H_URL     = f"{AIFA_BASE}/Classe_H_per_nome_commerciale_30-10-2025.csv"
CSV_EQUIV_URL = "https://www.aifa.gov.it/documents/20142/825643/Lista_farmaci_equivalenti.csv"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

FHIR_HEADERS = {
    "Content-Type": "application/fhir+json",
    "Accept":       "application/fhir+json",
}


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="Import farmaci AIFA in HAPI FHIR come CodeSystem/ValueSet versionati."
    )
    p.add_argument("hapi_url", nargs="?", default=HAPI_URL_DEFAULT,
                   help=f"URL base HAPI FHIR (default: {HAPI_URL_DEFAULT})")
    p.add_argument("--version", default=None,
                   help="Versione YYYY-MM (default: mese corrente). "
                        "Determina anche la sottocartella CSV da usare.")
    p.add_argument("--list", action="store_true",
                   help="Elenca le versioni già caricate su HAPI ed esce")
    p.add_argument("--force-download", action="store_true",
                   help="Forza il download dei CSV da aifa.gov.it anche se già presenti")
    p.add_argument("--no-verify-ssl", action="store_true",
                   help="Disabilita verifica certificato SSL (usa se aifa.gov.it non è raggiungibile per SSL)")
    return p.parse_args()


# ── cartella versione ─────────────────────────────────────────────────────────

def version_dir(version: str) -> str:
    return os.path.join(SCRIPT_DIR, version)


def csv_path(version: str, name: str) -> str:
    return os.path.join(version_dir(version), name)


# ── download / lettura locale ─────────────────────────────────────────────────

def load_csv(local_path: str, remote_url: str, force: bool = False,
             verify_ssl: bool = True) -> str:
    if not force and os.path.exists(local_path):
        print(f"  Locale  : {local_path}")
        with open(local_path, encoding="windows-1252", errors="replace") as f:
            return f.read()
    print(f"  Download: {remote_url}")
    r = requests.get(remote_url, timeout=60, verify=verify_ssl,
                     headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36"})
    r.raise_for_status()
    content = r.content.decode("windows-1252", errors="replace")
    os.makedirs(os.path.dirname(local_path), exist_ok=True)
    with open(local_path, "w", encoding="windows-1252", errors="replace") as f:
        f.write(content)
    return content


# ── parse ─────────────────────────────────────────────────────────────────────

def parse_equivalenti(content: str) -> dict[str, str]:
    atc_map: dict[str, str] = {}
    reader = csv.DictReader(io.StringIO(content), delimiter=";")
    for row in reader:
        aic = (row.get("AIC") or "").strip().zfill(9)  # normalizza a 9 cifre
        atc = (row.get("ATC") or "").strip()
        if aic and atc:
            atc_map[aic] = atc
    return atc_map


def parse_classe_a(content: str) -> list[dict]:
    drugs = []
    reader = csv.DictReader(io.StringIO(content), delimiter=";")
    for row in reader:
        aic  = (row.get("AIC") or "").strip()
        nome = (row.get("Denominazione e Confezione") or "").strip()
        if not aic or not nome:
            continue
        drugs.append({
            "code":               aic,
            "display":            nome,
            "principio_attivo":   (row.get("Principio Attivo") or "").strip(),
            "descrizione_gruppo": (row.get("Descrizione Gruppo") or "").strip(),
            "titolare":           (row.get("Titolare AIC") or "").strip(),
            "classe":             "A",
            "atc":                "",
        })
    return drugs


def parse_classe_h(content: str) -> list[dict]:
    AIC_KEY = "Codice \nAIC"   # header con newline nel CSV originale
    drugs = []
    reader = csv.DictReader(io.StringIO(content), delimiter=";")
    for row in reader:
        aic  = (row.get(AIC_KEY) or "").strip()
        nome = (row.get("Denominazione e Confezione") or "").strip()
        if not aic or not nome:
            continue
        drugs.append({
            "code":               aic,
            "display":            nome,
            "principio_attivo":   (row.get("Principio Attivo") or "").strip(),
            "descrizione_gruppo": (row.get("Descrizione Gruppo") or "").strip(),
            "titolare":           (row.get("Titolare AIC") or "").strip(),
            "classe":             "H",
            "atc":                "",
        })
    return drugs


def enrich_with_atc(drugs: list[dict], atc_map: dict[str, str]) -> int:
    matched = 0
    for d in drugs:
        atc = atc_map.get(d["code"], "")
        if atc:
            d["atc"] = atc
            matched += 1
    return matched


# ── FHIR build ────────────────────────────────────────────────────────────────

def build_codesystem(drugs: list[dict], version: str) -> dict:
    seen: set[str] = set()
    concepts = []
    for d in drugs:
        if d["code"] in seen:
            continue
        seen.add(d["code"])
        props = [
            {"code": "principio-attivo",   "valueString": d["principio_attivo"]},
            {"code": "descrizione-gruppo", "valueString": d["descrizione_gruppo"]},
            {"code": "titolare-aic",       "valueString": d["titolare"]},
            {"code": "classe",             "valueCode":   d["classe"]},
        ]
        if d["atc"]:
            props.append({"code": "atc", "valueCode": d["atc"]})
        nome_comm = d["display"]
        pa        = d["principio_attivo"]
        concept: dict = {
            "code":       d["code"],
            "display":    f"{pa} — {nome_comm}" if pa else nome_comm,
            "definition": nome_comm,
            "property":   props,
        }
        designations = []
        if d["principio_attivo"]:
            designations.append({
                "use":   {"system": "https://aifa.gov.it/fhir/CodeSystem/designation-use",
                          "code": "principio-attivo", "display": "Principio attivo"},
                "value": d["principio_attivo"],
            })
        if d["descrizione_gruppo"]:
            designations.append({
                "use":   {"system": "https://aifa.gov.it/fhir/CodeSystem/designation-use",
                          "code": "descrizione-gruppo", "display": "Descrizione gruppo equivalenza"},
                "value": d["descrizione_gruppo"],
            })
        if d["atc"]:
            designations.append({
                "use":   {"system": "https://aifa.gov.it/fhir/CodeSystem/designation-use",
                          "code": "atc", "display": "Codice ATC"},
                "value": d["atc"],
            })
        if designations:
            concept["designation"] = designations
        concepts.append(concept)
    return {
        "resourceType": "CodeSystem",
        "url":          CS_URL,
        "version":      version,
        "name":         "AIFAFarmaci",
        "title":        "Farmaci Autorizzati AIFA",
        "status":       "active",
        "experimental": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
        "description": (
            f"Farmaci autorizzati in Italia (Classe A e H) — versione {version}. "
            "Codice ATC disponibile per i farmaci presenti nella lista di trasparenza."
        ),
        "content": "complete",
        "count":   len(concepts),
        "filter": [
            {
                "code":        "classe",
                "description": "Filtra per classe di rimborsabilità",
                "operator":    ["="],
                "value":       "code A | H",
            },
        ],
        "property": [
            {"code": "principio-attivo",   "type": "string", "description": "Principio attivo"},
            {"code": "descrizione-gruppo", "type": "string", "description": "Descrizione gruppo equivalenza"},
            {"code": "titolare-aic",       "type": "string", "description": "Titolare AIC"},
            {"code": "classe",             "type": "code",   "description": "Classe di rimborsabilità (A o H)"},
            {"code": "atc",                "type": "code",   "description": "Codice ATC"},
        ],
        "concept": concepts,
    }


def build_valueset(url: str, name: str, title: str, description: str,
                   version: str, classe_filter: str | None = None) -> dict:
    """
    classe_filter "A"|"H" → property filter classe = A|H.
    Altrimenti include tutto il CodeSystem.
    """
    if classe_filter:
        include = {
            "system":  CS_URL,
            "version": version,
            "filter":  [{"property": "classe", "op": "=", "value": classe_filter}],
        }
    else:
        include = {"system": CS_URL, "version": version}

    return {
        "resourceType": "ValueSet",
        "url":          url,
        "version":      version,
        "name":         name,
        "title":        title,
        "status":       "active",
        "experimental": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
        "description":  f"{description} — versione {version}.",
        "compose":      {"include": [include]},
    }


# ── HAPI helpers ──────────────────────────────────────────────────────────────

def fhir_conditional_put(hapi_url: str, resource: dict) -> dict | None:
    """PUT condizionale: aggiorna se versione già esiste, crea altrimenti."""
    rt      = resource["resourceType"]
    url     = resource["url"]
    version = resource["version"]
    title   = resource.get("title") or resource.get("name") or rt

    search = requests.get(
        f"{hapi_url}/{rt}",
        params={"url": url, "version": version, "_elements": "id"},
        headers=FHIR_HEADERS,
        timeout=30,
    )
    existing_id = None
    if search.ok:
        entries = search.json().get("entry", [])
        if entries:
            existing_id = entries[0]["resource"]["id"]

    if existing_id:
        resource["id"] = existing_id
        r = requests.put(
            f"{hapi_url}/{rt}/{existing_id}",
            data=json.dumps(resource),
            headers=FHIR_HEADERS,
            timeout=180,
        )
        verb = "PUT"
    else:
        r = requests.post(
            f"{hapi_url}/{rt}",
            data=json.dumps(resource),
            headers=FHIR_HEADERS,
            timeout=180,
        )
        verb = "POST"

    if r.status_code not in (200, 201):
        print(f"  ERRORE [{verb}] {rt} '{title}': HTTP {r.status_code}")
        print(f"  {r.text[:400]}")
        return None

    result  = r.json()
    action  = "aggiornato" if existing_id else "creato"
    print(f"  OK {rt}/{result.get('id')} v{version}  '{title}'  [{action}]")
    return result


def list_versions(hapi_url: str) -> None:
    r = requests.get(
        f"{hapi_url}/CodeSystem",
        params={"url": CS_URL, "_elements": "id,version,date,count", "_count": "50"},
        headers=FHIR_HEADERS,
        timeout=30,
    )
    if not r.ok:
        print(f"Errore: {r.status_code} {r.text[:200]}")
        return

    entries = r.json().get("entry", [])
    if not entries:
        print("Nessuna versione del CodeSystem AIFA trovata su HAPI.")
        return

    # versioni locali (cartelle presenti)
    local_versions = sorted([
        d for d in os.listdir(SCRIPT_DIR)
        if os.path.isdir(os.path.join(SCRIPT_DIR, d)) and len(d) == 7 and d[4] == '-'
    ])

    print(f"\nVersioni CodeSystem su HAPI ({CS_URL}):\n")
    print(f"  {'Versione':<12} {'Data':<12} {'Concetti':<10} {'CSV locale':<12} ID FHIR")
    print(f"  {'-'*12} {'-'*12} {'-'*10} {'-'*12} {'-'*36}")
    for e in entries:
        res = e["resource"]
        ver = res.get("version", "?")
        has_local = "SI" if ver in local_versions else "-"
        print(f"  {ver:<12} {res.get('date','?')[:10]:<12} "
              f"{res.get('count','?'):<10} {has_local:<12} {res.get('id','?')}")

    not_uploaded = [v for v in local_versions
                    if v not in [e["resource"].get("version") for e in entries]]
    if not_uploaded:
        print(f"\n  Cartelle locali non ancora caricate su HAPI: {', '.join(not_uploaded)}")


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    args    = parse_args()
    hapi    = args.hapi_url
    version = args.version or date.today().strftime("%Y-%m")
    force   = args.force_download

    verify_ssl = not args.no_verify_ssl
    if not verify_ssl:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        print("ATTENZIONE: verifica SSL disabilitata (--no-verify-ssl)")

    if args.list:
        print(f"HAPI FHIR: {hapi}")
        list_versions(hapi)
        return

    vdir = version_dir(version)
    print(f"HAPI FHIR : {hapi}")
    print(f"Versione  : {version}")
    print(f"Cartella  : {vdir}\n")

    print("=== Caricamento CSV AIFA ===")
    drugs_a = parse_classe_a(
        load_csv(csv_path(version, "aifa_classe_a.csv"), CSV_A_URL, force, verify_ssl))
    print(f"  Classe A: {len(drugs_a)} farmaci")

    drugs_h = parse_classe_h(
        load_csv(csv_path(version, "aifa_classe_h.csv"), CSV_H_URL, force, verify_ssl))
    print(f"  Classe H: {len(drugs_h)} farmaci")

    atc_map = parse_equivalenti(
        load_csv(csv_path(version, "aifa_equivalenti.csv"), CSV_EQUIV_URL, force, verify_ssl))
    print(f"  Lista trasparenza: {len(atc_map)} AIC con ATC")

    print("\n=== Arricchimento con ATC ===")
    m_a = enrich_with_atc(drugs_a, atc_map)
    m_h = enrich_with_atc(drugs_h, atc_map)
    print(f"  Classe A: {m_a}/{len(drugs_a)} farmaci con ATC")
    print(f"  Classe H: {m_h}/{len(drugs_h)} farmaci con ATC")

    all_drugs = drugs_a + drugs_h

    print("\n=== Build risorse FHIR ===")
    cs = build_codesystem(all_drugs, version)
    print(f"  CodeSystem v{version}: {cs['count']} concetti")

    n_atc = sum(1 for d in all_drugs if d["atc"])
    print(f"  Farmaci con ATC: {n_atc}")

    vs_a   = build_valueset(VS_A_URL,   "AIFAFarmaciClasseA",  "Farmaci AIFA Classe A",
                            "Farmaci rimborsati dal SSN (Classe A) - AIFA",
                            version, classe_filter="A")
    vs_h   = build_valueset(VS_H_URL,   "AIFAFarmaciClasseH",  "Farmaci AIFA Classe H",
                            "Farmaci uso ospedaliero (Classe H) - AIFA",
                            version, classe_filter="H")
    vs_all = build_valueset(VS_ALL_URL, "AIFAFarmaciAll",       "Farmaci Autorizzati AIFA (Classe A e H)",
                            "Tutti i farmaci autorizzati AIFA (Classe A e H)",
                            version)

    print("\n=== Upload su HAPI FHIR ===")
    fhir_conditional_put(hapi, cs)
    fhir_conditional_put(hapi, vs_a)
    fhir_conditional_put(hapi, vs_h)
    fhir_conditional_put(hapi, vs_all)

    print(f"\nFatto! (versione {version})")
    list_versions(hapi)
    print()
    print("Query HAPI utili:")
    print(f"  Tutti i farmaci : GET {hapi}/ValueSet/$expand?url={VS_ALL_URL}&filter=<nome>")
    print(f"  Solo classe A   : GET {hapi}/ValueSet/$expand?url={VS_A_URL}&filter=<nome>")
    print(f"  Solo classe H   : GET {hapi}/ValueSet/$expand?url={VS_H_URL}&filter=<nome>")
    print(f"  Versione spec.  : GET {hapi}/ValueSet/$expand?url={VS_ALL_URL}&valueSetVersion={version}&filter=<nome>")
    print(f"  Lookup farmaco  : GET {hapi}/CodeSystem/$lookup?system={CS_URL}&code=<AIC>")
    print(f"  Validate AIC    : GET {hapi}/CodeSystem/$validate-code?url={CS_URL}&code=<AIC>")


if __name__ == "__main__":
    main()
