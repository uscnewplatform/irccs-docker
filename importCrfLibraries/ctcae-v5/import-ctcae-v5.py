#!/usr/bin/env python3
"""
Import CTCAE v5.0 come CodeSystem, ValueSet e StructureDefinition su HAPI FHIR.

Uso:
    python3 import-ctcae-v5.py <excel> [HAPI_URL] [--bundle-only] [--list]

Argomenti:
    excel               Percorso del file Excel NCI CTCAE v5
                        (es. "CTCAE_v5.0_2017-11-27.xlsx")
    HAPI_URL            URL base di HAPI FHIR (default: http://localhost:8080/fhir)
    --bundle-only       Genera solo ctcae-v5-bundle.json senza caricare su HAPI
    --list              Mostra le risorse CTCAE v5 già caricate su HAPI ed esce

Esempi:
    # Genera bundle e carica su HAPI locale
    python3 import-ctcae-v5.py "CTCAE_v5.0_2017-11-27.xlsx"

    # Carica su HAPI remoto
    python3 import-ctcae-v5.py ctcae.xlsx https://hapi.irccs.infocube.it/fhir

    # Solo bundle JSON, niente push
    python3 import-ctcae-v5.py ctcae.xlsx --bundle-only

    # Verifica cosa è già caricato su HAPI
    python3 import-ctcae-v5.py ctcae.xlsx --list

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

CS_URL = "https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v5"
VS_URL = "https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v5-adverse-events"
SD_URL = "https://irccs-pascale.it/fhir/StructureDefinition/ctcae-v5-grade-severity"

VERSION = "5.0"

# ─── Lettura Excel ────────────────────────────────────────────────────────────

def _testo(val) -> str:
    if val is None:
        return ""
    s = str(val).strip()
    return "" if s in ("-", "–", "null", "NULL", " -") else s


def leggi_termini(percorso_excel: str) -> list[dict]:
    print(f"  Lettura Excel: {percorso_excel}")
    wb = openpyxl.load_workbook(percorso_excel, read_only=True, data_only=True)
    # CTCAE v5 è nel primo foglio (indice 0)
    ws = wb.worksheets[0]
    termini = []
    for i, row in enumerate(ws.iter_rows(values_only=True)):
        if i == 0:
            continue  # intestazione
        code, soc, term, g1, g2, g3, g4, g5, defin, nav_note, change = (
            row[0], row[1], row[2], row[3], row[4],
            row[5], row[6], row[7], row[8], row[9], row[10]
        )
        code_str = ""
        if code is not None:
            code_str = _testo(str(int(float(str(code)))) if str(code).replace(".", "").isdigit() else code)
        if not code_str:
            continue
        termini.append({
            "code":       code_str,
            "soc":        _testo(soc),
            "term":       _testo(term),
            "grade1":     _testo(g1),
            "grade2":     _testo(g2),
            "grade3":     _testo(g3),
            "grade4":     _testo(g4),
            "grade5":     _testo(g5),
            "definition": _testo(defin),
            "navNote":    _testo(nav_note),
            "v5change":   _testo(change),
        })
    wb.close()
    print(f"  Termini letti: {len(termini)} (da {len(set(t['soc'] for t in termini))} SOC)")
    return termini

# ─── Costruzione risorse FHIR ─────────────────────────────────────────────────

def build_codesystem(termini: list[dict]) -> dict:
    concetti = []
    for t in termini:
        props = []
        for campo in ("soc", "grade1", "grade2", "grade3", "grade4", "grade5",
                      "navNote", "v5change"):
            if t[campo]:
                props.append({"code": campo, "valueString": t[campo]})
        c = {"code": t["code"], "display": t["term"], "property": props}
        if t["definition"]:
            c["definition"] = t["definition"]
        concetti.append(c)

    # Numero progressivo 1..N della domanda, continuo sull'intero file (ordine dei concept).
    for _n, _c in enumerate(concetti, 1):
        _c.setdefault("property", []).insert(0, {"code": "number", "valueInteger": _n})

    return {
        "resourceType": "CodeSystem",
        "id":           "ctcae-v5",
        "url":          CS_URL,
        "version":      VERSION,
        "name":         "CTCAEv5",
        "title":        "CTCAE v5.0 Adverse Events",
        "status":       "active",
        "content":      "complete",
        "date":         str(date.today()),
        "description":  (
            f"NCI Common Terminology Criteria for Adverse Events v5.0 (Novembre 2017). "
            f"{len(concetti)} termini."
        ),
        "publisher":    "NCI / IRCCS Pascale",
        "copyright":    "NCI CTCAE v5.0 – November 2017",
        "property": [
            {"code": "number",   "description": "Numero progressivo della domanda (1..N)", "type": "integer"},
            {"code": "soc",      "description": "System Organ Class MedDRA",  "type": "string"},
            {"code": "grade1",   "description": "Grade 1 description",         "type": "string"},
            {"code": "grade2",   "description": "Grade 2 description",         "type": "string"},
            {"code": "grade3",   "description": "Grade 3 description",         "type": "string"},
            {"code": "grade4",   "description": "Grade 4 description",         "type": "string"},
            {"code": "grade5",   "description": "Grade 5 (Death)",             "type": "string"},
            {"code": "navNote",  "description": "Navigational Note",           "type": "string"},
            {"code": "v5change", "description": "CTCAE v5.0 Change vs v4",     "type": "string"},
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
        "id":           "ctcae-v5-adverse-events",
        "url":          VS_URL,
        "version":      VERSION,
        "name":         "CTCAEv5AdverseEvents",
        "title":        "CTCAE v5.0 Adverse Events ValueSet",
        "status":       "active",
        "date":         str(date.today()),
        "description":  f"Tutti i {len(concetti_vs)} termini CTCAE v5.0",
        "compose": {
            "include": [{"system": CS_URL, "concept": concetti_vs}]
        },
    }


def build_structuredefinition() -> dict:
    """StructureDefinition CTCAE v5.0 — grade1-5, soc, navNote, v5change."""
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
         "short": "Metadati CTCAE v5.0 su QuestionnaireItem"},
        {"id": "Extension.extension", "path": "Extension.extension",
         "slicing": {"discriminator": [{"type": "value", "path": "url"}], "rules": "open"}},
    ]
    for i in range(1, 6):
        elementi += slice_str(f"grade{i}", f"Grade {i} – descrizione CTCAE v5.0")
    elementi += slice_str("soc",      "System Organ Class MedDRA")
    elementi += slice_str("navNote",  "Nota navigazionale NCI")
    elementi += slice_str("v5change", "Tipo variazione rispetto a CTCAE v4")
    elementi += [
        {"id": "Extension.url",      "path": "Extension.url",      "fixedUri": SD_URL},
        {"id": "Extension.value[x]", "path": "Extension.value[x]", "max": "0"},
    ]

    return {
        "resourceType": "StructureDefinition",
        "id":           "ctcae-v5-grade-severity",
        "url":          SD_URL,
        "version":      "1.0",
        "name":         "CtcaeV5GradeSeverity",
        "title":        "CTCAE v5.0 Grade Severity Extension",
        "status":       "active",
        "date":         str(date.today()),
        "kind":         "complex-type",
        "abstract":     False,
        "context":      [{"type": "element", "expression": "QuestionnaireItem"}],
        "type":         "Extension",
        "baseDefinition": "http://hl7.org/fhir/StructureDefinition/Extension",
        "derivation":   "constraint",
        "description": (
            "Estensione su QuestionnaireItem per CTCAE v5.0: gradi 1-5, SOC MedDRA, "
            "nota navigazionale e variazioni rispetto a v4."
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
        print(f"    CodeSystem         → {url}/CodeSystem/ctcae-v5")
        print(f"    ValueSet           → {url}/ValueSet/ctcae-v5-adverse-events")
        print(f"    StructureDefinition→ {url}/StructureDefinition/ctcae-grade-severity")
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
    print(f"\nRisorse CTCAE v5 su {url}:\n")

    for tipo, res_id in [
        ("CodeSystem",          "ctcae-v5"),
        ("ValueSet",            "ctcae-v5-adverse-events"),
        ("StructureDefinition", "ctcae-grade-severity"),
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
        description="Import CTCAE v5.0 → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("excel",     help="Percorso file Excel CTCAE v5.0 NCI")
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
    print("  CTCAE v5.0 → HAPI FHIR")
    print("─" * 60)

    termini = leggi_termini(args.excel)

    print("  Costruzione risorse FHIR...")
    cs     = build_codesystem(termini)
    vs     = build_valueset(termini)
    sd     = build_structuredefinition()
    bundle = build_bundle(cs, vs, sd)

    script_dir = Path(__file__).parent
    bundle_out = script_dir / "ctcae-v5-bundle.json"
    bundle_out.write_text(json.dumps(bundle, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  Bundle salvato: {bundle_out}  ({bundle_out.stat().st_size // 1024} KB)")

    if args.bundle_only:
        print("\n  --bundle-only: nessun push su HAPI.")
        return

    push_to_hapi(bundle, args.hapi_url)
    print("─" * 60)


if __name__ == "__main__":
    main()
