#!/usr/bin/env bash
# Disattiva la manutenzione COMPLETA: ferma il nginx fallback, riavvia lo
# stack Docker, aspetta che irccs-httpd-dashboard sia up, svuota il flag.
#
# Nginx va fermato PRIMA di "docker compose up": tengono entrambi la stessa
# porta (80/443), non possono stare su insieme. Con nginx ancora attivo
# "docker compose up" fallisce con "address already in use" (visto in lab).
# C'e' quindi una finestra di qualche secondo, tra lo stop di nginx e
# l'avvio di httpd, in cui la porta non risponde: inevitabile, non
# eliminabile senza un layer esterno (vedi discussione in README).
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

if systemctl is-active --quiet irccs-maintenance 2>/dev/null; then
    echo "[..] Fermo il fallback host-level (nginx) per liberare la porta..."
    sudo systemctl stop irccs-maintenance
    echo "[OK] Fallback host-level fermato."
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
        echo "  Il nginx fallback e' gia' fermo: la porta potrebbe restare"
        echo "  scoperta finche' non risolvi. Controlla 'docker compose logs irccs-httpd'."
        echo "  Puoi rimettere su il fallback nel frattempo:"
        echo "    sudo systemctl start irccs-maintenance"
        exit 1
    fi
done

: > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1) svuotato."
echo "[OK] Sito tornato operativo."
