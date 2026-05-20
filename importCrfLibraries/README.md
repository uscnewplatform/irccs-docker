# Import terminologie → HAPI FHIR

Carica CTCAE, PRO-CTCAE e EORTC come risorse FHIR su HAPI FHIR.

Ogni versione è indipendente. I bundle JSON pre-generati sono già nel repo.

## Struttura

```
importCrfLibraries/
├── ctcae-v4/
│   ├── import-ctcae-v4.py        ← genera bundle da Excel + push su HAPI
│   ├── install-ctcae-v4.sh       ← push curl del bundle pre-generato
│   └── ctcae-v4-bundle.json      ← 790 termini, 26 SOC
├── ctcae-v5/
│   ├── import-ctcae-v5.py
│   ├── install-ctcae-v5.sh
│   └── ctcae-v5-bundle.json      ← 837 termini, 26 SOC
├── ctcae-v6/
│   ├── import-ctcae-v6.py
│   ├── install-ctcae-v6.sh
│   ├── ctcae-v6-bundle.json      ← 850 termini, 26 SOC
│   └── README.md
├── proctc-v1/
│   ├── import-proctc-v1.py
│   ├── install-proctc-v1.sh
│   └── proctc-v1-bundle.json     ← 125 termini PRO-CTCAE v1
└── eortc-v1/
    ├── import-eortc-v1.py
    ├── install-eortc-v1.sh
    └── eortc-v1-bundle.json      ← 30 item EORTC QLQ-C30
```

## Utilizzo rapido

```bash
bash irccs-docker/importCrfLibraries/ctcae-v4/install-ctcae-v4.sh http://localhost:8080/fhir
bash irccs-docker/importCrfLibraries/ctcae-v5/install-ctcae-v5.sh http://localhost:8080/fhir
bash irccs-docker/importCrfLibraries/ctcae-v6/install-ctcae-v6.sh http://localhost:8080/fhir
bash irccs-docker/importCrfLibraries/proctc-v1/install-proctc-v1.sh http://localhost:8080/fhir
bash irccs-docker/importCrfLibraries/eortc-v1/install-eortc-v1.sh http://localhost:8080/fhir
```

## Rigenera bundle da Excel

```bash
# Richiede: pip install openpyxl requests

python3 importCrfLibraries/ctcae-v4/import-ctcae-v4.py "CTCAE_4.03_2010-06-14.xlsx" --bundle-only
python3 importCrfLibraries/ctcae-v5/import-ctcae-v5.py "CTCAE_v5.0_2017-11-27.xlsx" --bundle-only
python3 importCrfLibraries/ctcae-v6/import-ctcae-v6.py "CTCAE v6.0 Final Clean-Tracked-Mapping_w_OS_Jan2026.xlsx" --bundle-only
python3 importCrfLibraries/proctc-v1/import-proctc-v1.py "uosc_proctcaev1.xlsx" --bundle-only
python3 importCrfLibraries/eortc-v1/import-eortc-v1.py "eortc-qlq-c30.xlsx" --bundle-only
```

## Risorse create per versione

| Versione | CodeSystem ID | ValueSet ID | Termini |
|---|---|---|---|
| CTCAE v4.03 | `ctcae-v4` | `ctcae-v4-adverse-events` | 790 |
| CTCAE v5.0 | `ctcae-v5` | `ctcae-v5-adverse-events` | 837 |
| CTCAE v6.0 | `ctcae-v6` | `ctcae-v6-adverse-events` | 850 |
| PRO-CTCAE v1 | `proctc-v1` | `proctc-v1-adverse-events` | 125 |
| EORTC QLQ-C30 | `eortc-v1` | `eortc-v1-items` | 30 |

## Proprietà CodeSystem per concetto

### CTCAE (v4/v5/v6)

| Proprietà | v4 | v5 | v6 | Descrizione |
|---|---|---|---|---|
| `soc` | ✓ | ✓ | ✓ | System Organ Class MedDRA |
| `grade1`–`grade5` | ✓ | ✓ | ✓ | Descrizione grado |
| `navNote` | — | ✓ | ✓ | Nota navigazionale NCI |
| `v5change` | — | ✓ | — | Variazioni rispetto a v4 |
| `v6change` | — | — | ✓ | Variazioni rispetto a v5 |

### PRO-CTCAE v1

| Proprietà | Descrizione |
|---|---|
| `macrogroup` | Macrogruppo sintomatologico |
| `category` | Categoria di sintomo (usata per raggruppamento UI) |
| `interface` | Tipo di interfaccia UI |
| `answ1`–`answ8` | Opzioni di risposta |

### EORTC QLQ-C30

| Proprietà | Descrizione |
|---|---|
| `head` | Sezione / dominio (usata per raggruppamento UI) |
| `answ1`–`answ7` | Opzioni di risposta |

## Architettura

Tutte le terminologie sono gestite via HAPI FHIR (CodeSystem + ValueSet).
Il microservizio `irccs-microservice-ctcae` **non espone più endpoint terminologici** — gestisce solo OTP/TOTP.

La UI legge i CodeSystem direttamente da HAPI tramite:
- `CtcaeV6Service.ts` → CTCAE v4/v5/v6
- `ProctcV1Service.ts` → PRO-CTCAE v1
- `EortcV1Service.ts` → EORTC QLQ-C30
