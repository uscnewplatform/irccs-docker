# Import terminologie → HAPI FHIR

Carica CTCAE, PRO-CTCAE e EORTC come risorse FHIR su HAPI FHIR.

Ogni versione è indipendente. Sia il bundle JSON pre-generato sia l'Excel sorgente
sono versionati nella cartella della CRF.

## Due sorgenti di import

`install-*.sh` accetta `--source`:

| `--source` | Cosa fa |
|---|---|
| `bundle` (default) | carica il `*-bundle.json` pre-generato e committato (solo `curl`, zero dipendenze) |
| `excel` | rigenera il bundle dall'Excel versionato (`import-*.py --bundle-only`, serve `openpyxl`) e poi lo carica |

```bash
bash ctcae-v5/install-ctcae-v5.sh http://localhost:8080/fhir                 # da bundle
bash ctcae-v5/install-ctcae-v5.sh http://localhost:8080/fhir --source excel  # rigenera da Excel + carica
```

Con `--source excel` il `*-bundle.json` viene riscritto (cambia solo il campo `date`).
Se vuoi che il bundle aggiornato resti nel repo, committalo dopo.

## Struttura

```
importCrfLibraries/
├── _lib.sh                       ← helper condiviso degli install-*.sh (parse args, rigenera, push)
├── requirements.txt              ← deps per --source excel (openpyxl, requests)
├── ctcae-v4/
│   ├── import-ctcae-v4.py        ← genera bundle da Excel + push su HAPI
│   ├── install-ctcae-v4.sh       ← carica bundle o (─-source excel) rigenera da Excel
│   ├── CTCAE_4.03_2010-06-14.xlsx ← Excel sorgente versionato
│   └── ctcae-v4-bundle.json      ← 790 termini, 26 SOC
├── ctcae-v5/
│   ├── import-ctcae-v5.py
│   ├── install-ctcae-v5.sh
│   ├── CTCAE_v5.0_2017-11-27.xlsx
│   └── ctcae-v5-bundle.json      ← 837 termini, 26 SOC
├── ctcae-v6/
│   ├── import-ctcae-v6.py
│   ├── install-ctcae-v6.sh
│   ├── CTCAE_v6.0_Final_Jan2026.xlsx
│   ├── ctcae-v6-bundle.json      ← 850 termini, 26 SOC
│   └── README.md
├── proctc-v1/
│   ├── import-proctc-v1.py
│   ├── install-proctc-v1.sh
│   ├── uosc_proctcaev1.xlsx
│   └── proctc-v1-bundle.json     ← 125 termini PRO-CTCAE v1
└── eortc-v1/
    ├── import-eortc-v1.py
    ├── install-eortc-v1.sh
    ├── eortc-qlq-c30.xlsx
    └── eortc-v1-bundle.json      ← 30 item EORTC QLQ-C30
```

## Utilizzo rapido

Sostituisci l'URL con quello dell'ambiente target (locale/preprod/nuovo server).
Default `--source bundle` = solo `curl`, nessuna dipendenza Python.

```bash
HAPI=http://localhost:8080/fhir   # ← cambia per l'ambiente nuovo

bash irccs-docker/importCrfLibraries/ctcae-v4/install-ctcae-v4.sh   "$HAPI"
bash irccs-docker/importCrfLibraries/ctcae-v5/install-ctcae-v5.sh   "$HAPI"
bash irccs-docker/importCrfLibraries/ctcae-v6/install-ctcae-v6.sh   "$HAPI"
bash irccs-docker/importCrfLibraries/proctc-v1/install-proctc-v1.sh "$HAPI"
bash irccs-docker/importCrfLibraries/eortc-v1/install-eortc-v1.sh   "$HAPI"
```

Note ambiente nuovo: HAPI dev'essere raggiungibile dalla macchina che lancia; questi script
sono **standalone** (niente Nexus/irccs-common). CS/VS con stessa url già presenti → `PUT`
idempotente, si può ri-lanciare senza duplicati.

## Rigenera bundle da Excel

```bash
# Richiede: pip install -r requirements.txt

python3 importCrfLibraries/ctcae-v4/import-ctcae-v4.py "CTCAE_4.03_2010-06-14.xlsx" --bundle-only
python3 importCrfLibraries/ctcae-v5/import-ctcae-v5.py "CTCAE_v5.0_2017-11-27.xlsx" --bundle-only
python3 importCrfLibraries/ctcae-v6/import-ctcae-v6.py "CTCAE_v6.0_Final_Jan2026.xlsx" --bundle-only
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
| `number` | ✓ | ✓ | ✓ | Numero progressivo 1..N (valueInteger, continuo sul file) |
| `soc` | ✓ | ✓ | ✓ | System Organ Class MedDRA |
| `grade1`–`grade5` | ✓ | ✓ | ✓ | Descrizione grado |
| `navNote` | — | ✓ | ✓ | Nota navigazionale NCI |
| `v5change` | — | ✓ | — | Variazioni rispetto a v4 |
| `v6change` | — | — | ✓ | Variazioni rispetto a v5 |

### PRO-CTCAE v1

| Proprietà | Descrizione |
|---|---|
| `number` | Numero progressivo 1..N (valueInteger, continuo sul file) |
| `macrogroup` | Macrogruppo sintomatologico |
| `category` | Categoria di sintomo (usata per raggruppamento UI) |
| `interface` | Tipo di interfaccia UI |
| `answ1`–`answ8` | Opzioni di risposta |

### EORTC QLQ-C30

| Proprietà | Descrizione |
|---|---|
| `number` | Numero progressivo 1..N (valueInteger, continuo sul file) |
| `head` | Sezione / dominio (usata per raggruppamento UI) |
| `answ1`–`answ7` | Opzioni di risposta |

## Numerazione domande (1..N) nei PDF

La property `number` (valueInteger, 1..N continuo sul file) serve a numerare le domande nei PDF di stampa CRF. Catena:

```
CodeSystem concept.property `number`        (questo repo, import-*.py)
  → QuestionnaireItem.prefix = String(number)  (dashboard, build*Questionnaire al momento dell'import CRF)
    → PDF: "N. testo domanda"                   (dashboard, makeCrfPdf.ts + Crf/makeHistoryPdf.ts)
```

Nei PDF convivono **due numerazioni indipendenti**, a livelli diversi:
- **sezione** (gruppo SOC / head / category) → `1.`, `2.`… progressivo sulle sezioni;
- **domanda** → `number` del file (1..N continuo, **non** riparte per sezione → dentro una sezione può iniziare da un valore > 1).

> ⚠️ Il numero arriva nell'item **al momento dell'import** del CRF dal CodeSystem. I CRF
> importati **prima** dell'introduzione di `number` non hanno il `prefix`: vanno re-importati
> (o ripopolati) per vederlo nei PDF.

`number` è ordine dei concept nel file Excel: se cambia l'ordine Excel cambia la numerazione (rigenera con `--source excel`).

## Architettura

Tutte le terminologie sono gestite via HAPI FHIR (CodeSystem + ValueSet).
Il microservizio `irccs-microservice-notification` **non espone più endpoint terminologici** — gestisce solo OTP/TOTP.

La UI legge i CodeSystem direttamente da HAPI tramite:
- `CtcaeV6Service.ts` → CTCAE v4/v5/v6
- `ProctcV1Service.ts` → PRO-CTCAE v1
- `EortcV1Service.ts` → EORTC QLQ-C30

Ognuno imposta `QuestionnaireItem.prefix` dalla property `number` (vedi sopra).
