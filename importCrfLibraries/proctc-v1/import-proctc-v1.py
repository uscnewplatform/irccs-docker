#!/usr/bin/env python3
"""
Import PRO-CTCAE v1 come CodeSystem, ValueSet e StructureDefinition su HAPI FHIR.

Uso:
    python3 import-proctc-v1.py <excel> [HAPI_URL] [--bundle-only] [--list]

Argomenti:
    excel               Percorso del file Excel PRO-CTCAE v1
                        (es. "uosc_proctcaev1.xlsx")
    HAPI_URL            URL base di HAPI FHIR (default: http://localhost:8080/fhir)
    --bundle-only       Genera solo proctc-v1-bundle.json senza caricare su HAPI
    --list              Mostra le risorse PRO-CTCAE v1 già caricate su HAPI ed esce

Esempi:
    python3 import-proctc-v1.py uosc_proctcaev1.xlsx --bundle-only
    python3 import-proctc-v1.py uosc_proctcaev1.xlsx https://hapi.irccs.infocube.it/fhir

Richiede:
    pip install openpyxl requests
"""

import json
import sys
import argparse
from pathlib import Path
from datetime import date

try:
    import openpyxl
except ImportError:
    print("ERRORE: openpyxl non installato. Esegui: pip install openpyxl")
    sys.exit(1)

try:
    import requests
except ImportError:
    requests = None  # type: ignore

# ─── URL canoniche FHIR ───────────────────────────────────────────────────────

CS_URL = "https://healthcaredelivery.cancer.gov/pro-ctcae"
VS_URL = "https://healthcaredelivery.cancer.gov/pro-ctcae-adverse-events"
SD_URL = "https://irccs-pascale.it/fhir/StructureDefinition/proctc-v1-grade-severity"

VERSION = "1.0"

# ─── Lettura Excel ────────────────────────────────────────────────────────────

def _testo(val) -> str:
    if val is None:
        return ""
    s = str(val).strip()
    return "" if s in ("-", "–", "null", "NULL", "NULL\n", " -", "") else s


def leggi_termini(percorso_excel: str) -> list[dict]:
    print(f"  Lettura Excel: {percorso_excel}")
    wb = openpyxl.load_workbook(percorso_excel, read_only=True, data_only=True)
    ws = wb.worksheets[0]
    termini = []
    idx = 0
    for i, row in enumerate(ws.iter_rows(values_only=True)):
        if i == 0:
            continue  # intestazione
        macrogroup = _testo(row[0] if len(row) > 0 else None)
        category   = _testo(row[1] if len(row) > 1 else None)
        term       = _testo(row[2] if len(row) > 2 else None)
        if not term:
            continue
        idx += 1
        answs = []
        for col in range(3, 11):
            answs.append(_testo(row[col] if len(row) > col else None))
        interface  = _testo(row[11] if len(row) > 11 else None)

        termini.append({
            "code":       f"PROCTC-{idx:04d}",
            "macrogroup": macrogroup,
            "category":   category,
            "term":       term,
            "interface":  interface,
            "answers":    answs,
        })
    wb.close()
    macrogroups = set(t["macrogroup"] for t in termini if t["macrogroup"])
    print(f"  Termini letti: {len(termini)} (da {len(macrogroups)} macrogruppi)")
    return termini


# ─── Costruzione risorse FHIR ─────────────────────────────────────────────────

def build_codesystem(termini: list[dict]) -> dict:
    concetti = []
    for t in termini:
        props = []
        if t["macrogroup"]:
            props.append({"code": "macrogroup", "valueString": t["macrogroup"]})
        if t["category"]:
            props.append({"code": "category", "valueString": t["category"]})
        if t["interface"]:
            props.append({"code": "interface", "valueString": t["interface"]})
        for i, ans in enumerate(t["answers"], 1):
            if ans:
                props.append({"code": f"answ{i}", "valueString": ans})
        concetti.append({
            "code":     t["code"],
            "display":  t["term"],
            "property": props,
        })

    # Numero progressivo 1..N della domanda, continuo sull'intero file (ordine dei concept).
    for _n, _c in enumerate(concetti, 1):
        _c.setdefault("property", []).insert(0, {"code": "number", "valueInteger": _n})

    return {
        "resourceType": "CodeSystem",
        "id":           "proctc-v1",
        "url":          CS_URL,
        "version":      VERSION,
        "name":         "PRO_CTCAEv1",
        "title":        "PRO-CTCAE v1 Patient-Reported Outcomes",
        "status":       "active",
        "content":      "complete",
        "date":         str(date.today()),
        "description":  (
            f"NCI Patient-Reported Outcomes version of CTCAE (PRO-CTCAE) v1. "
            f"{len(concetti)} termini."
        ),
        "publisher":    "NCI / IRCCS Pascale",
        "copyright":    "NCI PRO-CTCAE v1",
        "property": [
            {"code": "number",     "description": "Numero progressivo della domanda (1..N)", "type": "integer"},
            {"code": "macrogroup", "description": "Macrogruppo sintomatologico", "type": "string"},
            {"code": "category",   "description": "Categoria di sintomo",        "type": "string"},
            {"code": "interface",  "description": "Tipo di interfaccia UI",      "type": "string"},
            {"code": "answ1",      "description": "Risposta 1",                  "type": "string"},
            {"code": "answ2",      "description": "Risposta 2",                  "type": "string"},
            {"code": "answ3",      "description": "Risposta 3",                  "type": "string"},
            {"code": "answ4",      "description": "Risposta 4",                  "type": "string"},
            {"code": "answ5",      "description": "Risposta 5",                  "type": "string"},
            {"code": "answ6",      "description": "Risposta 6",                  "type": "string"},
            {"code": "answ7",      "description": "Risposta 7",                  "type": "string"},
            {"code": "answ8",      "description": "Risposta 8",                  "type": "string"},
        ],
        "concept": concetti,
    }


def build_valueset(termini: list[dict]) -> dict:
    concetti_vs = [
        {"code": t["code"], "display": t["term"]}
        for t in termini if t["code"] and t["term"]
    ]
    return {
        "resourceType": "ValueSet",
        "id":           "proctc-v1-adverse-events",
        "url":          VS_URL,
        "version":      VERSION,
        "name":         "PRO_CTCAEv1AdverseEvents",
        "title":        "PRO-CTCAE v1 Adverse Events ValueSet",
        "status":       "active",
        "date":         str(date.today()),
        "description":  f"Tutti i {len(concetti_vs)} termini PRO-CTCAE v1",
        "compose": {
            "include": [{"system": CS_URL, "concept": concetti_vs}]
        },
    }


def build_structuredefinition() -> dict:
    def slice_str(name: str, short: str) -> list[dict]:
        return [
            {"id": f"Extension.extension:{name}", "path": "Extension.extension",
             "sliceName": name, "short": short, "min": 0, "max": "1"},
            {"id": f"Extension.extension:{name}.url", "path": "Extension.extension.url",
             "fixedUri": name},
            {"id": f"Extension.extension:{name}.value[x]", "path": "Extension.extension.value[x]",
             "type": [{"code": "string"}]},
        ]

    elementi = [
        {"id": "Extension", "path": "Extension",
         "short": "Metadati PRO-CTCAE v1 su QuestionnaireItem"},
        {"id": "Extension.extension", "path": "Extension.extension",
         "slicing": {"discriminator": [{"type": "value", "path": "url"}], "rules": "open"}},
    ]
    elementi += slice_str("macrogroup", "Macrogruppo sintomatologico")
    elementi += slice_str("category",   "Categoria di sintomo")
    elementi += slice_str("interface",  "Tipo di interfaccia UI")
    for i in range(1, 9):
        elementi += slice_str(f"answ{i}", f"Risposta {i}")
    elementi += [
        {"id": "Extension.url",      "path": "Extension.url",      "fixedUri": SD_URL},
        {"id": "Extension.value[x]", "path": "Extension.value[x]", "max": "0"},
    ]

    return {
        "resourceType": "StructureDefinition",
        "id":           "proctc-v1-grade-severity",
        "url":          SD_URL,
        "version":      "1.0",
        "name":         "PRO_CTCAEv1GradeSeverity",
        "title":        "PRO-CTCAE v1 Grade Severity Extension",
        "status":       "active",
        "date":         str(date.today()),
        "kind":         "complex-type",
        "abstract":     False,
        "context":      [{"type": "element", "expression": "QuestionnaireItem"}],
        "type":         "Extension",
        "baseDefinition": "http://hl7.org/fhir/StructureDefinition/Extension",
        "derivation":   "constraint",
        "description":  (
            "Estensione su QuestionnaireItem per PRO-CTCAE v1: macrogruppo, categoria, "
            "interfaccia UI e opzioni di risposta 1-8."
        ),
        "differential": {"element": elementi},
    }


def build_bundle(cs: dict, vs: dict, sd: dict) -> dict:
    return {
        "resourceType": "Bundle",
        "type": "transaction",
        "entry": [
            {"resource": cs, "request": {"method": "PUT", "url": f"CodeSystem/{cs['id']}"}},
            {"resource": vs, "request": {"method": "PUT", "url": f"ValueSet/{vs['id']}"}},
            {"resource": sd, "request": {"method": "PUT", "url": f"StructureDefinition/{sd['id']}"}},
        ],
    }

# ─── Push su HAPI FHIR ────────────────────────────────────────────────────────

def push_to_hapi(bundle: dict, hapi_url: str) -> None:
    if requests is None:
        print("ERRORE: requests non installato. Esegui: pip install requests")
        sys.exit(1)

    url = hapi_url.rstrip("/")
    print(f"\n  Push su {url} ...")
    r = requests.post(
        url,
        json=bundle,
        headers={"Content-Type": "application/fhir+json"},
        timeout=120,
    )
    if r.status_code in (200, 201):
        print(f"  ✓ Caricamento completato (HTTP {r.status_code})")
        print(f"\n  Risorse caricate:")
        print(f"    CodeSystem         → {url}/CodeSystem/proctc-v1")
        print(f"    ValueSet           → {url}/ValueSet/proctc-v1-adverse-events")
        print(f"    StructureDefinition→ {url}/StructureDefinition/proctc-v1-grade-severity")
    else:
        print(f"  ✗ Errore HTTP {r.status_code}")
        try:
            print(json.dumps(r.json(), indent=2, ensure_ascii=False)[:2000])
        except Exception:
            print(r.text[:2000])
        sys.exit(1)

# ─── --list ──────────────────────────────────────────────────────────────────

def list_hapi(hapi_url: str) -> None:
    if requests is None:
        print("ERRORE: requests non installato. Esegui: pip install requests")
        sys.exit(1)

    url = hapi_url.rstrip("/")
    print(f"\nRisorse PRO-CTCAE v1 su {url}:\n")

    for tipo, res_id in [
        ("CodeSystem",          "proctc-v1"),
        ("ValueSet",            "proctc-v1-adverse-events"),
        ("StructureDefinition", "proctc-v1-grade-severity"),
    ]:
        r = requests.get(
            f"{url}/{tipo}/{res_id}",
            headers={"Accept": "application/fhir+json"},
            timeout=30,
        )
        if r.status_code == 200:
            data = r.json()
            versione = data.get("version", "—")
            data_mod = data.get("date", "—")
            print(f"  ✓ {tipo:<22} id={res_id}  versione={versione}  data={data_mod}")
        elif r.status_code == 404:
            print(f"  ✗ {tipo:<22} id={res_id}  NON TROVATO")
        else:
            print(f"  ? {tipo:<22} id={res_id}  HTTP {r.status_code}")

    print()

# ─── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Import PRO-CTCAE v1 → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("excel",     help="Percorso file Excel PRO-CTCAE v1 NCI")
    parser.add_argument("hapi_url",  nargs="?", default="http://localhost:8080/fhir",
                        help="URL base HAPI FHIR (default: http://localhost:8080/fhir)")
    parser.add_argument("--bundle-only", action="store_true",
                        help="Genera solo il bundle JSON, non carica su HAPI")
    parser.add_argument("--list",    action="store_true",
                        help="Mostra risorse già caricate su HAPI ed esce")

    args = parser.parse_args()

    if args.list:
        list_hapi(args.hapi_url)
        return

    print("─" * 60)
    print("  PRO-CTCAE v1 → HAPI FHIR")
    print("─" * 60)

    termini = leggi_termini(args.excel)

    print("  Costruzione risorse FHIR...")
    cs     = build_codesystem(termini)
    vs     = build_valueset(termini)
    sd     = build_structuredefinition()
    bundle = build_bundle(cs, vs, sd)

    script_dir = Path(__file__).parent
    bundle_out = script_dir / "proctc-v1-bundle.json"
    bundle_out.write_text(json.dumps(bundle, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  Bundle salvato: {bundle_out}  ({bundle_out.stat().st_size // 1024} KB)")

    if args.bundle_only:
        print("\n  --bundle-only: nessun push su HAPI.")
        return

    push_to_hapi(bundle, args.hapi_url)
    print("─" * 60)


if __name__ == "__main__":
    main()
