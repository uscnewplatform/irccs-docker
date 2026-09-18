#!/usr/bin/env bash
# Installa (idempotente) la crontab per lo snapshot mensile di Loki, invece di lasciare
# "aggiungere questa riga a mano" come unica istruzione (README precedente) - verificato
# durante l'audit trail Fase 3 che nessuno l'aveva mai effettivamente eseguita in
# nessun ambiente. Rieseguibile senza duplicare la riga in crontab.
#
# Uso:
#   ./install_loki_archive_cron.sh [directory_archivio] [mesi_da_conservare]
#
# Di default schedula il giorno 1 di ogni mese alle 03:00, log in
# /var/log/loki-archive.log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_SCRIPT="${SCRIPT_DIR}/archive_loki_snapshot.sh"
ARCHIVE_DIR="${1:-/var/backup/loki-archive}"
KEEP_MONTHS="${2:-12}"

if [ ! -x "$ARCHIVE_SCRIPT" ]; then
    echo "ERRORE: $ARCHIVE_SCRIPT non trovato o non eseguibile." >&2
    exit 1
fi

CRON_LINE="0 3 1 * * ${ARCHIVE_SCRIPT} ${ARCHIVE_DIR} ${KEEP_MONTHS} >> /var/log/loki-archive.log 2>&1"
CRON_MARKER="# irccs-docker: archiviazione mensile Loki (gestito da install_loki_archive_cron.sh)"

EXISTING_CRONTAB="$(crontab -l 2>/dev/null || true)"

if echo "$EXISTING_CRONTAB" | grep -qF "$ARCHIVE_SCRIPT"; then
    echo "Voce crontab per $ARCHIVE_SCRIPT gia' presente - nessuna modifica."
    echo "Riga attuale:"
    echo "$EXISTING_CRONTAB" | grep -F "$ARCHIVE_SCRIPT"
    exit 0
fi

{
    echo "$EXISTING_CRONTAB"
    echo "$CRON_MARKER"
    echo "$CRON_LINE"
} | crontab -

echo "Crontab installata:"
echo "$CRON_LINE"
echo ""
echo "Verifica con: crontab -l"
