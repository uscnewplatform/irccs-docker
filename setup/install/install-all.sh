#!/usr/bin/env bash
# Prima installazione — esegue in sequenza TUTTI gli step automatizzabili
# (via API HAPI FHIR, zero click da UI) descritti in
# docs/modules/ROOT/pages/installazione.adoc.
#
# NON fa (restano manuali, vedi installazione.adoc):
#   - configurazione SMTP/lingua/tema/client-secret in Keycloak (richiede UI)
#   - abilitazione SSL Keycloac
#   - import terminologia LOINC (richiede account loinc.org + file scaricati
#     a mano + CLI dentro il container: 15-30 minuti, vedi sezione dedicata
#     in installazione.adoc — NON incluso qui di proposito)
#
# Uso:
#   cd irccs-docker
#   ./setup/install/install-all.sh <HAPI_URL>
#
# Esempio (stack locale, dallo host):
#   ./setup/install/install-all.sh http://localhost:8080/fhir
#
# Esempio (da dentro un altro container sulla stessa rete Docker):
#   ./setup/install/install-all.sh http://irccs-hapi-fhir:8080/fhir
#
# Idempotente nel suo complesso: ogni script sottostante lo e' gia'
# singolarmente (PUT/conditional-PUT) — rieseguirlo dopo un'interruzione
# non duplica nulla, riprende semplicemente dall'inizio.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Uso: $0 <HAPI_URL>"
  echo "Esempio: $0 http://localhost:8080/fhir"
  exit 1
fi

HAPI_URL="${1%/}"
# install_searchparameters.sh e install_consent_types.sh vogliono "host:port"
# (senza schema, senza /fhir — lo aggiungono loro internamente, solo http://).
HOSTNAME_PORT="${HAPI_URL#http://}"
HOSTNAME_PORT="${HOSTNAME_PORT#https://}"
HOSTNAME_PORT="${HOSTNAME_PORT%/fhir}"

# Step 5/6 (farmaci AIFA) richiedono il modulo Python "requests".
# Su host con Python gestito dal sistema (PEP 668) puo' servire un venv:
#   python3 -m venv .venv && .venv/bin/pip install -r data-import/farmaci-aifa/requirements.txt
# e poi rilanciare questo script con quel python: PYTHON_BIN=.venv/bin/python ./setup/install/install-all.sh ...
PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! "$PYTHON_BIN" -c "import requests" 2>/dev/null; then
  echo "ERRORE: modulo Python 'requests' non trovato per $PYTHON_BIN (richiesto dagli step 5-6, import farmaci AIFA)."
  echo "Soluzione:"
  echo "  python3 -m venv .venv && .venv/bin/pip install -r data-import/farmaci-aifa/requirements.txt"
  echo "  PYTHON_BIN=\"\$(pwd)/.venv/bin/python\" $0 $HAPI_URL"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DATA_IMPORT_DIR="$(cd "$SCRIPT_DIR/../../data-import" && pwd)"

STEP=0
TOTAL=6

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  [$STEP/$TOTAL] $1"
  echo "════════════════════════════════════════════════════════════"
  echo "$2"
  echo ""
}

# ──────────────────────────────────────────────────────────────────
step "Search Parameters FHIR" \
"Cosa fa: installa i SearchParameter custom richiesti dai microservizi
(es. entity-identifier su AuditEvent, campi custom su altre risorse).
Va fatto per primo: senza questi, alcune query dei microservizi falliscono
silenziosamente o restituiscono liste vuote.
Input: solo host:port ricavato da HAPI_URL (es. localhost:8080)."
bash "$SCRIPT_DIR/install_searchparameters.sh" "$HOSTNAME_PORT"

# ──────────────────────────────────────────────────────────────────
step "Patient Journey J-LI" \
"Cosa fa: carica il transaction bundle J-LI_Batch.json (Patient Journey
di esempio/default) su HAPI FHIR.
Input: solo HAPI_URL."
bash "$SCRIPT_DIR/install_jli.sh" "$HAPI_URL"

# ──────────────────────────────────────────────────────────────────
step "Tipi di consenso (registry)" \
"Cosa fa: precarica i 9 tipi di consenso base (CodeSystem
urn:irccs:consent-type, terminologia HL7) — necessario perché il designer
studi e il tipo 'privacy' funzionino da subito.
Input: solo host:port ricavato da HAPI_URL. Idempotente (PUT conditional),
rilanciabile senza creare duplicati."
bash "$SCRIPT_DIR/install_consent_types.sh" "$HOSTNAME_PORT"

# ──────────────────────────────────────────────────────────────────
step "Librerie CRF (CTCAE, EORTC, EuroQol, PRO-CTCAE, USC PROFFIT)" \
"Cosa fa: carica su HAPI, una per una, tutte le librerie terminologiche CRF
committate in data-import/crf-libraries/ (CodeSystem + ValueSet +
StructureDefinition, bundle pre-generati — nessun download esterno).
Dopo questo step il bottone di import compare nel Questionnaire builder
del dashboard senza altre modifiche.
Input: solo HAPI_URL, uguale per ogni libreria."
for install_sh in "$DATA_IMPORT_DIR"/crf-libraries/*/install-*.sh; do
  lib_name="$(basename "$(dirname "$install_sh")")"
  echo "  → libreria: $lib_name"
  bash "$install_sh" "$HAPI_URL"
done

# ──────────────────────────────────────────────────────────────────
step "Farmaci AIFA — classi A/H + equivalenti" \
"Cosa fa: importa il catalogo farmaci AIFA per classe (A/H) ed equivalenti
come CodeSystem+ValueSet versionati. Se i CSV della versione corrente non
sono già committati in data-import/farmaci-aifa/import-aifa-per-classi/,
lo script li SCARICA da aifa.gov.it (richiede accesso internet in uscita
dall'host che esegue questo script).
Input: solo HAPI_URL (usa la versione = mese corrente di default)."
"$PYTHON_BIN" "$DATA_IMPORT_DIR/farmaci-aifa/import-aifa-per-classi/import-aifa-farmaci.py" "$HAPI_URL"

# ──────────────────────────────────────────────────────────────────
step "Farmaci AIFA — confezioni + ATC (159k concept, batch)" \
"Cosa fa: importa il catalogo farmaci per confezione/AIC con codice ATC,
a lotti di 2000 concept (evita timeout/OOM su un'unica transazione gigante).
Usa il CSV già committato in data-import/farmaci-aifa/import-confezioni-atc/
— nessun download. Richiede qualche minuto (159k concept).
Input: solo HAPI_URL."
"$PYTHON_BIN" "$DATA_IMPORT_DIR/farmaci-aifa/import-confezioni-atc/import-confezioni-atc-batch.py" "$HAPI_URL"

# ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ Tutti gli step automatici completati ($TOTAL/$TOTAL)."
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Restano da fare A MANO (vedi installazione.adoc):"
echo "  - Configurazione SMTP/lingua/tema/client-secret in Keycloak (UI)"
echo "  - Import terminologia LOINC — OPZIONALE, NON automatizzato qui:"
echo "    richiede account su loinc.org, download manuale dello zip,"
echo "    hapi-fhir-cli.jar della stessa versione del server, e"
echo "    l'esecuzione DENTRO il container irccs-hapi-fhir (15-30 minuti)."
echo "    Procedura completa: docs/modules/ROOT/pages/installazione.adoc,"
echo "    sezione 'C. Import terminologia LOINC (opzionale, MANUALE)'."
echo ""
