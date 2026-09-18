#!/usr/bin/env bash
# Attiva la manutenzione COMPLETA: flag (livello 1) + nginx fallback host
# (livello 2) + ferma lo stack Docker. Sequenza testata in lab:
#   flag ON -> nginx fallback ON -> docker compose down
# cosi' la porta resta sempre coperta, nessuna finestra di 502/connection
# refused tra "backend giu'" e "httpd giu'".
#
# Richiede il setup una tantum del fallback (vedi README-maintenance.md,
# sezione Installazione) gia' fatto sull'host.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_FILE="$COMPOSE_DIR/httpd-config/.maintenance-flag"

echo "manutenzione attivata il $(date -Iseconds)" > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1, backend) attivato: $FLAG_FILE"

if ! systemctl list-unit-files irccs-maintenance.service &>/dev/null; then
    echo "[ERRORE] irccs-maintenance.service non installato. Vedi README-maintenance.md (Installazione)."
    exit 1
fi

if systemctl is-active --quiet irccs-maintenance; then
    echo "[OK] Fallback host-level (nginx) gia' attivo."
else
    echo "[..] Avvio fallback host-level (nginx) su questa porta..."
    sudo systemctl start irccs-maintenance
    echo "[OK] Fallback host-level attivo: la porta e' coperta anche a stack fermo."
fi

echo "[..] Fermo lo stack Docker (docker compose down)..."
(cd "$COMPOSE_DIR" && docker compose down)
echo "[OK] Stack fermo. Sito in manutenzione, servito da nginx host-level."
