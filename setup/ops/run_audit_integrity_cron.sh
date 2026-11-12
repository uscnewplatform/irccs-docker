#!/usr/bin/env bash
# ==============================================================================
# Script per l'esecuzione periodica schedulata (Cron / Systemd Timer / Container)
# della verifica di integrità dell'Audit Trail (Hash-Chain).
#
# Esegue verify_audit_hash_chain.py in modalità incrementale (o full), emettendo
# le righe di log AUDIT-INTEGRITY-OK / AUDIT-INTEGRITY-VIOLATION catturate da Loki
# ed aggiornando le metriche Prometheus Textfile se configurate.
#
# Uso:
#   ./run_audit_integrity_cron.sh [--full]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/verify_audit_hash_chain.py"

AUDIT_FHIR_URL="${IRCCS_AUDIT_FHIR_URL:-http://127.0.0.1:8081/fhir}"
STATE_FILE="${IRCCS_AUDIT_CHECKPOINT_FILE:-${SCRIPT_DIR}/.audit_integrity_checkpoint.json}"
REPORT_FILE="${IRCCS_AUDIT_REPORT_FILE:-${SCRIPT_DIR}/audit-integrity-last-report.json}"
PROMETHEUS_TEXTFILE="${IRCCS_AUDIT_PROMETHEUS_FILE:-/var/run/node_exporter/audit_integrity.prom}"

MODE_ARG="--incremental"
if [[ "${1:-}" == "--full" ]]; then
    MODE_ARG="--full"
fi

PROM_ARG=""
if [[ -d "$(dirname "${PROMETHEUS_TEXTFILE}")" ]]; then
    PROM_ARG="--prometheus-textfile ${PROMETHEUS_TEXTFILE}"
fi

python3 "${PYTHON_SCRIPT}" \
    --audit-fhir "${AUDIT_FHIR_URL}" \
    ${MODE_ARG} \
    --checkpoint-file "${STATE_FILE}" \
    --report-file "${REPORT_FILE}" \
    ${PROM_ARG}
