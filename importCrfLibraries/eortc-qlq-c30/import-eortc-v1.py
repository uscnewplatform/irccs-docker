#!/usr/bin/env python3
"""
Import EORTC QLQ-C30 v1 come CodeSystem, ValueSet e StructureDefinition su HAPI FHIR.

Uso:
    python3 import-eortc-v1.py <excel> [HAPI_URL] [--bundle-only] [--list]

Argomenti:
    excel               Percorso del file Excel EORTC QLQ-C30
                        (es. "eortc-qlq-c30.xlsx")
    HAPI_URL            URL base di HAPI FHIR (default: http://localhost:8080/fhir)
    --bundle-only       Genera solo eortc-v1-bundle.json senza caricare su HAPI
    --list              Mostra le risorse EORTC v1 già caricate su HAPI ed esce

Esempi:
    python3 import-eortc-v1.py eortc-qlq-c30.xlsx --bundle-only
    python3 import-eortc-v1.py eortc-qlq-c30.xlsx https://hapi.irccs.infocube.it/fhir

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

CS_URL = "https://www.eortc.org/qlq-c30"
VS_URL = "https://www.eortc.org/qlq-c30-items"
SD_URL = "https://irccs-pascale.it/fhir/StructureDefinition/eortc-v1-grade-severity"

VERSION = "1.0"

# ─── Lettura Excel ────────────────────────────────────────────────────────────

_EMPTY = {"-", "–", "null", "NULL", "NULL\n", " -", ""}


def _testo(val) -> str:
    if val is None:
        return ""
    s = str(val).strip()
    return "" if s in _EMPTY else s


def _code(val) -> str:
    """Normalizza numquest (può essere float 1.0) → stringa '1'."""
    if val is None:
        return ""
    s = str(val).strip()
    if s in _EMPTY:
        return ""
    try:
        return str(int(float(s)))
    except (ValueError, OverflowError):
        return s


def leggi_termini(percorso_excel: str) -> list[dict]:
    print(f"  Lettura Excel: {percorso_excel}")
    wb = openpyxl.load_workbook(percorso_excel, read_only=True, data_only=True)
    ws = wb.worksheets[0]
    termini = []
    for i, row in enumerate(ws.iter_rows(values_only=True)):
        if i == 0:
            continue  # intestazione
        code  = _code(row[0] if len(row) > 0 else None)
        head  = _testo(row[1] if len(row) > 1 else None)
        quest = _testo(row[2] if len(row) > 2 else None)
        if not quest:
            continue
        if not code:
            continue
        answs = []
        for col in range(3, 10):
            answs.append(_testo(row[col] if len(row) > col else None))

        termini.append({
            "code":    code,
            "head":    head,
            "quest":   quest,
            "answers": answs,
        })
    wb.close()
    heads = set(t["head"] for t in termini if t["head"])
    print(f"  Termini letti: {len(termini)} (da {len(heads)} sezioni)")
    return termini


# ─── Costruzione risorse FHIR ─────────────────────────────────────────────────

def build_codesystem(termini: list[dict]) -> dict:
    concetti = []
    for t in termini:
        props = []
        if t["head"]:
            props.append({"code": "head", "valueString": t["head"]})
        for i, ans in enumerate(t["answers"], 1):
            if ans:
                props.append({"code": f"answ{i}", "valueString": ans})
        concetti.append({
            "code":     t["code"],
            "display":  t["quest"],
            "property": props,
        })

    # number = numquest del concept (fallback: ordine 1..N se non numerico).
    for _n, _c in enumerate(concetti, 1):
        try:
            _num = int(str(_c["code"]).strip())
        except (ValueError, TypeError):
            _num = _n
        _c.setdefault("property", []).insert(0, {"code": "number", "valueInteger": _num})

    return {
        "resourceType": "CodeSystem",
        "id":           "eortc-v1",
        "url":          CS_URL,
        "version":      VERSION,
        "name":         "EORTCQLQv1",
        "title":        "EORTC QLQ-C30 Quality of Life Questionnaire",
        "status":       "active",
        "content":      "complete",
        "date":         str(date.today()),
        "description":  (
            f"European Organisation for Research and Treatment of Cancer "
            f"Quality of Life Questionnaire Core 30 (QLQ-C30). "
            f"{len(concetti)} items."
        ),
        "publisher":    "EORTC / IRCCS Pascale",
        "copyright":    "EORTC QLQ-C30",
        "property": [
            {"code": "number", "description": "Numero della domanda (numquest)", "type": "integer"},
            {"code": "head",  "description": "Sezione / dominio del questionario", "type": "string"},
            {"code": "answ1", "description": "Risposta 1",                         "type": "string"},
            {"code": "answ2", "description": "Risposta 2",                         "type": "string"},
            {"code": "answ3", "description": "Risposta 3",                         "type": "string"},
            {"code": "answ4", "description": "Risposta 4",                         "type": "string"},
            {"code": "answ5", "description": "Risposta 5",                         "type": "string"},
            {"code": "answ6", "description": "Risposta 6",                         "type": "string"},
            {"code": "answ7", "description": "Risposta 7",                         "type": "string"},
        ],
        "concept": concetti,
    }


def build_valueset(termini: list[dict]) -> dict:
    concetti_vs = [
        {"code": t["code"], "display": t["quest"]}
        for t in termini if t["code"] and t["quest"]
    ]
    return {
        "resourceType": "ValueSet",
        "id":           "eortc-v1-items",
        "url":          VS_URL,
        "version":      VERSION,
        "name":         "EORTCQLQv1Items",
        "title":        "EORTC QLQ-C30 Items ValueSet",
        "status":       "active",
        "date":         str(date.today()),
        "description":  f"Tutti i {len(concetti_vs)} item EORTC QLQ-C30",
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
         "short": "Metadati EORTC QLQ-C30 su QuestionnaireItem"},
        {"id": "Extension.extension", "path": "Extension.extension",
         "slicing": {"discriminator": [{"type": "value", "path": "url"}], "rules": "open"}},
    ]
    elementi += slice_str("head", "Sezione / dominio del questionario")
    for i in range(1, 8):
        elementi += slice_str(f"answ{i}", f"Risposta {i}")
    elementi += [
        {"id": "Extension.url",      "path": "Extension.url",      "fixedUri": SD_URL},
        {"id": "Extension.value[x]", "path": "Extension.value[x]", "max": "0"},
    ]

    return {
        "resourceType": "StructureDefinition",
        "id":           "eortc-v1-grade-severity",
        "url":          SD_URL,
        "version":      "1.0",
        "name":         "EORTCv1GradeSeverity",
        "title":        "EORTC QLQ-C30 v1 Grade Severity Extension",
        "status":       "active",
        "date":         str(date.today()),
        "kind":         "complex-type",
        "abstract":     False,
        "context":      [{"type": "element", "expression": "QuestionnaireItem"}],
        "type":         "Extension",
        "baseDefinition": "http://hl7.org/fhir/StructureDefinition/Extension",
        "derivation":   "constraint",
        "description":  (
            "Estensione su QuestionnaireItem per EORTC QLQ-C30: sezione (head) e opzioni di risposta 1-7."
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
        print(f"    CodeSystem         → {url}/CodeSystem/eortc-v1")
        print(f"    ValueSet           → {url}/ValueSet/eortc-v1-items")
        print(f"    StructureDefinition→ {url}/StructureDefinition/eortc-v1-grade-severity")
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
    print(f"\nRisorse EORTC v1 su {url}:\n")

    for tipo, res_id in [
        ("CodeSystem",          "eortc-v1"),
        ("ValueSet",            "eortc-v1-items"),
        ("StructureDefinition", "eortc-v1-grade-severity"),
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
        description="Import EORTC QLQ-C30 → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("excel",     help="Percorso file Excel EORTC QLQ-C30")
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
    print("  EORTC QLQ-C30 v1 → HAPI FHIR")
    print("─" * 60)

    termini = leggi_termini(args.excel)

    print("  Costruzione risorse FHIR...")
    cs     = build_codesystem(termini)
    vs     = build_valueset(termini)
    sd     = build_structuredefinition()
    bundle = build_bundle(cs, vs, sd)

    script_dir = Path(__file__).parent
    bundle_out = script_dir / "eortc-v1-bundle.json"
    bundle_out.write_text(json.dumps(bundle, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  Bundle salvato: {bundle_out}  ({bundle_out.stat().st_size // 1024} KB)")

    if args.bundle_only:
        print("\n  --bundle-only: nessun push su HAPI.")
        return

    push_to_hapi(bundle, args.hapi_url)
    print("─" * 60)


if __name__ == "__main__":
    main()
