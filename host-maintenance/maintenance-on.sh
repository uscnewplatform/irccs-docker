#!/usr/bin/env bash
# Attiva la manutenzione. Sceglie automaticamente il livello giusto:
#   - se irccs-httpd-dashboard e' up -> attiva solo il flag (livello 1, backend)
#   - se non risponde -> presuppone stack/httpd giu', ricorda di avviare
#     il fallback host-level (livello 2)
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_FILE="$COMPOSE_DIR/httpd-config/.maintenance-flag"

echo "manutenzione attivata il $(date -Iseconds)" > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1, backend) attivato: $FLAG_FILE"

if docker ps --format '{{.Names}}' | grep -q '^irccs-httpd-dashboard$'; then
    echo "[OK] irccs-httpd-dashboard e' up: le richieste ora ricevono 503 + maintenance.html."
else
    echo "[ATTENZIONE] irccs-httpd-dashboard non risulta attivo."
    echo "  Se stai per fermare l'intero stack (docker compose down) o aggiornare"
    echo "  httpd stesso, avvia anche il fallback host-level PRIMA di fermarlo:"
    echo "    sudo systemctl start irccs-maintenance"
fi
