#!/usr/bin/env bash
# Disattiva la manutenzione COMPLETA: riavvia lo stack Docker, aspetta che
# irccs-httpd-dashboard sia up, ferma il nginx fallback e svuota il flag.
# Sequenza inversa di maintenance-on.sh, ordine importante: nginx deve
# fermarsi DOPO che httpd e' pronto a prendere la porta, altrimenti c'e'
# una finestra vuota tra i due.
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAG_FILE="$COMPOSE_DIR/httpd-config/.maintenance-flag"

if docker compose version &>/dev/null; then
    COMPOSE=(docker compose)
elif command -v docker-compose &>/dev/null; then
    COMPOSE=(docker-compose)
else
    echo "[ERRORE] Ne' 'docker compose' (v2) ne' 'docker-compose' (v1) trovati." >&2
    exit 1
fi

echo "[..] Riavvio lo stack Docker (${COMPOSE[*]} up -d)..."
(cd "$COMPOSE_DIR" && "${COMPOSE[@]}" up -d)

echo "[..] Attendo che irccs-httpd-dashboard sia up (max 60s)..."
for i in $(seq 1 30); do
    if docker ps --filter "name=^irccs-httpd-dashboard$" --filter "status=running" --format '{{.Names}}' | grep -q .; then
        echo "[OK] irccs-httpd-dashboard e' up."
        break
    fi
    sleep 2
    if [ "$i" -eq 30 ]; then
        echo "[ATTENZIONE] irccs-httpd-dashboard non risulta up dopo 60s."
        echo "  Non fermo il fallback host-level per non lasciare la porta scoperta."
        echo "  Controlla 'docker compose logs irccs-httpd' poi rilancia questo script."
        exit 1
    fi
done

if systemctl is-active --quiet irccs-maintenance 2>/dev/null; then
    echo "[..] Fermo il fallback host-level (nginx)..."
    sudo systemctl stop irccs-maintenance
    echo "[OK] Fallback host-level fermato."
fi

: > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1) svuotato."
echo "[OK] Sito tornato operativo."
