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

require_env BACKUP_ROOT BACKUP_OFFSITE_METHOD

DB_KIND="${1:?uso: encrypt_and_offsite.sh <hapi|keycloak> <dump>}"
PLAINTEXT="${2:?uso: encrypt_and_offsite.sh <hapi|keycloak> <dump>}"

[ -f "$PLAINTEXT" ] || die "dump non trovato: $PLAINTEXT"
command -v age >/dev/null 2>&1 || die "age non installato (apt/brew install age)"

# Multi-recipient: BACKUP_AGE_RECIPIENTS (plurale, una o piu' chiavi pubbliche
# age separate da spazi/newline/virgole, righe vuote o che iniziano per #
# ignorate) — perdere UNA chiave privata non rende illeggibili i backup se ne
# esiste almeno un'altra custodita altrove. Retrocompatibilita': se solo la
# vecchia variabile singolare BACKUP_AGE_RECIPIENT e' definita, si comporta
# come prima (singolo recipient).
RECIPIENTS_RAW="${BACKUP_AGE_RECIPIENTS:-${BACKUP_AGE_RECIPIENT:-}}"
[ -n "$RECIPIENTS_RAW" ] || die "nessuna chiave age configurata: impostare BACKUP_AGE_RECIPIENTS (raccomandato, multi-custode) o BACKUP_AGE_RECIPIENT in backup/.env.backup"

AGE_RECIPIENT_ARGS=()
while IFS= read -r recipient; do
  recipient="${recipient//,/}"
  [ -z "$recipient" ] && continue
  case "$recipient" in
    \#*) continue ;;
    age1*) AGE_RECIPIENT_ARGS+=(-r "$recipient") ;;
    *) die "recipient age non valido (atteso formato age1...): $recipient" ;;
  esac
done < <(tr ' ,' '\n\n' <<<"$RECIPIENTS_RAW")

RECIPIENT_COUNT=$(( ${#AGE_RECIPIENT_ARGS[@]} / 2 ))
[ "$RECIPIENT_COUNT" -gt 0 ] || die "nessun recipient age valido trovato in BACKUP_AGE_RECIPIENTS/BACKUP_AGE_RECIPIENT"
log_info "cifratura con $RECIPIENT_COUNT recipient age configurati"
[ "$RECIPIENT_COUNT" -eq 1 ] && log_warn "un solo recipient age configurato: se questa chiave privata va persa, tutti i backup diventano illeggibili. Raccomandato BACKUP_AGE_RECIPIENTS con almeno 2 custodi indipendenti."

ARCHIVE_DIR="$BACKUP_ROOT/$DB_KIND/archive"
mkdir -p "$ARCHIVE_DIR"

BASENAME="$(basename "$PLAINTEXT")"
ENCRYPTED="$ARCHIVE_DIR/${BASENAME}.age"

log_info "cifratura: $PLAINTEXT -> $ENCRYPTED"
if ! age "${AGE_RECIPIENT_ARGS[@]}" -o "$ENCRYPTED.tmp" "$PLAINTEXT"; then
  rm -f "$ENCRYPTED.tmp"
  die "cifratura fallita: $PLAINTEXT"
fi
mv "$ENCRYPTED.tmp" "$ENCRYPTED"

# WORM best-effort per l'archivio audit (hash-chain tamper-evidence, floor
# retention 25 anni — vedi retention_cleanup.sh): chattr +i blocca rm/mv/write
# anche per root senza un chattr -i esplicito precedente. Non e' vera
# immutabilita' (root puo' sempre fare chattr -i), ma alza il costo di una
# cancellazione accidentale o di un bug in uno script rispetto a un file
# normale. Silenzioso se il filesystem non supporta gli attributi ext2
# (es. overlay/tmpfs in alcuni ambienti di test) - non deve bloccare il backup.
if [ "$DB_KIND" = "hapi-audit" ]; then
  if command -v chattr >/dev/null 2>&1 && chattr +i "$ENCRYPTED" 2>/dev/null; then
    log_info "immutabilita' locale (chattr +i) applicata: $ENCRYPTED"
  else
    log_warn "chattr +i non applicabile su $ENCRYPTED (filesystem non supportato o non root): archivio audit NON immutabile localmente"
  fi
fi

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
