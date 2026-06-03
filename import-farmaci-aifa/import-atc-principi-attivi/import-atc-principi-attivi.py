#!/usr/bin/env python3
"""
Import principi attivi (ATC) come CodeSystem e ValueSet FHIR in HAPI.

Sorgente: confezioni.csv (export AIFA "lista confezioni").
Modello: UN concetto per coppia (ATC, principio attivo).
    - code     = AIC rappresentante della coppia (codice AIFA reale, univoco)
    - display  = principio attivo (PA_ASSOCIATI) esatto
    - property atc = CODICE_ATC, property aic = code (AIC)
    Niente designation.

Perche code = AIC (rappresentante) e non ATC puro:
    ATC <-> PA e many-to-many (709 ATC hanno piu PA, 261 PA hanno piu ATC).
    FHIR impone CodeSystem.concept.code univoco. L'AIC e' un codice AIFA reale e
    univoco; ogni coppia (ATC, PA) ha >=1 AIC, se ne sceglie uno come rappresentante.
    Linkabile a farmaci-aifa (CodeSystem .../farmaci, code = AIC).

Registro (stabilita del code):
    pa-aic-registry.json mappa "<ATC>|<PA>" -> AIC scelto la prima volta (AIC minimo).
    Ad ogni run le coppie gia note RIUSANO l'AIC registrato (anche se quella confezione
    e' sparita dal CSV) -> il code NON cambia mai -> le QuestionnaireResponse gia salvate
    restano valide. Senza registro il rappresentante slitterebbe se la confezione viene
    ritirata. Il registro e' la fonte di verita: va conservato/versionato.

Versionamento:
    PUT su id fisso -> "ultima versione sovrascrive" (niente coesistenza multi-versione:
    answerValueSet non ha versione, espande sempre l'ultima). Col registro i code restano
    stabili anche dopo un re-import.
    Il CSV usato viene archiviato in <version>/confezioni.csv (snapshot/audit).

Uso:
    python3 import-atc-principi-attivi.py [HAPI_URL] [opzioni]

    HAPI_URL              URL base HAPI FHIR (default: http://localhost:8080/fhir)
    --csv PATH            CSV sorgente (default: <version>/confezioni.csv, poi ./confezioni.csv)
    --version YYYY-MM     Versione catalogo (default: mese corrente)
    --files-only          Genera solo i JSON, niente upload su HAPI
    --no-upload           Alias di --files-only
    --list                Elenca le versioni gia su HAPI ed esce
    --include-nd          Includi anche PA = "N.D." (default: escluse)
    --no-archive          Non archiviare lo snapshot CSV in <version>/

Output file (cartella dello script):
    CodeSystem-ATC.json
    ValueSet-ATC.json
    pa-aic-registry.json       (registro "ATC|PA" -> AIC, da CONSERVARE/versionare)
    <version>/confezioni.csv   (snapshot della sorgente, salvo --no-archive)

Risorse FHIR (id fissi -> PUT idempotente, niente duplicati ri-eseguendo):
    CodeSystem  http://terminology.hl7.it/CodeSystem/aifa-atc-principi-attivi
    ValueSet    http://terminology.hl7.it/ValueSet/aifa-atc-all

Uso nei Questionnaire:
    "item": [{ "type": "choice",
               "answerValueSet": "http://terminology.hl7.it/ValueSet/aifa-atc-all" }]
    (HAPI deve avere caricati sia il ValueSet sia il CodeSystem per l'$expand)
"""

import argparse
import csv
import json
import os
import shutil
import sys
from datetime import date

import requests

# ── costanti ──────────────────────────────────────────────────────────────────

HAPI_URL_DEFAULT = "http://localhost:8080/fhir"

CS_ID  = "aifa-atc-principi-attivi"
VS_ID  = "aifa-atc-all"
CS_URL = "http://terminology.hl7.it/CodeSystem/aifa-atc-principi-attivi"
VS_URL = "http://terminology.hl7.it/ValueSet/aifa-atc-all"

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REGISTRY_PATH = os.path.join(SCRIPT_DIR, "pa-aic-registry.json")

# colonne CSV (separatore ';')
COL_ATC = "CODICE_ATC"
COL_PA  = "PA_ASSOCIATI"
COL_AIC = "CODICE_AIC"

FHIR_HEADERS = {
    "Content-Type": "application/fhir+json",
    "Accept":       "application/fhir+json",
}


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="Import principi attivi (ATC) in HAPI FHIR come CodeSystem/ValueSet."
    )
    p.add_argument("hapi_url", nargs="?", default=HAPI_URL_DEFAULT,
                   help=f"URL base HAPI FHIR (default: {HAPI_URL_DEFAULT})")
    p.add_argument("--csv", default=None,
                   help="CSV sorgente (default: <version>/confezioni.csv, poi ./confezioni.csv)")
    p.add_argument("--version", default=None,
                   help="Versione YYYY-MM (default: mese corrente)")
    p.add_argument("--files-only", "--no-upload", dest="files_only",
                   action="store_true", help="Genera solo i JSON, niente upload")
    p.add_argument("--list", action="store_true",
                   help="Elenca le versioni gia su HAPI ed esce")
    p.add_argument("--include-nd", action="store_true",
                   help='Includi anche PA = "N.D." (default: escluse)')
    p.add_argument("--no-archive", action="store_true",
                   help="Non archiviare lo snapshot CSV in <version>/")
    return p.parse_args()


def version_dir(version: str) -> str:
    return os.path.join(SCRIPT_DIR, version)


def resolve_csv(arg_csv: str | None, version: str) -> str:
    """Risolve il CSV: --csv esplicito, poi <version>/confezioni.csv, poi ./confezioni.csv."""
    if arg_csv:
        return arg_csv
    snapshot = os.path.join(version_dir(version), "confezioni.csv")
    if os.path.exists(snapshot):
        return snapshot
    return os.path.join(SCRIPT_DIR, "confezioni.csv")


def archive_csv(src: str, version: str) -> str | None:
    """Copia il CSV sorgente in <version>/confezioni.csv (snapshot). No-op se gia li."""
    dest = os.path.join(version_dir(version), "confezioni.csv")
    if os.path.abspath(src) == os.path.abspath(dest):
        return None
    os.makedirs(version_dir(version), exist_ok=True)
    shutil.copy2(src, dest)
    return dest


# ── parse CSV ───────────────────────────────────────────────────────────────--

def parse_confezioni(path: str, include_nd: bool) -> dict[tuple[str, str], dict]:
    """
    Ritorna: (atc, pa) -> {"min_aic": <AIC minimo della coppia>, "count": n_confezioni}.
    min_aic = candidato per il code di una coppia NUOVA (le coppie gia note usano il registro).
    Salta righe senza ATC/AIC. Salta PA vuote e (di default) 'N.D.'.
    """
    if not os.path.exists(path):
        sys.exit(f"ERRORE: CSV non trovato: {path}")

    pairs: dict[tuple[str, str], dict] = {}
    n_rows = n_skip = 0
    with open(path, encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            atc = (row.get(COL_ATC) or "").strip().upper()
            pa  = (row.get(COL_PA) or "").strip().upper()
            aic = (row.get(COL_AIC) or "").strip()
            if not atc or not aic:
                n_skip += 1
                continue
            if not pa or (pa == "N.D." and not include_nd):
                n_skip += 1
                continue
            key = (atc, pa)
            entry = pairs.get(key)
            if entry is None:
                pairs[key] = {"min_aic": aic, "count": 1}
            else:
                entry["count"] += 1
                if aic < entry["min_aic"]:   # AIC zero-padded a larghezza fissa -> min lessicografico = min numerico
                    entry["min_aic"] = aic
            n_rows += 1
    print(f"  Righe valide: {n_rows}  |  scartate (no ATC/AIC / PA vuota / N.D.): {n_skip}")
    return pairs


# ── registro PA->AIC (congela il code rappresentante tra versioni) ──────────────

def load_registry() -> dict[str, str]:
    """Registro 'ATC|PA' -> AIC. Fonte di verita della stabilita dei code."""
    if os.path.exists(REGISTRY_PATH):
        with open(REGISTRY_PATH, encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_registry(reg: dict[str, str]) -> None:
    with open(REGISTRY_PATH, "w", encoding="utf-8") as f:
        json.dump(reg, f, ensure_ascii=False, indent=2, sort_keys=True)


def reg_key(atc: str, pa: str) -> str:
    return f"{atc}|{pa}"


# ── FHIR build ────────────────────────────────────────────────────────────────

def build_codesystem(pairs: dict[tuple[str, str], dict], registry: dict[str, str],
                     version: str) -> tuple[dict, int]:
    """
    Assegna code = AIC rappresentante. Coppie gia nel registro -> riusa l'AIC congelato
    (anche se la confezione e sparita dal CSV -> code stabile per lo storico).
    Coppie nuove -> min_aic dal CSV, registrato.
    Ritorna (codeSystem, n_nuove_coppie). Muta `registry` in-place.
    """
    n_new = 0
    concepts = []
    for (atc, pa) in sorted(pairs):
        k = reg_key(atc, pa)
        code = registry.get(k)
        if code is None:
            code = pairs[(atc, pa)]["min_aic"]
            registry[k] = code
            n_new += 1
        concepts.append({
            "code":     code,
            "display":  pa,
            "property": [
                {"code": "atc", "valueCode": atc},
                {"code": "aic", "valueString": code},
            ],
        })

    cs = {
        "resourceType": "CodeSystem",
        "id":           CS_ID,
        "url":          CS_URL,
        "version":      version,
        "name":         "AIFAATCPrincipiAttivi",
        "title":        "Principi Attivi per codice ATC (AIFA)",
        "status":       "active",
        "experimental": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
        "description": (
            f"Principi attivi dei farmaci autorizzati (sorgente: confezioni AIFA) — "
            f"versione {version}. Un concetto per coppia (ATC, principio attivo); "
            "code = AIC rappresentante (congelato via registro), display = principio "
            "attivo, property 'atc' = codice ATC."
        ),
        "caseSensitive": True,
        "content":       "complete",
        "property": [
            {"code": "atc", "type": "code",   "description": "Codice ATC del principio attivo"},
            {"code": "aic", "type": "string", "description": "AIC rappresentante (= code)"},
        ],
        "count":         len(concepts),
        "concept":       concepts,
    }
    return cs, n_new


def build_valueset(version: str) -> dict:
    return {
        "resourceType": "ValueSet",
        "id":           VS_ID,
        "url":          VS_URL,
        "version":      version,
        "name":         "AIFAATCAll",
        "title":        "Principi Attivi ATC (tutti) - AIFA",
        "status":       "active",
        "experimental": False,
        "date":         str(date.today()),
        "publisher":    "AIFA - Agenzia Italiana del Farmaco",
        "description":  f"Tutti i principi attivi per codice ATC — versione {version}.",
        "compose":      {"include": [{"system": CS_URL, "version": version}]},
    }


# ── HAPI helpers ──────────────────────────────────────────────────────────────

def fhir_put_by_id(hapi_url: str, resource: dict) -> bool:
    """PUT idempotente su id fisso."""
    rt  = resource["resourceType"]
    rid = resource["id"]
    r = requests.put(
        f"{hapi_url}/{rt}/{rid}",
        data=json.dumps(resource),
        headers=FHIR_HEADERS,
        timeout=300,
    )
    if r.status_code not in (200, 201):
        print(f"  ERRORE [PUT] {rt}/{rid}: HTTP {r.status_code}")
        print(f"  {r.text[:400]}")
        return False
    action = "creato" if r.status_code == 201 else "aggiornato"
    print(f"  OK {rt}/{rid} v{resource['version']}  [{action}]")
    return True


def list_versions(hapi_url: str) -> None:
    r = requests.get(
        f"{hapi_url}/CodeSystem",
        params={"url": CS_URL, "_elements": "id,version,date,count", "_count": "50"},
        headers=FHIR_HEADERS, timeout=30,
    )
    if not r.ok:
        print(f"Errore: {r.status_code} {r.text[:200]}")
        return
    entries = r.json().get("entry", [])
    if not entries:
        print("Nessuna versione del CodeSystem ATC trovata su HAPI.")
        return
    print(f"\nVersioni CodeSystem su HAPI ({CS_URL}):\n")
    print(f"  {'Versione':<12} {'Data':<12} {'Concetti':<10} ID FHIR")
    print(f"  {'-'*12} {'-'*12} {'-'*10} {'-'*36}")
    for e in entries:
        res = e["resource"]
        print(f"  {res.get('version','?'):<12} {res.get('date','?')[:10]:<12} "
              f"{res.get('count','?'):<10} {res.get('id','?')}")


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    args    = parse_args()
    hapi    = args.hapi_url
    version = args.version or date.today().strftime("%Y-%m")

    if args.list:
        print(f"HAPI FHIR: {hapi}")
        list_versions(hapi)
        return

    csv_src = resolve_csv(args.csv, version)
    print(f"HAPI FHIR : {hapi}")
    print(f"Versione  : {version}")
    print(f"CSV       : {csv_src}\n")

    print("=== Parsing confezioni.csv ===")
    pairs = parse_confezioni(csv_src, args.include_nd)
    n_atc = len({atc for (atc, _) in pairs})
    n_pa  = len({pa for (_, pa) in pairs})
    print(f"  Coppie ATC+PA: {len(pairs)}  |  ATC distinti: {n_atc}  |  PA distinte: {n_pa}")

    registry = load_registry()
    print(f"  Registro PA->AIC: {len(registry)} coppie note ({REGISTRY_PATH})")

    print("\n=== Build risorse FHIR ===")
    cs, n_new = build_codesystem(pairs, registry, version)
    vs = build_valueset(version)
    print(f"  CodeSystem v{version}: {cs['count']} concetti (code = AIC, 1 per coppia ATC+PA)")
    print(f"  Coppie nuove (AIC assegnato ora): {n_new}")
    print(f"  ValueSet  v{version}: include tutto il CodeSystem")

    save_registry(registry)
    print(f"  Registro aggiornato: {REGISTRY_PATH} ({len(registry)} coppie)")

    cs_path = os.path.join(SCRIPT_DIR, "CodeSystem-ATC.json")
    vs_path = os.path.join(SCRIPT_DIR, "ValueSet-ATC.json")
    with open(cs_path, "w", encoding="utf-8") as f:
        json.dump(cs, f, ensure_ascii=False, indent=2)
    with open(vs_path, "w", encoding="utf-8") as f:
        json.dump(vs, f, ensure_ascii=False, indent=2)
    print(f"\n  Scritto: {cs_path}")
    print(f"  Scritto: {vs_path}")

    if not args.no_archive:
        archived = archive_csv(csv_src, version)
        if archived:
            print(f"  Snapshot CSV: {archived}")

    if args.files_only:
        print("\n--files-only: niente upload su HAPI.")
    else:
        print("\n=== Upload su HAPI FHIR (PUT idempotente) ===")
        ok_cs = fhir_put_by_id(hapi, cs)   # CodeSystem prima (il ValueSet lo referenzia)
        ok_vs = fhir_put_by_id(hapi, vs)
        if ok_cs and ok_vs:
            list_versions(hapi)

    print()
    print("Uso nei Questionnaire (answerValueSet):")
    print(f"  {VS_URL}")
    print("Query HAPI utili:")
    print(f"  Cerca PA       : GET {hapi}/ValueSet/$expand?url={VS_URL}&filter=<nome>")
    print(f"  Lookup AIC     : GET {hapi}/CodeSystem/$lookup?system={CS_URL}&code=<AIC>")
    print(f"  Validate AIC   : GET {hapi}/CodeSystem/$validate-code?url={CS_URL}&code=<AIC>")


if __name__ == "__main__":
    main()
