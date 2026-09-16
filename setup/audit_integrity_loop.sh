#!/bin/sh
# ==============================================================================
# Loop di verifica continua dell'integrità dell'audit trail (hash-chain).
# Pensato come entrypoint del container `irccs-audit-integrity` (python:3-alpine,
# nessuna dipendenza: verify_audit_hash_chain.py usa solo la stdlib).
#
# - verifica INCREMENTALE ogni AUDIT_INTEGRITY_INTERVAL secondi (default 900):
#   controlla solo gli AuditEvent nuovi dall'ultimo checkpoint;
# - verifica FULL ogni AUDIT_INTEGRITY_FULL_EVERY cicli (default 96 = ~24h con
#   intervallo 900s): ri-verifica l'intero storico, così una manomissione di un
#   evento già "checkpointato" viene comunque rilevata entro 24h.
#
# L'output (AUDIT-INTEGRITY-OK / -FORK / -VIOLATION / -ERROR) va su stdout/stderr
# del container -> Alloy -> Loki -> regole Grafana `irccs-audit-integrity-*`.
# ==============================================================================
set -u

SCRIPT="${AUDIT_INTEGRITY_SCRIPT:-/setup/verify_audit_hash_chain.py}"
AUDIT_FHIR="${IRCCS_AUDIT_FHIR_URL:-http://irccs-hapi-audit:8080/fhir}"
STATE_DIR="${AUDIT_INTEGRITY_STATE_DIR:-/state}"
INTERVAL="${AUDIT_INTEGRITY_INTERVAL:-900}"
FULL_EVERY="${AUDIT_INTEGRITY_FULL_EVERY:-96}"
EXTRA_ARGS="${AUDIT_INTEGRITY_EXTRA_ARGS:-}"

CHECKPOINT="${STATE_DIR}/audit_integrity_checkpoint.json"
REPORT="${STATE_DIR}/audit-integrity-last-report.json"
PROM="${STATE_DIR}/audit_integrity.prom"

mkdir -p "${STATE_DIR}"
cycle=0

echo "audit_integrity_loop: avvio (fhir=${AUDIT_FHIR} interval=${INTERVAL}s full_every=${FULL_EVERY})"

while true; do
    # incrementale: --strict, un fork nel delta di eventi nuovi = anomalia reale.
    # full (~ogni 24h): lenient, i fork storici ai riavvii dello stack sono attesi.
    if [ "$((cycle % FULL_EVERY))" -eq 0 ]; then
        mode="--full"
    else
        mode="--incremental --strict"
    fi

    # shellcheck disable=SC2086
    python3 "${SCRIPT}" \
        --audit-fhir "${AUDIT_FHIR}" \
        ${mode} \
        --checkpoint-file "${CHECKPOINT}" \
        --report-file "${REPORT}" \
        --prometheus-textfile "${PROM}" \
        --quiet \
        ${EXTRA_ARGS} \
        || echo "audit_integrity_loop: verifica ${mode} uscita con codice $? (dettaglio sopra)"

    cycle=$((cycle + 1))
    sleep "${INTERVAL}"
done
