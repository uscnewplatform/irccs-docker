#!/usr/bin/env bash
# Attiva la manutenzione COMPLETA: flag (livello 1) + ferma lo stack Docker
# + nginx fallback host (livello 2). Sequenza testata in lab:
#   flag ON -> docker compose down -> nginx fallback ON
#
# Ordine importante: nginx e irccs-httpd-dashboard vogliono la stessa porta
# e non possono coesistere. Se nginx si avvia mentre httpd e' ancora su,
# fallisce con "Address already in use" (bug visto in lab, corretto). Lo
# stack va fermato PRIMA. C'e' quindi una finestra di qualche secondo tra
# "docker compose down" e l'avvio di nginx in cui la porta non risponde:
# inevitabile con questa architettura (vedi nota in README).
#
# Richiede il setup una tantum del fallback (vedi README-maintenance.md,
# sezione Installazione) gia' fatto sull'host.
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

if ! systemctl list-unit-files irccs-maintenance.service &>/dev/null; then
    echo "[ERRORE] irccs-maintenance.service non installato. Vedi README-maintenance.md (Installazione)."
    exit 1
fi

echo "manutenzione attivata il $(date -Iseconds)" > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1, backend) attivato: $FLAG_FILE"

echo "[..] Fermo lo stack Docker (${COMPOSE[*]} down)..."
(cd "$COMPOSE_DIR" && "${COMPOSE[@]}" down)
echo "[OK] Stack fermo, porta libera."

if systemctl is-active --quiet irccs-maintenance; then
    echo "[OK] Fallback host-level (nginx) gia' attivo."
else
    echo "[..] Avvio fallback host-level (nginx)..."
    sudo systemctl start irccs-maintenance
    echo "[OK] Fallback host-level attivo: sito in manutenzione, servito da nginx host-level."
fi
