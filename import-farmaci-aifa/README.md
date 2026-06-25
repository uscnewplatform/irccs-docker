# Import Farmaci AIFA → HAPI FHIR

Carica il catalogo farmaci AIFA come risorse FHIR Terminology (CodeSystem + ValueSet) su HAPI FHIR.

Due pipeline **indipendenti**, con URL canonici diversi → coesistono sullo stesso HAPI:

| Pipeline | Cartella | Granularità | CodeSystem | Quando |
|---|---|---|---|---|
| **Per classi** (A/H) | `import-aifa-per-classi/` | 1 concept = farmaco per nome commerciale | `farmaci` | catalogo Classe A/H, ~12.9k, versionato per snapshot |
| **Confezioni (ATC)** | `import-confezioni-atc/` | 1 concept = confezione (AIC) | `farmaci-confezioni-atc-np` | catalogo completo confezioni, ~159k, ricerca per principio attivo |

## Struttura cartelle

```
import-farmaci-aifa/
├── README.md
├── requirements.txt                       ← dipendenze Python (requests)
├── import-aifa-per-classi/                ← PIPELINE A: Classe A/H
│   ├── import-aifa-farmaci.py             ← script di import (non toccare)
│   └── 2026-05/                           ← snapshot maggio 2026 (incluso nel repo)
│       ├── aifa_classe_a.csv
│       ├── aifa_classe_h.csv
│       └── aifa_equivalenti.csv
└── import-confezioni-atc/                 ← PIPELINE B: confezioni
    ├── import-confezioni-atc-batch.py     ← script di import a lotti (non toccare)
    └── 2026-06/
        └── confezioni.csv                 ← catalogo confezioni AIFA (~159k righe)
```

Ogni sottocartella `YYYY-MM` contiene i CSV del relativo snapshot AIFA.
Il nome della cartella coincide con la versione usata nelle risorse FHIR.

## Prerequisiti

- Python 3.10+
- Dipendenze Python:
  ```bash
  pip install -r requirements.txt
  ```
- HAPI FHIR raggiungibile (locale o remoto)

---

# Pipeline A — Farmaci per classi (A/H)

Catalogo AIFA Classe A/H come `CodeSystem farmaci` + ValueSet versionati.
Supporta versionamento annuale: versioni diverse coesistono, nessun duplicato.

## Utilizzo

```bash
cd import-aifa-per-classi

# Import della cartella 2026-05 già presente
python3 import-aifa-farmaci.py http://localhost:8080/fhir --version 2026-05

# Import con versione automatica (mese corrente)
python3 import-aifa-farmaci.py http://localhost:8080/fhir

# Elenca versioni caricate su HAPI (+ cartelle locali presenti)
python3 import-aifa-farmaci.py http://localhost:8080/fhir --list

# Forza re-download dei CSV da aifa.gov.it nella cartella di versione
python3 import-aifa-farmaci.py http://localhost:8080/fhir --version 2026-05 --force-download
```

## Aggiornamento annuale

### 1. Crea la nuova cartella

```bash
mkdir import-aifa-per-classi/2026-10
```

### 2. Scarica i nuovi CSV da AIFA e salvali nella cartella

| File da salvare | Fonte AIFA |
|---|---|
| `aifa_classe_a.csv` | [Classe A per nome commerciale](https://www.aifa.gov.it/en/liste-farmaci-a-h) |
| `aifa_classe_h.csv` | [Classe H per nome commerciale](https://www.aifa.gov.it/en/liste-farmaci-a-h) |
| `aifa_equivalenti.csv` | [Lista Trasparenza](https://www.aifa.gov.it/en/liste-di-trasparenza) (ha il codice ATC) |

In alternativa, lo script scarica automaticamente se la cartella è vuota o con `--force-download`.
Se le URL AIFA cambiano, aggiorna `CSV_A_URL`, `CSV_H_URL`, `CSV_EQUIV_URL` nello script.

### 3. Esegui l'import

```bash
python3 import-aifa-farmaci.py http://localhost:8080/fhir --version 2026-10
```

### 4. Verifica

```bash
python3 import-aifa-farmaci.py http://localhost:8080/fhir --list
```

Output atteso:

```
Versioni CodeSystem su HAPI:

  Versione     Data         Concetti   CSV locale   ID FHIR
  ------------ ------------ ---------- ------------ -----------
  2026-05      2026-05-13   12906      SI           abc123...
  2026-10      2026-10-07   13100      SI           def456...
```

La cartella `2026-05` rimane nel repo; i questionari già creati con quella versione continuano a funzionare.

## Versionamento FHIR

Ogni import produce risorse con la **stessa URL canonica** e una **versione diversa**.

```
CodeSystem url = https://aifa.gov.it/fhir/CodeSystem/farmaci
               version = 2026-05   ← snapshot maggio 2026
               version = 2026-10   ← snapshot ottobre 2026  ← default (più recente)
```

| Situazione | Azione |
|---|---|
| Prima esecuzione con versione X | `POST` → crea |
| Ri-esecuzione con stessa versione X | `PUT` → aggiorna in-place, **zero duplicati** |
| Esecuzione con nuova versione Y | `POST` → crea, la X rimane |

### Query per versione specifica

```bash
# Ultima versione (default)
GET /fhir/ValueSet/$expand?url=https://aifa.gov.it/fhir/ValueSet/farmaci-aifa&filter=aspirina

# Versione storica specifica
GET /fhir/ValueSet/$expand?url=https://aifa.gov.it/fhir/ValueSet/farmaci-aifa&valueSetVersion=2026-05&filter=aspirina
```

### Pinnare uno studio a una versione

```json
{
  "linkId": "farmaco",
  "type": "choice",
  "answerValueSet": "https://aifa.gov.it/fhir/ValueSet/farmaci-aifa|2026-05"
}
```

## Risorse FHIR create

| Risorsa | URL canonica |
|---|---|
| CodeSystem | `https://aifa.gov.it/fhir/CodeSystem/farmaci` |
| ValueSet Classe A | `https://aifa.gov.it/fhir/ValueSet/farmaci-classe-a` |
| ValueSet Classe H | `https://aifa.gov.it/fhir/ValueSet/farmaci-classe-h` |
| ValueSet Tutti (A+H) | `https://aifa.gov.it/fhir/ValueSet/farmaci-aifa` |
| ValueSet con ATC | `https://aifa.gov.it/fhir/ValueSet/farmaci-con-atc` |

### Proprietà CodeSystem

| Proprietà | Tipo | Disponibilità |
|---|---|---|
| `principio-attivo` | string | Sempre |
| `descrizione-gruppo` | string | Sempre |
| `titolare-aic` | string | Sempre |
| `classe` | code (`A` / `H`) | Sempre |
| `atc` | code (es. `A10AE04`) | ~65% dei farmaci |

## API HAPI FHIR

```bash
# Ricerca per nome
curl "http://localhost:8080/fhir/ValueSet/\$expand?url=https://aifa.gov.it/fhir/ValueSet/farmaci-aifa&filter=aspirina&count=20"

# Dettagli farmaco (principio attivo, ATC, classe...)
curl "http://localhost:8080/fhir/CodeSystem/\$lookup?system=https://aifa.gov.it/fhir/CodeSystem/farmaci&code=043658032"

# Validazione codice AIC
curl "http://localhost:8080/fhir/CodeSystem/\$validate-code?url=https://aifa.gov.it/fhir/CodeSystem/farmaci&code=043658032"

# Lista versioni
curl "http://localhost:8080/fhir/CodeSystem?url=https://aifa.gov.it/fhir/CodeSystem/farmaci&_elements=version,date,count"
```

---

# Pipeline B — Confezioni (catalogo completo)

Catalogo completo AIFA a livello di **confezione** (~159k, da `confezioni.csv`), usato come
`answerValueSet` di una multichoice nel CRF: si cerca per **principio attivo** e si seleziona la confezione.

## Perché a lotti (non una PUT unica)

`content=complete` con 159k concept in **una sola PUT** (~122MB) non regge su HAPI (OOM/timeout,
transazione che non committa). Lo script carica i concept a **lotti via `$apply-codesystem-delta-add`**:
tante transazioni piccole, progresso visibile, ripartenza con `--skip`.

Il CodeSystem è quindi `content=not-present` (delta-add lo richiede).

## Utilizzo

```bash
cd import-confezioni-atc

# Smoke test (primi 2000 concept) — verifica connettività + HAPI
python3 import-confezioni-atc-batch.py http://localhost:8080/fhir --limit 2000

# Carico completo (~159k, lotti da 2000)
python3 import-confezioni-atc-batch.py http://localhost:8080/fhir

# Ripartenza dopo interruzione (lo skip da usare lo stampa lo script stesso)
python3 import-confezioni-atc-batch.py http://localhost:8080/fhir --skip 40000
```

Il CSV (`2026-06/confezioni.csv`) viene risolto automaticamente; usa `--csv PATH` per sovrascriverlo.

### Opzioni

| Opzione | Default | Descrizione |
|---|---|---|
| `HAPI_URL` (posizionale) | `http://localhost:8080/fhir` | endpoint FHIR |
| `--csv PATH` | auto (`2026-06/confezioni.csv`) | CSV sorgente |
| `--version YYYY-MM` | mese corrente | versione delle risorse FHIR |
| `--batch-size N` | `2000` | concept per lotto |
| `--limit N` | — | carica solo i primi N (test) |
| `--skip N` | `0` | salta i primi N (ripartenza) |
| `--cs-url URL` / `--vs-url URL` | URL `*-np` di default | override URL canonici |

## Ripartenza & auto-heal (HAPI-0389)

Se un run viene interrotto a metà, il CodeSystem può restare con **concept corrotti**
(`TermConcept` orfani da transazione non committata). Ri-eseguendo, HAPI risponde:

```
HTTP 500 — HAPI-0389: ... org.hibernate.TransientObjectException:
persistent instance references an unsaved transient instance of 'TermConcept'
```

Non è un problema di timing né di `--batch-size`: `delta-add` è idempotente sui code **sani**
(ri-aggiungerli → 200), ma su un code **corrotto** già presente lancia HAPI-0389 e fa fallire
l'intero lotto.

Lo script è **auto-healing**: su quell'errore fa `$apply-codesystem-delta-remove` del lotto
(purga i corrotti/esistenti, tollera i code assenti) e ritenta la `delta-add`. Sul happy-path
(code nuovi) il remove non scatta mai. Quindi:

- **ambiente nuovo** (CS mai usato) → carica diretto, nessun heal;
- **ripartenza** (`--skip N`) o **CS sporco** → l'auto-heal ripulisce e prosegue da solo.

Niente azione manuale: rilancia lo stesso comando (eventualmente con lo `--skip` che lo script stampa).

## Modello del concept

| Campo FHIR | Valore | Note |
|---|---|---|
| `code` | `CODICE_AIC` | codice AIFA univoco della confezione |
| `display` | `"PA — DENOMINAZIONE DESCRIZIONE"` | usato per la ricerca via `$expand?filter` |
| `property principio-attivo` | PA (valueString) | letto via `$lookup` |
| `property forma` | FORMA (valueString) | formulazione, read-only nel CRF |
| `property atc` | CODICE_ATC (valueString) | |

> ⚠️ `$apply-codesystem-delta-add` **scarta le designation ma tiene le property**, e `$expand`
> ritorna le designation ma **non** le property. Quindi col `not-present`:
> - **ricerca** per principio attivo = via **display** (il PA è in testa al display, `$expand?filter` lo matcha) — richiede pre-espansione (`pre_expand_value_sets: true` su HAPI);
> - **forma / atc / pa** = property, recuperate dal frontend con **`$lookup`** alla selezione del farmaco (non da `$expand`).

## Risorse FHIR create

| Risorsa | URL canonica (default) |
|---|---|
| CodeSystem | `https://aifa.gov.it/fhir/CodeSystem/farmaci-confezioni-atc-np` |
| ValueSet | `https://aifa.gov.it/fhir/ValueSet/farmaci-confezioni-atc-np` |

## API HAPI FHIR

```bash
# Ricerca per principio attivo (match sul display)
curl "http://localhost:8080/fhir/ValueSet/\$expand?url=https://aifa.gov.it/fhir/ValueSet/farmaci-confezioni-atc-np&filter=metformina&count=20"

# Dettagli confezione (forma, atc, principio-attivo) — property via $lookup
curl "http://localhost:8080/fhir/CodeSystem/\$lookup?system=https://aifa.gov.it/fhir/CodeSystem/farmaci-confezioni-atc-np&code=043658032"
```

---

## Fonti dati AIFA

Licenza: [CC BY 3.0 IT](https://creativecommons.org/licenses/by/3.0/it/) — AIFA Open Data.

| CSV | Pagina AIFA |
|---|---|
| Classe A / H | https://www.aifa.gov.it/en/liste-farmaci-a-h |
| Lista Trasparenza (con ATC) | https://www.aifa.gov.it/en/liste-di-trasparenza |
| Confezioni (catalogo completo) | https://www.aifa.gov.it/en/liste-di-trasparenza |
