#!/usr/bin/env python3
"""
Import EuroQol EQ-5D-5L → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition).

Sorgente unica: euroqol_eq5d5l.csv (nessun Excel).
CSV: numquest,head,quest,answ1..12

Uso:
    python3 import-euroqol-eq5d5l.py [csv] [HAPI_URL] [--bundle-only] [--list]

Richiede: pip install requests
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import _csvlib as csvlib  # noqa: E402

CFG = csvlib.LibConfig(
    cs_id="euroqol-eq5d5l",
    vs_id="euroqol-eq5d5l-items",
    sd_id="euroqol-eq5d5l-metadata",
    cs_url="https://euroqol.org/eq-5d-5l",
    vs_url="https://euroqol.org/eq-5d-5l-items",
    sd_url="https://irccs-pascale.it/fhir/StructureDefinition/euroqol-eq5d5l-metadata",
    version="1.0",
    cs_name="EuroQolEQ5D5L",
    cs_title="EuroQol EQ-5D-5L",
    vs_name="EuroQolEQ5D5LItems",
    vs_title="EuroQol EQ-5D-5L Items ValueSet",
    sd_name="EuroQolEQ5D5LMetadata",
    sd_title="EuroQol EQ-5D-5L Metadata Extension",
    publisher="EuroQol Research Foundation / IRCCS Pascale",
    copyright="© EuroQol Research Foundation. EQ-5D™ is a trade mark of the EuroQol Research Foundation.",
    description="EuroQol EQ-5D-5L health-related quality of life instrument. {n} items.",
    sd_description="Estensione su QuestionnaireItem per EQ-5D-5L: sezione e opzioni di risposta.",
    display_col="quest",
    text_props=[("head", "head", "Sezione / dominio del questionario")],
    code_fmt="{n}",
    item_label="item",
)

if __name__ == "__main__":
    csvlib.main(CFG, default_csv="euroqol_eq5d5l.csv")
