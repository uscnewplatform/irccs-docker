# Import terminologie CRF → HAPI FHIR

Carica le CRF library (CTCAE, PRO-CTCAE, EORTC, EuroQol, PROFFIT) come risorse
FHIR su HAPI FHIR: **CodeSystem + ValueSet + StructureDefinition**.

Ogni libreria è indipendente e ha un `*-bundle.json` committato = **unica sorgente
per l'install** (solo `curl`, zero dipendenze). Nessun id Excel collegato:
l'install non richiama né rigenera da Excel.

Il bundle si **rigenera dalla sorgente della libreria** con il rispettivo
`import-*.py --bundle-only`:

| Sorgente di rigenerazione | Librerie |
|---|---|
| **CSV** (committato in cartella) | `proctc-v1`, `eortc_hcc18`, `euroqol_eq5d5l`, `usc_proffit` |
| **Excel** (committato in cartella) | `ctcae-v4`, `ctcae-v5`, `ctcae-v6`, `eortc-qlq-c30` |

Le library CSV usano l'helper condiviso `_csvlib.py`; le CTCAE/EORTC-C30 leggono
il proprio `.xlsx` (import dedicato). In entrambi i casi l'output è lo stesso:
un Bundle transaction con PUT idempotenti.

## Utilizzo rapido (install = push del bundle)

```bash
HAPI=http://localhost:8080/fhir   # ← cambia per l'ambiente target

bash ctcae-v4/install-ctcae-v4.sh            "$HAPI"
bash ctcae-v5/install-ctcae-v5.sh            "$HAPI"
bash ctcae-v6/install-ctcae-v6.sh            "$HAPI"
bash proctc-v1/install-proctc-v1.sh          "$HAPI"
bash eortc-qlq-c30/install-eortc-v1.sh       "$HAPI"
bash eortc_hcc18/install-eortc-hcc18.sh      "$HAPI"
bash euroqol_eq5d5l/install-euroqol-eq5d5l.sh "$HAPI"
bash usc_proffit/install-usc-proffit.sh      "$HAPI"
```

Gli install sono **standalone** (niente Nexus/irccs-common) e idempotenti:
CS/VS/SD con stessa url → `PUT`, ri-lanciabili senza duplicati.

## Rigenera un bundle dalla sorgente

```bash
# Library CSV (richiede: pip install requests)
python3 proctc-v1/import-proctc-v1.py            --bundle-only
python3 eortc_hcc18/import-eortc-hcc18.py         --bundle-only
python3 euroqol_eq5d5l/import-euroqol-eq5d5l.py   --bundle-only
python3 usc_proffit/import-usc-proffit.py         --bundle-only

# Library Excel (richiede: pip install openpyxl requests)
python3 ctcae-v4/import-ctcae-v4.py "ctcae-v4/CTCAE_4.03_2010-06-14.xlsx" --bundle-only
python3 ctcae-v5/import-ctcae-v5.py "ctcae-v5/CTCAE_v5.0_2017-11-27.xlsx" --bundle-only
python3 ctcae-v6/import-ctcae-v6.py "ctcae-v6/CTCAE_v6.0_Final_Jan2026.xlsx" --bundle-only
python3 eortc-qlq-c30/import-eortc-v1.py "eortc-qlq-c30/eortc-qlq-c30.xlsx" --bundle-only
```

Se rigeneri e vuoi che il bundle aggiornato resti nel repo, committalo dopo.

## Struttura

```
importCrfLibraries/
├── _lib.sh                      ← helper install (parse HAPI_URL + push bundle)
├── _csvlib.py                   ← helper import per le library CSV (CSV → CS+VS+SD+bundle)
├── requirements.txt             ← deps per rigenerare i bundle (requests, openpyxl)
├── ctcae-v4/  … ctcae-v6/       ← Excel + import-ctcae-vN.py + install + *-bundle.json
├── eortc-qlq-c30/               ← Excel + import-eortc-v1.py + install + eortc-v1-bundle.json
├── proctc-v1/                   ← proctcae-v1.csv + import-proctc-v1.py + install + bundle
├── eortc_hcc18/                 ← eortc_hcc18.csv + import-eortc-hcc18.py + install + bundle
├── euroqol_eq5d5l/              ← euroqol_eq5d5l.csv + import-euroqol-eq5d5l.py + install + bundle
└── usc_proffit/                 ← usc_proffit.csv + import-usc-proffit.py + install + bundle
```

## Risorse create per libreria

| Libreria | CodeSystem id | ValueSet id | Concept |
|---|---|---|---|
| CTCAE v4.03 | `ctcae-v4` | `ctcae-v4-adverse-events` | 790 |
| CTCAE v5.0 | `ctcae-v5` | `ctcae-v5-adverse-events` | 837 |
| CTCAE v6.0 | `ctcae-v6` | `ctcae-v6-adverse-events` | 850 |
| PRO-CTCAE v1 | `proctc-v1` | `proctc-v1-adverse-events` | 126 |
| EORTC QLQ-C30 | `eortc-v1` | `eortc-v1-items` | 30 |
| EORTC QLQ-HCC18 | `eortc-hcc18` | `eortc-hcc18-items` | 18 |
| EuroQol EQ-5D-5L | `euroqol-eq5d5l` | `euroqol-eq5d5l-items` | 5 |
| USC PROFFIT | `usc-proffit` | `usc-proffit-items` | 16 |

## Formato CSV (library CSV)

Intestazione sulla prima riga. Colonne:

```
numquest, <display>, [colonne testo...], answ1, answ2, ...
```

- `numquest` → property `number` (numerazione domande, vedi sotto)
- `<display>` → `concept.display` (`term` per PRO-CTCAE, `quest` per gli altri)
- colonne testo → property stringa (`macrogroup`/`category` per PRO-CTCAE, `head` per gli altri)
- `answ1..N` → property `answ1..N` (numero di colonne answ letto dall'intestazione)

Il concept `code` è `numquest` per le library QLQ-like, `PROCTC-<numquest a 4 cifre>` per PRO-CTCAE.

## Numerazione domande (`number`) nei PDF

La property `number` (valueInteger) numera le domande nei PDF di stampa CRF. Catena:

```
CodeSystem concept.property `number`
  → QuestionnaireItem.prefix = String(number)   (dashboard, al momento dell'import CRF)
    → PDF: "N. testo domanda"                    (dashboard, makeCrfPdf.ts + Crf/makeHistoryPdf.ts)
```

Origine di `number` per libreria:

| Libreria | `number` = |
|---|---|
| CTCAE v4/v5/v6 | **codice MedDRA** del concept (fallback: ordine 1..N se non numerico) |
| eortc-qlq-c30, proctc-v1, eortc_hcc18, euroqol_eq5d5l, usc_proffit | valore **`numquest`** del file |

> ⚠️ Il numero arriva nell'item **al momento dell'import** del CRF dal CodeSystem.
> I CRF importati prima dell'introduzione/modifica di `number` vanno re-importati
> per vederlo aggiornato nei PDF.

## Architettura

Tutte le terminologie sono gestite via HAPI FHIR (CodeSystem + ValueSet + StructureDefinition).
Il microservizio `irccs-microservice-notification` non espone endpoint terminologici.

La UI **scopre le library automaticamente da HAPI** (`useCrfLibraries` +
`classifyCodeSystem` in `src/fhir/service/Terminology/CrfLibraryService.ts`):
un CodeSystem con property `grade1` è classificato CTCAE (gradi, gruppo `soc`),
con `category`/`macrogroup` PRO-CTCAE-like, con `answ*` EORTC-like (gruppo `head`).
Caricata una nuova library su HAPI, il bottone di import compare nel Questionnaire
builder **senza modifiche al codice frontend**. `QuestionnaireItem.prefix` viene
impostato dalla property `number`.

Documentazione completa: `irccs-docker/docs/modules/ROOT/pages/librerie-crf.adoc`.
