#!/usr/bin/env bash
# Disattiva la manutenzione: svuota il flag (livello 1) e ferma il fallback
# host-level (livello 2) se attivo.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_FILE="$COMPOSE_DIR/httpd-config/.maintenance-flag"

: > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1, backend) disattivato."

if systemctl is-active --quiet irccs-maintenance 2>/dev/null; then
    echo "[INFO] Fallback host-level attivo: lo fermo prima che irccs-httpd riprenda 443."
    sudo systemctl stop irccs-maintenance
    echo "[OK] Fallback host-level fermato."
fi

echo "[INFO] Se lo stack era fermo, ricordati: docker compose up -d"
