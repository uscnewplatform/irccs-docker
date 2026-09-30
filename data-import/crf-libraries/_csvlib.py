#!/usr/bin/env python3
"""
Helper condiviso per gli import-*.py delle CRF library a sorgente CSV.

Ogni cartella-libreria definisce una `LibConfig` e chiama `csvlib.main(cfg)`.
Il CSV è l'unica sorgente: nessun Excel, nessun id Excel collegato.

Schema CSV atteso (intestazione sulla prima riga):
    numquest, <display_col>, [colonne testo...], answ1, answ2, ...
dove:
    numquest      numero progressivo della domanda (1..N) → property `number`
    <display_col> testo mostrato come display del concept (es. quest / term)
    colonne testo property stringa aggiuntive (es. head, macrogroup, category)
    answ1..N      opzioni di risposta → property answ1..N

Colonne opzionali (sotto-domande condizionali e tipo risposta):
    code          code esplicito del concept (es. "8.1"); se assente si usa
                  code_fmt su numquest. Obbligatorio se numquest è vuoto.
    parent        code della domanda madre → property `parent`: la domanda
                  diventa una sotto-domanda condizionale (enableWhen all'import
                  CRF nel designer)
    showif        codici risposta della madre che rendono visibile la
                  sotto-domanda, separati da | (es. "2|3|4") → property `showif`
    answerType    multichoice | choice | open-choice | number → property
                  `answerType` (tipo di risposta all'import CRF)

Risorse generate: CodeSystem + ValueSet + StructureDefinition, impacchettate in
un Bundle transaction (PUT idempotenti). Push su HAPI via requests, oppure
`--bundle-only` per rigenerare solo il *-bundle.json committato.
"""

import csv
import json
import re
import sys
import argparse
from pathlib import Path
from datetime import date
from dataclasses import dataclass, field

try:
    import requests
except ImportError:
    requests = None  # type: ignore

_EMPTY = {"", "-", "–", "null", "NULL", "NULL\n", " -"}


# ─── Config libreria ──────────────────────────────────────────────────────────

@dataclass
class LibConfig:
    # identità risorse
    cs_id: str
    vs_id: str
    sd_id: str
    cs_url: str
    vs_url: str
    sd_url: str
    version: str
    # metadati CodeSystem / ValueSet
    cs_name: str
    cs_title: str
    vs_name: str
    vs_title: str
    sd_name: str
    sd_title: str
    publisher: str
    copyright: str
    description: str          # descrizione CodeSystem ({n} = numero concept)
    sd_description: str
    # mappa colonne CSV
    display_col: str          # header colonna display del concept (es. "quest", "term")
    text_props: list          # lista di (property_code, csv_header, descrizione)
    code_fmt: str = "{n}"     # formato del concept.code a partire da numquest ({n})
    item_label: str = "domande"   # etichetta usata nei print
    bundle_name: str = ""     # nome file bundle (default: {cs_id}-bundle.json)


# ─── Utility ──────────────────────────────────────────────────────────────────

def _testo(val) -> str:
    if val is None:
        return ""
    s = str(val).strip()
    return "" if s in _EMPTY else s


def _numquest(val):
    """numquest → int; None se non numerico/mancante."""
    s = _testo(val)
    if not s:
        return None
    try:
        return int(float(s))
    except (ValueError, OverflowError):
        return None


def _answ_headers(fieldnames) -> list:
    """Colonne answ1..N presenti nell'intestazione, ordinate per indice.
    Solo answ<numero>: esclude p.es. la colonna opzionale answerType."""
    ans = [h for h in fieldnames if h and re.fullmatch(r"answ\d+", h.lower())]
    return sorted(ans, key=lambda h: int(h[4:]))


# ─── Lettura CSV ──────────────────────────────────────────────────────────────

def leggi_csv(percorso_csv: str, cfg: LibConfig) -> tuple:
    print(f"  Lettura CSV: {percorso_csv}")
    with open(percorso_csv, encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = reader.fieldnames or []
        answ_cols = _answ_headers(fieldnames)
        termini = []
        for row in reader:
            display = _testo(row.get(cfg.display_col))
            if not display:
                continue
            n = _numquest(row.get("numquest"))
            explicit_code = _testo(row.get("code"))
            if n is None and not explicit_code:
                continue
            props = []
            for prop_code, header, _desc in cfg.text_props:
                v = _testo(row.get(header))
                if v:
                    props.append((prop_code, v))
            answers = [_testo(row.get(h)) for h in answ_cols]
            termini.append({
                "number":  n,
                "code":    explicit_code or cfg.code_fmt.format(n=n),
                "display": display,
                "props":   props,
                "answers": answers,
                "parent":      _testo(row.get("parent")),
                "showif":      _testo(row.get("showif")),
                "answer_type": _testo(row.get("answerType")),
            })
    print(f"  {cfg.item_label.capitalize()} lette: {len(termini)} "
          f"(colonne risposta: {len(answ_cols)})")
    return termini, len(answ_cols)


# ─── Costruzione risorse FHIR ─────────────────────────────────────────────────

def build_codesystem(termini: list, n_answ: int, cfg: LibConfig) -> dict:
    concetti = []
    for t in termini:
        props = []
        if t["number"] is not None:
            props.append({"code": "number", "valueInteger": t["number"]})
        for prop_code, v in t["props"]:
            props.append({"code": prop_code, "valueString": v})
        for i, ans in enumerate(t["answers"], 1):
            if ans:
                props.append({"code": f"answ{i}", "valueString": ans})
        if t["parent"]:
            props.append({"code": "parent", "valueString": t["parent"]})
        if t["showif"]:
            props.append({"code": "showif", "valueString": t["showif"]})
        if t["answer_type"]:
            props.append({"code": "answerType", "valueString": t["answer_type"]})
        concetti.append({
            "code":     t["code"],
            "display":  t["display"],
            "property": props,
        })

    property_defs = [
        {"code": "number", "description": "Numero della domanda (da numquest)", "type": "integer"},
    ]
    for prop_code, _header, desc in cfg.text_props:
        property_defs.append({"code": prop_code, "description": desc, "type": "string"})
    for i in range(1, n_answ + 1):
        property_defs.append({"code": f"answ{i}", "description": f"Risposta {i}", "type": "string"})
    if any(t["parent"] for t in termini):
        property_defs.append({"code": "parent",
                              "description": "Code della domanda madre (sotto-domanda condizionale)",
                              "type": "string"})
        property_defs.append({"code": "showif",
                              "description": "Codici risposta della domanda madre che rendono visibile la sotto-domanda (separati da |)",
                              "type": "string"})
    if any(t["answer_type"] for t in termini):
        property_defs.append({"code": "answerType",
                              "description": "Tipo di risposta all'import CRF (multichoice | choice | open-choice | number)",
                              "type": "string"})

    return {
        "resourceType": "CodeSystem",
        "id":           cfg.cs_id,
        "url":          cfg.cs_url,
        "version":      cfg.version,
        "name":         cfg.cs_name,
        "title":        cfg.cs_title,
        "status":       "active",
        "content":      "complete",
        "date":         str(date.today()),
        "description":  cfg.description.format(n=len(concetti)),
        "publisher":    cfg.publisher,
        "copyright":    cfg.copyright,
        "property":     property_defs,
        "concept":      concetti,
    }


def build_valueset(termini: list, cfg: LibConfig) -> dict:
    concetti_vs = [
        {"code": t["code"], "display": t["display"]}
        for t in termini if t["code"] and t["display"]
    ]
    return {
        "resourceType": "ValueSet",
        "id":           cfg.vs_id,
        "url":          cfg.vs_url,
        "version":      cfg.version,
        "name":         cfg.vs_name,
        "title":        cfg.vs_title,
        "status":       "active",
        "date":         str(date.today()),
        "description":  f"Tutti i {len(concetti_vs)} item ({cfg.cs_title})",
        "compose": {
            "include": [{"system": cfg.cs_url, "concept": concetti_vs}]
        },
    }


def build_structuredefinition(n_answ: int, cfg: LibConfig) -> dict:
    def slice_str(name: str, short: str) -> list:
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
         "short": f"Metadati {cfg.cs_title} su QuestionnaireItem"},
        {"id": "Extension.extension", "path": "Extension.extension",
         "slicing": {"discriminator": [{"type": "value", "path": "url"}], "rules": "open"}},
    ]
    for prop_code, _header, desc in cfg.text_props:
        elementi += slice_str(prop_code, desc)
    for i in range(1, n_answ + 1):
        elementi += slice_str(f"answ{i}", f"Risposta {i}")
    elementi += [
        {"id": "Extension.url",      "path": "Extension.url",      "fixedUri": cfg.sd_url},
        {"id": "Extension.value[x]", "path": "Extension.value[x]", "max": "0"},
    ]

    return {
        "resourceType": "StructureDefinition",
        "id":           cfg.sd_id,
        "url":          cfg.sd_url,
        "version":      cfg.version,
        "name":         cfg.sd_name,
        "title":        cfg.sd_title,
        "status":       "active",
        "date":         str(date.today()),
        "kind":         "complex-type",
        "abstract":     False,
        "context":      [{"type": "element", "expression": "QuestionnaireItem"}],
        "type":         "Extension",
        "baseDefinition": "http://hl7.org/fhir/StructureDefinition/Extension",
        "derivation":   "constraint",
        "description":  cfg.sd_description,
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


# ─── Push / list HAPI ─────────────────────────────────────────────────────────

def push_to_hapi(bundle: dict, hapi_url: str, cfg: LibConfig) -> None:
    if requests is None:
        print("ERRORE: requests non installato. Esegui: pip install requests")
        sys.exit(1)
    url = hapi_url.rstrip("/")
    print(f"\n  Push su {url} ...")
    r = requests.post(url, json=bundle,
                      headers={"Content-Type": "application/fhir+json"}, timeout=120)
    if r.status_code in (200, 201):
        print(f"  ✓ Caricamento completato (HTTP {r.status_code})")
        print(f"    CodeSystem          → {url}/CodeSystem/{cfg.cs_id}")
        print(f"    ValueSet            → {url}/ValueSet/{cfg.vs_id}")
        print(f"    StructureDefinition → {url}/StructureDefinition/{cfg.sd_id}")
    else:
        print(f"  ✗ Errore HTTP {r.status_code}")
        try:
            print(json.dumps(r.json(), indent=2, ensure_ascii=False)[:2000])
        except Exception:
            print(r.text[:2000])
        sys.exit(1)


def list_hapi(hapi_url: str, cfg: LibConfig) -> None:
    if requests is None:
        print("ERRORE: requests non installato. Esegui: pip install requests")
        sys.exit(1)
    url = hapi_url.rstrip("/")
    print(f"\nRisorse {cfg.cs_title} su {url}:\n")
    for tipo, res_id in [("CodeSystem", cfg.cs_id),
                         ("ValueSet", cfg.vs_id),
                         ("StructureDefinition", cfg.sd_id)]:
        r = requests.get(f"{url}/{tipo}/{res_id}",
                         headers={"Accept": "application/fhir+json"}, timeout=30)
        if r.status_code == 200:
            data = r.json()
            print(f"  ✓ {tipo:<22} id={res_id}  versione={data.get('version','—')}  data={data.get('date','—')}")
        elif r.status_code == 404:
            print(f"  ✗ {tipo:<22} id={res_id}  NON TROVATO")
        else:
            print(f"  ? {tipo:<22} id={res_id}  HTTP {r.status_code}")
    print()


# ─── Entry point generico ─────────────────────────────────────────────────────

def main(cfg: LibConfig, default_csv: str) -> None:
    parser = argparse.ArgumentParser(
        description=f"Import {cfg.cs_title} → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition)")
    parser.add_argument("csv", nargs="?", default=default_csv,
                        help=f"Percorso file CSV (default: {default_csv})")
    parser.add_argument("hapi_url", nargs="?", default="http://localhost:8080/fhir",
                        help="URL base HAPI FHIR (default: http://localhost:8080/fhir)")
    parser.add_argument("--bundle-only", action="store_true",
                        help="Genera solo il bundle JSON, non carica su HAPI")
    parser.add_argument("--list", action="store_true",
                        help="Mostra risorse già caricate su HAPI ed esce")
    args = parser.parse_args()

    if args.list:
        list_hapi(args.hapi_url, cfg)
        return

    print("─" * 60)
    print(f"  {cfg.cs_title} → HAPI FHIR")
    print("─" * 60)

    csv_path = args.csv
    if not Path(csv_path).is_absolute():
        # risolvi relativo alla cartella dello script chiamante
        import __main__
        base = Path(getattr(__main__, "__file__", ".")).resolve().parent
        cand = base / csv_path
        if cand.exists():
            csv_path = str(cand)

    termini, n_answ = leggi_csv(csv_path, cfg)
    if not termini:
        print("  ERRORE: nessun termine letto dal CSV.")
        sys.exit(1)

    print("  Costruzione risorse FHIR...")
    cs     = build_codesystem(termini, n_answ, cfg)
    vs     = build_valueset(termini, cfg)
    sd     = build_structuredefinition(n_answ, cfg)
    bundle = build_bundle(cs, vs, sd)

    import __main__
    script_dir = Path(getattr(__main__, "__file__", ".")).resolve().parent
    bundle_name = cfg.bundle_name or f"{cfg.cs_id}-bundle.json"
    bundle_out = script_dir / bundle_name
    bundle_out.write_text(json.dumps(bundle, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"  Bundle salvato: {bundle_out}  ({bundle_out.stat().st_size // 1024} KB)")

    if args.bundle_only:
        print("\n  --bundle-only: nessun push su HAPI.")
        return

    push_to_hapi(bundle, args.hapi_url, cfg)
    print("─" * 60)
