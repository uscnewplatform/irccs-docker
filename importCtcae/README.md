# Import CTCAE → HAPI FHIR

Carica le terminologie NCI CTCAE (v4, v5, v6) come risorse FHIR su HAPI FHIR.

Ogni versione è indipendente. I bundle JSON pre-generati sono già nel repo.

## Struttura

```
importCtcae/
├── v4/
│   ├── import-ctcae-v4.py        ← genera bundle da Excel + push su HAPI
│   ├── install-ctcae-v4.sh       ← push curl del bundle pre-generato
│   ├── ctcae-v4-bundle.json      ← bundle pre-generato (790 termini, 26 SOC)
│   └── README.md  ←  ← questa cartella non ha README proprio, vedi qui sotto
├── v5/
│   ├── import-ctcae-v5.py
│   ├── install-ctcae-v5.sh
│   └── ctcae-v5-bundle.json      ← 837 termini, 26 SOC
└── v6/
    ├── import-ctcae-v6.py
    ├── install-ctcae-v6.sh
    ├── ctcae-v6-bundle.json      ← 850 termini, 26 SOC
    └── README.md                 ← documentazione dettagliata v6
```

## Utilizzo rapido

```bash
# v4
bash irccs-docker/importCtcae/v4/install-ctcae-v4.sh http://localhost:8080/fhir

# v5
bash irccs-docker/importCtcae/v5/install-ctcae-v5.sh http://localhost:8080/fhir

# v6
bash irccs-docker/importCtcae/v6/install-ctcae-v6.sh http://localhost:8080/fhir
```

## Rigenera bundle da Excel

```bash
# Richiede: pip install openpyxl requests

python3 importCtcae/v4/import-ctcae-v4.py "CTCAE_4.03_2010-06-14.xlsx" --bundle-only
python3 importCtcae/v5/import-ctcae-v5.py "CTCAE_v5.0_2017-11-27.xlsx" --bundle-only
python3 importCtcae/v6/import-ctcae-v6.py "CTCAE v6.0 Final Clean-Tracked-Mapping_w_OS_Jan2026.xlsx" --bundle-only
```

## Risorse create per versione

| Versione | CodeSystem ID | ValueSet ID | Termini |
|---|---|---|---|
| v4.03 | `ctcae-v4` | `ctcae-v4-adverse-events` | 790 |
| v5.0 | `ctcae-v5` | `ctcae-v5-adverse-events` | 837 |
| v6.0 | `ctcae-v6` | `ctcae-v6-adverse-events` | 850 |

La `StructureDefinition` `ctcae-grade-severity` è condivisa tra tutte le versioni (stesso ID/URL).

## Proprietà CodeSystem per concetto

| Proprietà | v4 | v5 | v6 | Descrizione |
|---|---|---|---|---|
| `soc` | ✓ | ✓ | ✓ | System Organ Class MedDRA |
| `grade1`–`grade5` | ✓ | ✓ | ✓ | Descrizione grado |
| `navNote` | — | ✓ | ✓ | Nota navigazionale NCI |
| `v5change` | — | ✓ | — | Variazioni rispetto a v4 |
| `v6change` | — | — | ✓ | Variazioni rispetto a v5 |

## Architettura

Le versioni CTC sono gestite interamente via HAPI FHIR (CodeSystem + ValueSet).
Il microservizio `irccs-microservice-ctcae` **non espone più endpoint CTC** — gestisce solo EORTC, ProCTC e OTP.

La UI legge i CodeSystem direttamente da HAPI tramite `CtcaeV6Service.ts` (`buildCtcaeV4/V5/V6Questionnaire()`).
