#!/usr/bin/env bash
# Cifra (age) un dump verificato, lo sposta nell'archivio locale (quello soggetto
# a retention GFS) e lo replica offsite. Il plaintext di staging viene rimosso
# solo dopo cifratura riuscita.
#
# Uso: encrypt_and_offsite.sh <hapi|keycloak> <path/al/dump/plaintext>

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

require_env BACKUP_ROOT BACKUP_AGE_RECIPIENT BACKUP_OFFSITE_METHOD

DB_KIND="${1:?uso: encrypt_and_offsite.sh <hapi|keycloak> <dump>}"
PLAINTEXT="${2:?uso: encrypt_and_offsite.sh <hapi|keycloak> <dump>}"

[ -f "$PLAINTEXT" ] || die "dump non trovato: $PLAINTEXT"
command -v age >/dev/null 2>&1 || die "age non installato (apt/brew install age)"

ARCHIVE_DIR="$BACKUP_ROOT/$DB_KIND/archive"
mkdir -p "$ARCHIVE_DIR"

BASENAME="$(basename "$PLAINTEXT")"
ENCRYPTED="$ARCHIVE_DIR/${BASENAME}.age"

log_info "cifratura: $PLAINTEXT -> $ENCRYPTED"
if ! age -r "$BACKUP_AGE_RECIPIENT" -o "$ENCRYPTED.tmp" "$PLAINTEXT"; then
  rm -f "$ENCRYPTED.tmp"
  die "cifratura fallita: $PLAINTEXT"
fi
mv "$ENCRYPTED.tmp" "$ENCRYPTED"

# Plaintext rimosso solo dopo cifratura riuscita: non deve mai restare su disco.
rm -f "$PLAINTEXT"
log_info "plaintext staging rimosso: $PLAINTEXT"

case "$BACKUP_OFFSITE_METHOD" in
  none)
    log_warn "BACKUP_OFFSITE_METHOD=none: $ENCRYPTED resta solo in locale (nessuna copia offsite)"
    ;;
  rclone)
    require_env BACKUP_OFFSITE_TARGET
    command -v rclone >/dev/null 2>&1 || die "rclone non installato"
    if ! rclone copy "$ENCRYPTED" "$BACKUP_OFFSITE_TARGET/$DB_KIND/"; then
      die "rclone copy fallito: $ENCRYPTED -> $BACKUP_OFFSITE_TARGET/$DB_KIND/"
    fi
    log_info "offsite rclone OK: $ENCRYPTED -> $BACKUP_OFFSITE_TARGET/$DB_KIND/"
    ;;
  rsync)
    require_env BACKUP_OFFSITE_TARGET
    command -v rsync >/dev/null 2>&1 || die "rsync non installato"
    if ! rsync -av "$ENCRYPTED" "$BACKUP_OFFSITE_TARGET/$DB_KIND/"; then
      die "rsync fallito: $ENCRYPTED -> $BACKUP_OFFSITE_TARGET/$DB_KIND/"
    fi
    log_info "offsite rsync OK: $ENCRYPTED -> $BACKUP_OFFSITE_TARGET/$DB_KIND/"
    ;;
  *)
    die "BACKUP_OFFSITE_METHOD sconosciuto: $BACKUP_OFFSITE_METHOD (atteso rclone|rsync|none)"
    ;;
esac

echo "$ENCRYPTED"
