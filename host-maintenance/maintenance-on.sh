#!/usr/bin/env bash
# Attiva la manutenzione COMPLETA su TUTTI gli stack (main, monitoring, zammad, pwa).
# Sequenza:
#   1. flag livello 1 ON (httpd risponde 503 a dashboard, PWA e Zammad)
#   2. salva quali stack sono in esecuzione (serve a maintenance-off.sh)
#   3. ferma PER PRIMO irccs-httpd-dashboard e fa salire subito il nginx di
#      cortesia (stessa porta: httpd DEVE essere gia' fermo, altrimenti nginx
#      fallisce con "Address already in use"). Nginx serve la pagina di
#      assistenza anche per l'host di Zammad (pj-tk...) e per /app della PWA.
#   4. abbatte gli altri stack: pwa, zammad, monitoring, infine main
#      (main per ultimo: owner della rete "irccs" usata dagli altri).
#
# Tra lo stop di httpd e l'avvio di nginx la porta non risponde per qualche
# secondo: inevitabile (vedi README). Richiede il setup una tantum del
# fallback (README-maintenance.md, sezione Installazione).
set -euo pipefail

# shellcheck source=maintenance-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/maintenance-lib.sh"

if ! systemctl list-unit-files irccs-maintenance.service &>/dev/null; then
    echo "[ERRORE] irccs-maintenance.service non installato. Vedi README-maintenance.md (Installazione)."
    exit 1
fi

# 1. flag livello 1
echo "manutenzione attivata il $(date -Iseconds)" > "$FLAG_FILE"
echo "[OK] Flag di manutenzione (livello 1, backend) attivato: $FLAG_FILE"

# 2. stato stack in esecuzione (non sovrascrive se esiste gia': seconda
#    esecuzione di "on" a stack gia' fermi perderebbe l'informazione)
if [ ! -s "$STATE_FILE" ]; then
    : > "$STATE_FILE"
    for s in "${STACK_ORDER[@]}"; do
        stack_exists "$s" || continue
        if stack_running "$s"; then
            echo "$s" >> "$STATE_FILE"
        fi
    done
    echo "[OK] Stack in esecuzione salvati in $STATE_FILE: $(tr '\n' ' ' < "$STATE_FILE")"
else
    echo "[OK] $STATE_FILE gia' presente, lo mantengo: $(tr '\n' ' ' < "$STATE_FILE")"
fi

# 3. httpd per primo, poi nginx di cortesia
echo "[..] Fermo $HTTPD_CONTAINER..."
stack_compose main stop "$HTTPD_SERVICE"
echo "[OK] $HTTPD_CONTAINER fermo, porta libera."

if systemctl is-active --quiet irccs-maintenance; then
    echo "[OK] Fallback host-level (nginx) gia' attivo."
else
    echo "[..] Avvio fallback host-level (nginx)..."
    sudo systemctl start irccs-maintenance
    echo "[OK] Fallback host-level attivo: pagina di assistenza servita da nginx."
fi

# 4. gli altri stack, in ordine inverso di avvio
for ((i=${#STACK_ORDER[@]}-1; i>=0; i--)); do
    s="${STACK_ORDER[$i]}"
    stack_exists "$s" || { echo "[--] Stack $s: compose non trovato, salto."; continue; }
    echo "[..] Fermo stack $s..."
    if stack_compose "$s" down; then
        echo "[OK] Stack $s fermo."
    elif [ "$s" = "main" ]; then
        echo "[ERRORE] down dello stack main fallito." >&2
        exit 1
    else
        echo "[ATTENZIONE] down dello stack $s fallito, proseguo."
    fi
done

echo "[OK] Manutenzione attiva: tutti gli stack fermi, nginx serve la pagina di assistenza."
