#!/usr/bin/env bash
# Disattiva la manutenzione COMPLETA e riporta TUTTI gli stack come prima
# (rialza solo quelli che maintenance-on.sh aveva trovato attivi; se il file
# di stato manca, rialza tutti).
# Sequenza (nginx resta su il piu' possibile, per ridurre la finestra senza risposta):
#   1. main: tutti i servizi TRANNE irccs-httpd (nginx serve ancora la pagina)
#   2. ferma nginx e avvia irccs-httpd (stessa porta: non possono coesistere)
#      -> il flag e' ancora ON: httpd serve 503 + pagina finche' non e' tutto su
#   3. rialza monitoring, zammad, pwa
#   4. svuota il flag livello 1
#
# Se httpd non parte entro 60s, il nginx di cortesia viene rimesso su
# automaticamente (il sito non resta scoperto) e lo script esce con errore.
set -euo pipefail

# shellcheck source=maintenance-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/maintenance-lib.sh"

if [ -s "$STATE_FILE" ]; then
    mapfile -t TO_START < "$STATE_FILE"
    echo "[OK] Stack da ripristinare (da $STATE_FILE): ${TO_START[*]}"
else
    TO_START=("${STACK_ORDER[@]}")
    echo "[ATTENZIONE] $STATE_FILE assente: ripristino tutti gli stack: ${TO_START[*]}"
fi
# main serve sempre: crea la rete "irccs" e contiene httpd
case " ${TO_START[*]} " in *" main "*) ;; *) TO_START=(main "${TO_START[@]}") ;; esac

ensure_bind_files

# 1. main senza httpd
mapfile -t MAIN_SERVICES < <(stack_compose main config --services | grep -vx "$HTTPD_SERVICE")
echo "[..] Avvio stack main (senza $HTTPD_SERVICE)..."
stack_compose main up -d "${MAIN_SERVICES[@]}"
echo "[OK] Stack main su (httpd escluso)."

# 2. nginx giu', httpd su
if systemctl is-active --quiet irccs-maintenance 2>/dev/null; then
    echo "[..] Fermo il fallback host-level (nginx) per liberare la porta..."
    sudo systemctl stop irccs-maintenance
    echo "[OK] Fallback host-level fermato."
fi
echo "[..] Avvio $HTTPD_CONTAINER..."
stack_compose main up -d "$HTTPD_SERVICE"

echo "[..] Attendo che $HTTPD_CONTAINER sia up (max 60s)..."
UP=0
for i in $(seq 1 30); do
    if docker ps --filter "name=^${HTTPD_CONTAINER}$" --filter "status=running" --format '{{.Names}}' | grep -q .; then
        UP=1; break
    fi
    sleep 2
done
if [ "$UP" -ne 1 ]; then
    echo "[ATTENZIONE] $HTTPD_CONTAINER non risulta up dopo 60s: rimetto su il fallback nginx."
    sudo systemctl start irccs-maintenance || true
    echo "  Controlla 'docker compose logs $HTTPD_SERVICE', poi rilancia questo script."
    exit 1
fi
echo "[OK] $HTTPD_CONTAINER e' up (flag ancora ON: pagina di assistenza via httpd)."

# 3. stack accessori (non bloccanti: un errore qui non deve lasciare il sito in manutenzione)
FAILED=()
for s in "${STACK_ORDER[@]}"; do
    [ "$s" = "main" ] && continue
    case " ${TO_START[*]} " in *" $s "*) ;; *) continue ;; esac
    stack_exists "$s" || { echo "[--] Stack $s: compose non trovato, salto."; continue; }
    echo "[..] Avvio stack $s..."
    if stack_compose "$s" up -d; then
        echo "[OK] Stack $s su."
    else
        echo "[ATTENZIONE] avvio stack $s fallito."
        FAILED+=("$s")
    fi
done

# 4. flag OFF
: > "$FLAG_FILE"
rm -f "$STATE_FILE"
echo "[OK] Flag di manutenzione (livello 1) svuotato."
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "[ATTENZIONE] Sito operativo, ma stack NON ripartiti: ${FAILED[*]}"
    exit 2
fi
echo "[OK] Sito tornato operativo, tutti gli stack ripristinati."
