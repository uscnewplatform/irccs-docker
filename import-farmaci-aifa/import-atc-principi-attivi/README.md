# import-atc-principi-attivi

Importa i **principi attivi** dei farmaci (per codice ATC) in HAPI FHIR come `CodeSystem` + `ValueSet`,
da usare in `answerValueSet` dei Questionnaire (builder questionari).

Posizione: `irccs-docker/import-farmaci-aifa/import-atc-principi-attivi/` (sottocartella dell'import farmaci AIFA).
Sorgente: `confezioni.csv` (export AIFA "lista confezioni", separatore `;`).
Indipendente dagli altri import (farmaci-aifa nella cartella padre, CTCAE): URL canoniche diverse → non li tocca.

## Modello dati (code = AIC rappresentante)

ATC ↔ principio attivo è **many-to-many** (709 ATC con >1 PA, 261 PA con >1 ATC).
FHIR impone `code` univoco, quindi un concetto per **coppia (ATC, PA)**:

| Campo | Valore | Esempio |
|---|---|---|
| `code` | **AIC rappresentante** della coppia (codice AIFA reale, univoco) | `032142022` |
| `display` | principio attivo esatto (`PA_ASSOCIATI`) | `CLOREXIDINA DIGLUCONATO` |
| `property` `atc` | codice ATC | `A01AB03` |
| `property` `aic` | = code (AIC) | `032142022` |

- **Niente designation.** Ogni PA è una voce selezionabile/visualizzabile a sé.
- `code` = un AIC reale → **linkabile a `farmaci-aifa`** (CodeSystem `.../farmaci`, `code=AIC`). L'ATC è in `property.atc`.
- In `QuestionnaireResponse`: `Coding{system, code:"032142022", display:"CLOREXIDINA DIGLUCONATO"}`.
- Ogni coppia (ATC, PA) ha ≥1 AIC; se ne sceglie **uno** (l'AIC minimo) come rappresentante.
- Righe scartate: `CODICE_ATC`/`CODICE_AIC` vuoto, `PA_ASSOCIATI` vuoto o `N.D.` (usa `--include-nd` per tenerle).

Numeri sull'export attuale: 138.640 righe valide → 2256 ATC distinti, 3907 PA distinte, **4278 concetti**.

## Registro `pa-aic-registry.json` (stabilità dei code)

L'AIC rappresentante va **congelato**, altrimenti se quella confezione viene ritirata cambierebbe → code orfano.

- `pa-aic-registry.json` mappa `"<ATC>|<PA>" → AIC` scelto **la prima volta**.
- Ad ogni run: coppie già note → **riusano** l'AIC registrato (anche se la confezione è sparita dal CSV); coppie nuove → ricevono l'AIC minimo, registrato.
- È la **fonte di verità** della stabilità: va **conservato e versionato** (committalo). Se lo perdi, i code possono cambiare al prossimo import.

## Versionamento / nuovo CSV

Quando AIFA pubblica un nuovo `confezioni.csv`:

1. Lancia di nuovo lo script (con `--csv <nuovo>` o mettendo il file in `<version>/confezioni.csv`). **Tieni** `pa-aic-registry.json`.
2. Upload in **PUT su id fisso** → la risorsa su HAPI viene **sovrascritta** ("ultima versione vince"). Niente coesistenza multi-versione: `answerValueSet` non ha versione, espande sempre l'ultima.
3. I `code` delle coppie esistenti **non cambiano** (registro) → risposte storiche intatte. Coppie nuove = nuovi concetti; PA ritirate spariscono dal set ma le risposte vecchie conservano il `display` salvato (leggibili, non più riselezionabili).
4. Il CSV usato viene archiviato in `<version>/confezioni.csv` (snapshot/audit). Disattiva con `--no-archive`.

> Differenza con `farmaci-aifa`: quello tiene **più versioni coesistenti** su HAPI. Qui basta l'ultima versione perché il code è reso stabile dal registro.

## Risorse FHIR generate

| Risorsa | id | URL canonica |
|---|---|---|
| CodeSystem | `aifa-atc-principi-attivi` | `http://terminology.hl7.it/CodeSystem/aifa-atc-principi-attivi` |
| ValueSet | `aifa-atc-all` | `http://terminology.hl7.it/ValueSet/aifa-atc-all` |

## Uso

```bash
# Genera i JSON e carica su HAPI (PUT idempotente, CodeSystem prima del ValueSet)
python3 import-atc-principi-attivi.py http://localhost:8080/fhir --csv /percorso/confezioni.csv

# Solo generazione file, niente upload
python3 import-atc-principi-attivi.py --csv /percorso/confezioni.csv --files-only

# Elenca le versioni gia su HAPI
python3 import-atc-principi-attivi.py http://localhost:8080/fhir --list
```

Opzioni: `--version YYYY-MM` (default mese corrente) · `--include-nd` · `--files-only`/`--no-upload` · `--no-archive`.
Default `--csv`: `<version>/confezioni.csv`, poi `./confezioni.csv`.
Output: `CodeSystem-ATC.json`, `ValueSet-ATC.json`, `pa-aic-registry.json` (**da conservare**), `<version>/confezioni.csv` (snapshot).

Upload manuale equivalente (PUT su id fisso = niente duplicati):

```bash
curl -X PUT http://localhost:8080/fhir/CodeSystem/aifa-atc-principi-attivi \
  -H "Content-Type: application/fhir+json" -d @CodeSystem-ATC.json
curl -X PUT http://localhost:8080/fhir/ValueSet/aifa-atc-all \
  -H "Content-Type: application/fhir+json" -d @ValueSet-ATC.json
```

> Caricare **sia** CodeSystem **sia** ValueSet (CodeSystem per primo): `$expand` del ValueSet legge i concetti dal CodeSystem referenziato.

## Import & pre-expansion (serve un reindex?)

**No reindex manuale** dei search parameter. Ma la ricerca per nome (`$expand?filter=`) su un CodeSystem grande (4278 concetti) richiede la **pre-expansion** della terminologia, che HAPI fa **in background da solo**.

Cosa succede dopo l'upload:

1. HAPI indicizza i concetti (deferred storage) e **pre-espande** il ValueSet con un **job schedulato** (default ~ogni 10 min).
2. La ricerca filtrata funziona **dopo** che la pre-expansion è completata. Serve il full-text attivo: in `pascale-local` è già così (`hibernate.search.enabled: true`, backend Lucene).
3. Nei primi minuti `$expand?filter=` può tornare **vuoto**. La dashboard ha un fallback (`TerminologyService`: se l'expansion è vuota usa `compose.include`) → mostra i concetti ma **senza filtro** finché l'indice non è pronto.

> Perché è necessaria: HAPI rifiuta l'espansione in-memory con `filter` oltre ~1000 concetti. Con 4278 concetti la ricerca per nome gira **solo** via pre-expansion.

Procedura:

1. Carica CodeSystem + ValueSet (vedi sopra).
2. Attendi il job di pre-expansion (~10 min) **oppure riavvia HAPI** per forzarlo prima.
3. Verifica che la ricerca filtrata risponda:

```bash
curl "http://localhost:8080/fhir/ValueSet/\$expand?url=http://terminology.hl7.it/ValueSet/aifa-atc-all&filter=clorexidina&count=20"
```

Se torna i concetti filtrati → pronto. Se vuoto → la pre-expansion non è ancora finita.

Stesso comportamento dell'import `farmaci-aifa` (automatico, nessuno step manuale di reindex).

## Nel Questionnaire

```json
{ "type": "choice", "answerValueSet": "http://terminology.hl7.it/ValueSet/aifa-atc-all" }
```

L'autocomplete della dashboard (`PatientQuestionnaire` → `searchValueSetConcepts` → `$expand?filter=`)
funziona senza modifiche: cerca e salva il `display` (= principio attivo).

## Query HAPI utili

```
GET /ValueSet/$expand?url=http://terminology.hl7.it/ValueSet/aifa-atc-all&filter=clorexidina
GET /CodeSystem/$lookup?system=http://terminology.hl7.it/CodeSystem/aifa-atc-principi-attivi&code=032142022
```

## Confronto con gli altri import terminologici

| Import | Posizione | code | display | Note |
|---|---|---|---|---|
| farmaci-aifa | `import-farmaci-aifa/` (cartella padre) | AIC (per confezione) | PA — nome commerciale | 1 concetto per confezione; più versioni coesistenti |
| **atc-principi-attivi** | `import-farmaci-aifa/import-atc-principi-attivi/` | AIC rappresentante | principio attivo | 1 concetto per coppia ATC+PA; code stabile via registro, overwrite-latest |
| ctcae-v6 | `pascale-local/setup/` | codice CTCAE | termine evento avverso | bundle pre-generato |
