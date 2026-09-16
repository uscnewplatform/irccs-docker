#!/usr/bin/env bash
# Snapshot periodico del volume Loki (loki_data) prima che il compactor
# cancelli i chunk oltre retention_period (3 mesi, vedi monitoring-config/loki-config.yml).
#
# Non seleziona i soli log "in scadenza": copia l'intero storage ad ogni run,
# compresso. Pensato per girare da cron ~mensile (vedi setup/install_loki_archive_cron.sh
# per l'installazione automatica, non piu' a mano), in modo che ogni finestra di
# retention abbia almeno uno snapshot prima che i dati corrispondenti vengano cancellati
# da Loki.
#
# Uso:
#   ./archive_loki_snapshot.sh [directory_archivio] [mesi_da_conservare]
#
# mesi_da_conservare (default 12): gli archivi piu' vecchi di questa soglia vengono
# cancellati automaticamente ad ogni run - prima non c'era alcuna pulizia, lo spazio
# disco cresceva senza limite (vedi audit trail report, Fase 3).

set -euo pipefail

ARCHIVE_DIR="${1:-/var/backup/loki-archive}"
KEEP_MONTHS="${2:-12}"
VOLUME_NAME="irccs-docker_loki_data"
STAMP="$(date +%Y-%m-%d_%H%M)"
OUT_FILE="${ARCHIVE_DIR}/loki-snapshot-${STAMP}.tar.gz"

mkdir -p "$ARCHIVE_DIR"

if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    echo "ERRORE: volume Docker '$VOLUME_NAME' non trovato. Verifica il nome con: docker volume ls | grep loki" >&2
    exit 1
fi

echo "[$(date -Is)] Snapshot volume '$VOLUME_NAME' -> $OUT_FILE"

docker run --rm \
    -v "${VOLUME_NAME}:/loki:ro" \
    -v "${ARCHIVE_DIR}:/backup" \
    alpine:latest \
    tar czf "/backup/$(basename "$OUT_FILE")" -C / loki

echo "[$(date -Is)] Fatto: $(du -h "$OUT_FILE" | cut -f1)"

DELETED=$(find "$ARCHIVE_DIR" -maxdepth 1 -name 'loki-snapshot-*.tar.gz' -mtime "+$((KEEP_MONTHS * 30))" -print -delete)
if [ -n "$DELETED" ]; then
    echo "[$(date -Is)] Rimossi archivi piu' vecchi di ${KEEP_MONTHS} mesi:"
    echo "$DELETED"
fi

echo "Archivi presenti in ${ARCHIVE_DIR}:"
ls -lh "$ARCHIVE_DIR"
