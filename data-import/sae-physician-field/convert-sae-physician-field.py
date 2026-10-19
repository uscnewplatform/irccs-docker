#!/usr/bin/env python3
"""Converte il campo "Nome del medico che riporta l'evento" delle Questionnaire SAE da testo libero a
selezione di un Practitioner (item type=reference + estensione practitioner-select), cosi' il flusso SAE
sa chi e' il medico (email, abilitazione e firma). Idempotente: salta gli item gia' convertiti.

Uso (dry-run di default, stampa solo cosa cambierebbe):
    python3 convert-sae-physician-field.py --fhir-url http://localhost:8080/fhir
    python3 convert-sae-physician-field.py --fhir-url http://localhost:8080/fhir --apply
Controllare SEMPRE l'URL: lo script modifica le Questionnaire (nuova versione FHIR, lo storico resta).
"""
import argparse, json, re, urllib.request

NS = "http://irccs.pascale.napoli.it/fhir/StructureDefinition/"
EXTENSIONS = [
    {"url": "http://hl7.org/fhir/StructureDefinition/questionnaire-referenceResource", "valueCode": "Practitioner"},
    {"url": NS + "practitioner-select", "valueBoolean": True},
    {"url": NS + "autoconfirm", "valueBoolean": True},
]
LABEL = re.compile(r"^\s*nome del medico che riporta", re.I)  # esclude "Il nome del medico..." (altro item)


def fetch(url, data=None, method=None):
    req = urllib.request.Request(url, data=json.dumps(data).encode() if data is not None else None, method=method,
                                 headers={"Content-Type": "application/fhir+json"})
    with urllib.request.urlopen(req) as res:
        return json.load(res)


def is_sae(q):
    return any((i.get("system") or "").lower() == "sae" for i in q.get("identifier", []))


def convert(items):
    changed = 0
    for item in items:
        if item.get("type") in ("text", "string") and LABEL.search(item.get("text", "")) and not item.get("item"):
            item["type"] = "reference"
            kept = [e for e in item.get("extension", []) if e["url"] not in {x["url"] for x in EXTENSIONS}]
            item["extension"] = kept + EXTENSIONS
            changed += 1
        changed += convert(item.get("item", []))
    return changed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fhir-url", required=True)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    bundle = fetch(f"{args.fhir_url}/Questionnaire?_count=500")
    total = 0
    for entry in bundle.get("entry", []):
        q = entry["resource"]
        if not is_sae(q):
            continue
        n = convert(q.get("item", []))
        if n:
            total += n
            print(f"Questionnaire/{q['id']} '{q.get('title')}': {n} item(s) -> reference")
            if args.apply:
                fetch(f"{args.fhir_url}/Questionnaire/{q['id']}", q, "PUT")
    print(("Applicato" if args.apply else "Dry-run") + f": {total} item(s).")


if __name__ == "__main__":
    main()
