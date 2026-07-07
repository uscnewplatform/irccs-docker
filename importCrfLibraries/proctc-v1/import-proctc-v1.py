#!/usr/bin/env python3
"""
Import PRO-CTCAE v1 → HAPI FHIR (CodeSystem + ValueSet + StructureDefinition).

Sorgente unica: proctcae-v1.csv (nessun Excel).
CSV: numquest,macrogroup,category,term,answ1..8

Uso:
    python3 import-proctc-v1.py [csv] [HAPI_URL] [--bundle-only] [--list]

Richiede: pip install requests   (openpyxl NON più necessario)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import _csvlib as csvlib  # noqa: E402

CFG = csvlib.LibConfig(
    cs_id="proctc-v1",
    vs_id="proctc-v1-adverse-events",
    sd_id="proctc-v1-grade-severity",
    cs_url="https://healthcaredelivery.cancer.gov/pro-ctcae",
    vs_url="https://healthcaredelivery.cancer.gov/pro-ctcae-adverse-events",
    sd_url="https://irccs-pascale.it/fhir/StructureDefinition/proctc-v1-grade-severity",
    version="1.0",
    cs_name="PRO_CTCAEv1",
    cs_title="PRO-CTCAE v1 Patient-Reported Outcomes",
    vs_name="PRO_CTCAEv1AdverseEvents",
    vs_title="PRO-CTCAE v1 Adverse Events ValueSet",
    sd_name="PRO_CTCAEv1GradeSeverity",
    sd_title="PRO-CTCAE v1 Grade Severity Extension",
    publisher="NCI / IRCCS Pascale",
    copyright="NCI PRO-CTCAE v1",
    description="NCI Patient-Reported Outcomes version of CTCAE (PRO-CTCAE) v1. {n} termini.",
    sd_description=("Estensione su QuestionnaireItem per PRO-CTCAE v1: macrogruppo, "
                    "categoria e opzioni di risposta."),
    display_col="term",
    text_props=[
        ("macrogroup", "macrogroup", "Macrogruppo sintomatologico"),
        ("category",   "category",   "Categoria di sintomo"),
    ],
    code_fmt="PROCTC-{n:04d}",
    item_label="termini",
)

if __name__ == "__main__":
    csvlib.main(CFG, default_csv="proctcae-v1.csv")
