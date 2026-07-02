# Import CTCAE v6.0 → HAPI FHIR

Carica la terminologia NCI CTCAE v6.0 come risorse FHIR su HAPI FHIR.

Il bundle `ctcae-v6-bundle.json` è già presente nel repo (generato da Excel NCI, Gennaio 2026).
Per caricare su HAPI basta lo script shell. Per rigenerare da un nuovo Excel, serve Python.

## Struttura cartella

```
importCrfLibraries/ctcae-v6/
├── import-ctcae-v6.py            ← script Python (legge Excel, genera bundle, push su HAPI)
├── install-ctcae-v6.sh          ← carica il bundle committato su HAPI (solo curl)
├── CTCAE_v6.0_Final_Jan2026.xlsx ← Excel sorgente versionato
├── ctcae-v6-bundle.json         ← bundle FHIR pre-generato (committed nel repo)
└── README.md
```

> Per le convenzioni comuni a tutte le CRF library (bundle committato come unica
> sorgente install, rigenerazione via `import-*.py --bundle-only`, property `number`
> e numerazione domande nei PDF) vedi il [README della cartella padre](../README.md).

## Prerequisiti

| Strumento | Versione | Solo per |
|-----------|----------|----------|
| `curl`    | qualsiasi | `install-ctcae-v6.sh` |
| Python 3.10+ | 3.10+ | `import-ctcae-v6.py` |
| `openpyxl` | 3.x | lettura Excel |
| `requests` | 2.x | push Python su HAPI |

```bash
pip install openpyxl requests
```

---

## Utilizzo rapido (bundle pre-generato)

```bash
bash importCrfLibraries/ctcae-v6/install-ctcae-v6.sh http://localhost:8080/fhir
```

---

## Utilizzo con script Python

### Carica su HAPI locale (genera bundle + push)

```bash
python3 import-ctcae-v6.py "CTCAE_v6.0_Final_Jan2026.xlsx"
```

### Carica su HAPI remoto

```bash
python3 import-ctcae-v6.py ctcae.xlsx https://hapi.irccs.infocube.it/fhir
```

### Solo genera bundle JSON, niente push

```bash
python3 import-ctcae-v6.py ctcae.xlsx --bundle-only
```

### Verifica cosa è caricato su HAPI

```bash
python3 import-ctcae-v6.py ctcae.xlsx --list
```

Output atteso:
```
Risorse CTCAE v6 su http://localhost:8080/fhir:

  ✓ CodeSystem            id=ctcae-v6               versione=6.0  data=2026-05-15
  ✓ ValueSet              id=ctcae-v6-adverse-events versione=6.0  data=2026-05-15
  ✓ StructureDefinition   id=ctcae-v6-grade-severity versione=1.0  data=2026-05-15
```

---

## Risorse FHIR create

| Risorsa | ID | URL canonica |
|---|---|---|
| CodeSystem | `ctcae-v6` | `https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6` |
| ValueSet | `ctcae-v6-adverse-events` | `https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6-adverse-events` |
| StructureDefinition | `ctcae-v6-grade-severity` | `https://irccs-pascale.it/fhir/StructureDefinition/ctcae-v6-grade-severity` |

### CodeSystem — proprietà per concetto

| Proprietà | Tipo | Descrizione |
|---|---|---|
| `number` | integer | Numero della domanda (= codice MedDRA) |
| `soc` | string | System Organ Class MedDRA 28.0 |
| `grade1` | string | Descrizione Grade 1 |
| `grade2` | string | Descrizione Grade 2 |
| `grade3` | string | Descrizione Grade 3 |
| `grade4` | string | Descrizione Grade 4 |
| `grade5` | string | Descrizione Grade 5 (sempre "Death" se presente) |
| `navNote` | string | Nota navigazionale NCI |
| `v6change` | string | Tipo di variazione rispetto a CTCAE v5 |

### StructureDefinition — `ctcae-v6-grade-severity`

Estensione FHIR su `QuestionnaireItem` per profilare le domande che derivano da CTCAE v6.
Porta i metadati clinici del termine (gradi 1-5, SOC, nota navigazionale) direttamente nell'item.

```json
{
  "url": "https://irccs-pascale.it/fhir/StructureDefinition/ctcae-v6-grade-severity",
  "extension": [
    { "url": "grade1", "valueString": "Hemoglobin (Hgb) <LLN - 10.0 g/dL..." },
    { "url": "grade2", "valueString": "Hgb <10.0 - 8.0 g/dL..." },
    { "url": "grade3", "valueString": "Hgb <8.0 g/dL; transfusion indicated" },
    { "url": "grade4", "valueString": "Life-threatening consequences..." },
    { "url": "grade5", "valueString": "Death" },
    { "url": "soc",    "valueString": "Blood and lymphatic system disorders" }
  ]
}
```

---

## API HAPI FHIR

```bash
# Ricerca per termine (usato dal Questionnaire Builder → bottone "⚠️ CTCAE v6")
curl "http://localhost:8080/fhir/ValueSet/\$expand?url=https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6-adverse-events&filter=anemia&count=10"

# Dettagli termine con gradi e SOC
curl "http://localhost:8080/fhir/CodeSystem/\$lookup?system=https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6&code=10002272"

# Validazione codice MedDRA LLT
curl "http://localhost:8080/fhir/CodeSystem/\$validate-code?url=https://ncicb.nci.nih.gov/xml/owl/EVS/ctcae-v6&code=10002272"
```

---

## Aggiornamento a CTCAE v7 (futuro)

Quando NCI rilascerà CTCAE v7:

```bash
mkdir importCrfLibraries/ctcae-v7
cp import-ctcae-v6.py ../v7/import-ctcae-v7.py
# aggiorna CS_URL, VS_URL, VERSION nello script v7
python3 ../v7/import-ctcae-v7.py "CTCAE_v7.xlsx"
```

Le risorse v6 rimangono invariate su HAPI; i questionari esistenti continuano a funzionare.

---

## Fonte dati

Excel NCI originale: **CTCAE v6.0 Final Clean-Tracked-Mapping_w_OS_Jan2026.xlsx**
(versionato nel repo come `CTCAE_v6.0_Final_Jan2026.xlsx`).
Distribuito da [NCI CTCAE](https://ctep.cancer.gov/protocolDevelopment/electronic_applications/ctc.htm)
Licenza: dominio pubblico NCI/NIH.

Dati caricati: 850 termini, 26 SOC MedDRA 28.0.
