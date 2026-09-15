#!/usr/bin/env bash
# Retention GFS (Grandfather-Father-Son) sull'archivio cifrato locale (*.dump.age).
# Politica: tiene sempre gli ultimi N giornalieri; tra i restanti, tiene il piu'
# recente di ogni settimana (fino a BACKUP_KEEP_WEEKLY) e il piu' recente di ogni
# mese (fino a BACKUP_KEEP_MONTHLY). Il resto viene cancellato.
#
# Uso: retention_cleanup.sh <hapi|keycloak>

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

require_env BACKUP_ROOT BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY BACKUP_KEEP_MONTHLY

DB_KIND="${1:?uso: retention_cleanup.sh <hapi|keycloak>}"
ARCHIVE_DIR="$BACKUP_ROOT/$DB_KIND/archive"

[ -d "$ARCHIVE_DIR" ] || { log_warn "archivio inesistente, nulla da pulire: $ARCHIVE_DIR"; exit 0; }

# File ordinati dal piu' recente al piu' vecchio (nome contiene YYYY-MM-DD).
mapfile -t ALL_FILES < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.dump.age' | sort -r)

KEEP=()
KEEP+=("${ALL_FILES[@]:0:$BACKUP_KEEP_DAILY}")
REST=("${ALL_FILES[@]:$BACKUP_KEEP_DAILY}")

pick_one_per_bucket() {
  local bucket_fmt="$1" limit="$2"
  shift 2
  local -A seen=()
  local count=0
  local f bucket
  for f in "$@"; do
    bucket="$(date -d "$(basename "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')" +"$bucket_fmt" 2>/dev/null || true)"
    [ -z "$bucket" ] && continue
    if [ -z "${seen[$bucket]:-}" ]; then
      seen[$bucket]=1
      KEEP+=("$f")
      count=$((count + 1))
      [ "$count" -ge "$limit" ] && break
    fi
  done
}

pick_one_per_bucket "%G-W%V" "$BACKUP_KEEP_WEEKLY" "${REST[@]}"
pick_one_per_bucket "%Y-%m" "$BACKUP_KEEP_MONTHLY" "${REST[@]}"

for f in "${ALL_FILES[@]}"; do
  keep=false
  for k in "${KEEP[@]}"; do
    [ "$f" = "$k" ] && keep=true && break
  done
  if [ "$keep" = false ]; then
    log_info "retention: rimozione $f"
    rm -f "$f"
  fi
done

log_info "retention completata: db=$DB_KIND totale_tenuti=${#KEEP[@]}"
