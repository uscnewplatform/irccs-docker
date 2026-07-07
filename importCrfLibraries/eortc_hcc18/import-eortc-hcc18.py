#!/usr/bin/env python3
"""
Import EORTC QLQ-HCC18 → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition).

Sorgente unica: eortc_hcc18.csv (nessun Excel).
CSV: numquest,head,quest,answ1..12

Uso:
    python3 import-eortc-hcc18.py [csv] [HAPI_URL] [--bundle-only] [--list]

Richiede: pip install requests
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import _csvlib as csvlib  # noqa: E402

CFG = csvlib.LibConfig(
    cs_id="eortc-hcc18",
    vs_id="eortc-hcc18-items",
    sd_id="eortc-hcc18-metadata",
    cs_url="https://www.eortc.org/qlq-hcc18",
    vs_url="https://www.eortc.org/qlq-hcc18-items",
    sd_url="https://irccs-pascale.it/fhir/StructureDefinition/eortc-hcc18-metadata",
    version="1.0",
    cs_name="EORTCHCC18",
    cs_title="EORTC QLQ-HCC18 Hepatocellular Carcinoma Module",
    vs_name="EORTCHCC18Items",
    vs_title="EORTC QLQ-HCC18 Items ValueSet",
    sd_name="EORTCHCC18Metadata",
    sd_title="EORTC QLQ-HCC18 Metadata Extension",
    publisher="EORTC / IRCCS Pascale",
    copyright="EORTC QLQ-HCC18",
    description=("EORTC Quality of Life Questionnaire Hepatocellular Carcinoma "
                 "module (QLQ-HCC18). {n} items."),
    sd_description="Estensione su QuestionnaireItem per EORTC QLQ-HCC18: sezione e opzioni di risposta.",
    display_col="quest",
    text_props=[("head", "head", "Sezione / dominio del questionario")],
    code_fmt="{n}",
    item_label="item",
)

if __name__ == "__main__":
    csvlib.main(CFG, default_csv="eortc_hcc18.csv")
