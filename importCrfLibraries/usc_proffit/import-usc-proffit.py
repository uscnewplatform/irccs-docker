#!/usr/bin/env python3
"""
Import USC PROFFIT → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition).

Sorgente unica: usc_proffit.csv (nessun Excel).
CSV: numquest,head,quest,answ1..12

Uso:
    python3 import-usc-proffit.py [csv] [HAPI_URL] [--bundle-only] [--list]

Richiede: pip install requests
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import _csvlib as csvlib  # noqa: E402

CFG = csvlib.LibConfig(
    cs_id="usc-proffit",
    vs_id="usc-proffit-items",
    sd_id="usc-proffit-metadata",
    cs_url="https://irccs-pascale.it/fhir/CodeSystem/usc-proffit",
    vs_url="https://irccs-pascale.it/fhir/ValueSet/usc-proffit-items",
    sd_url="https://irccs-pascale.it/fhir/StructureDefinition/usc-proffit-metadata",
    version="1.0",
    cs_name="USCPROFFIT",
    cs_title="USC PROFFIT",
    vs_name="USCPROFFITItems",
    vs_title="USC PROFFIT Items ValueSet",
    sd_name="USCPROFFITMetadata",
    sd_title="USC PROFFIT Metadata Extension",
    publisher="IRCCS Pascale",
    copyright="PROFFIT - Patient Reported Outcome for Fighting FInancial Toxicity",
    description=("PROFFIT - Patient Reported Outcome for Fighting FInancial Toxicity. "
                 "{n} items."),
    sd_description="Estensione su QuestionnaireItem per USC PROFFIT: sezione e opzioni di risposta.",
    display_col="quest",
    text_props=[("head", "head", "Sezione / dominio del questionario")],
    code_fmt="{n}",
    item_label="item",
)

if __name__ == "__main__":
    csvlib.main(CFG, default_csv="usc_proffit.csv")
