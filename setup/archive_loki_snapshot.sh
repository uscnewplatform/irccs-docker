#!/usr/bin/env bash
# Snapshot periodico del volume Loki (loki_data) prima che il compactor
# cancelli i chunk oltre retention_period (3 mesi, vedi monitoring-config/loki-config.yml).
#
# Non seleziona i soli log "in scadenza": copia l'intero storage ad ogni run,
# compresso. Gli archivi restano su disco finche' non vengono cancellati a
# mano (o con una procedura separata di pulizia). Pensato per girare da cron
# ~mensile, in modo che ogni finestra di retention abbia almeno uno snapshot
# prima che i dati corrispondenti vengano cancellati da Loki.
#
# Uso:
#   ./archive_loki_snapshot.sh [directory_archivio]
#
# Cron (mensile, il 1 del mese alle 03:00), esempio crontab:
#   0 3 1 * * /path/to/irccs-docker/setup/archive_loki_snapshot.sh /var/backup/loki-archive >> /var/log/loki-archive.log 2>&1

set -euo pipefail

ARCHIVE_DIR="${1:-/var/backup/loki-archive}"
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
echo "Archivi presenti in ${ARCHIVE_DIR}:"
ls -lh "$ARCHIVE_DIR"
