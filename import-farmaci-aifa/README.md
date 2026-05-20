# Import Farmaci AIFA → HAPI FHIR

Carica il catalogo farmaci AIFA come risorse FHIR Terminology (CodeSystem + ValueSet) su HAPI FHIR.
Supporta versionamento annuale: versioni diverse coesistono, nessun duplicato.

## Struttura cartella

```
import-farmaci-aifa/
├── import-aifa-farmaci.py       ← script di import (non toccare)
├── README.md
├── 2026-05/                     ← snapshot maggio 2026 (incluso nel repo)
│   ├── aifa_classe_a.csv
│   ├── aifa_classe_h.csv
│   └── aifa_equivalenti.csv
└── 2026-10/                     ← esempio prossima versione (da creare)
    ├── aifa_classe_a.csv
    ├── ...
```

Ogni sottocartella `YYYY-MM` contiene i CSV del relativo snapshot AIFA.
Il nome della cartella coincide con la versione usata nelle risorse FHIR.

## Prerequisiti

- Python 3.10+
- Libreria `requests`:
  ```bash
  pip install requests
  ```
- HAPI FHIR raggiungibile (locale o remoto)

## Utilizzo

```bash
cd irccs-docker/import-farmaci-aifa

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
mkdir import-farmaci-aifa/2026-10
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

## Fonti dati AIFA

Licenza: [CC BY 3.0 IT](https://creativecommons.org/licenses/by/3.0/it/) — AIFA Open Data.

| CSV | Pagina AIFA |
|---|---|
| Classe A / H | https://www.aifa.gov.it/en/liste-farmaci-a-h |
| Lista Trasparenza (con ATC) | https://www.aifa.gov.it/en/liste-di-trasparenza |
