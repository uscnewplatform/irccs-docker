#!/usr/bin/env bash
# Ri-cifra TUTTO l'archivio esistente (locale, e offsite se configurato) da
# una vecchia chiave age a un nuovo set di recipient. Serve per revoca/
# rotazione: rimuovere una chiave da BACKUP_AGE_RECIPIENTS in .env.backup
# protegge solo i backup FUTURI — age non supporta revoca retroattiva, gli
# archivi gia' cifrati restano decifrabili per sempre con la vecchia chiave
# finche' qualcuno non li ri-cifra esplicitamente. Uso tipico: un custode
# lascia l'organizzazione, o si sospetta una chiave compromessa.
#
# Operazione potenzialmente pericolosa (sovrascrive l'intero archivio): per
# ogni file, decifra con la vecchia chiave, ri-cifra con il set CORRENTE di
# BACKUP_AGE_RECIPIENTS (gia' aggiornato in .env.backup PRIMA di lanciare
# questo script), verifica il round-trip (se BACKUP_VERIFY_KEY_FILE e'
# configurata ed e' tra i nuovi recipient) prima di sovrascrivere l'originale.
# Un file che fallisce in QUALUNQUE step (decifratura/cifratura/verifica)
# NON viene toccato: resta con la vecchia cifratura, loggato come errore,
# lo script continua sugli altri file (non si ferma al primo fallimento —
# meglio ri-cifrare il possibile ora e ritentare i falliti a parte).
#
# Uso:
#   reencrypt_archive.sh <path/alla/vecchia/chiave/privata> [--yes-i-am-sure=<hostname>]
#
# Interattivo: chiede di digitare l'hostname corrente per confermare (stesso
# pattern di restore_db.sh). Non interattivo: --yes-i-am-sure=<hostname>.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

set -E
trap 'log_error "crash inatteso alla linea $LINENO (comando: $BASH_COMMAND)"' ERR

require_env BACKUP_ROOT

OLD_KEY_FILE="${1:?uso: reencrypt_archive.sh <path/vecchia-chiave-privata> [--yes-i-am-sure=<hostname>]}"
CONFIRM_ARG="${2:-}"

[ -f "$OLD_KEY_FILE" ] || die "chiave privata non trovata: $OLD_KEY_FILE"
command -v age >/dev/null 2>&1 || die "age non installato"
command -v age-keygen >/dev/null 2>&1 || die "age-keygen non installato"
command -v shred >/dev/null 2>&1 || die "shred non installato"

OLD_PUBKEY="$(age-keygen -y "$OLD_KEY_FILE" 2>/dev/null)" || die "impossibile derivare la chiave pubblica da $OLD_KEY_FILE (file corrotto o non e' una chiave age valida)"

# Stesso parsing multi-recipient di encrypt_and_offsite.sh: il set NUOVO
# verso cui ri-cifrare e' quello attualmente in BACKUP_AGE_RECIPIENTS (deve
# essere gia' stato aggiornato in .env.backup PRIMA di lanciare questo
# script, escludendo la chiave da revocare).
RECIPIENTS_RAW="${BACKUP_AGE_RECIPIENTS:-${BACKUP_AGE_RECIPIENT:-}}"
[ -n "$RECIPIENTS_RAW" ] || die "nessuna chiave age configurata in BACKUP_AGE_RECIPIENTS/BACKUP_AGE_RECIPIENT (il nuovo set verso cui ri-cifrare)"

AGE_RECIPIENT_ARGS=()
NEW_RECIPIENTS_LIST=()
while IFS= read -r recipient; do
  recipient="${recipient//,/}"
  [ -z "$recipient" ] && continue
  case "$recipient" in
    \#*) continue ;;
    age1*) AGE_RECIPIENT_ARGS+=(-r "$recipient"); NEW_RECIPIENTS_LIST+=("$recipient") ;;
    *) die "recipient age non valido (atteso formato age1...): $recipient" ;;
  esac
done < <(tr ' ,' '\n\n' <<<"$RECIPIENTS_RAW")

[ "${#NEW_RECIPIENTS_LIST[@]}" -gt 0 ] || die "nessun recipient age valido trovato in BACKUP_AGE_RECIPIENTS/BACKUP_AGE_RECIPIENT"

for r in "${NEW_RECIPIENTS_LIST[@]}"; do
  if [ "$r" = "$OLD_PUBKEY" ]; then
    die "la vecchia chiave ($OLD_PUBKEY) e' ANCORA presente nel nuovo set BACKUP_AGE_RECIPIENTS — rimuoverla da .env.backup prima di ri-cifrare, altrimenti l'operazione non ha alcun effetto di revoca"
  fi
done

# Verifica round-trip opzionale ma fortemente raccomandata: se disponibile
# una chiave privata tra i NUOVI recipient (tipicamente BACKUP_VERIFY_KEY_FILE,
# vedi verify_archive_integrity.sh), la usiamo per confermare che ogni file
# ri-cifrato sia davvero decifrabile con il nuovo set prima di sovrascrivere
# l'originale — altrimenti un bug in age o nei recipient sbagliati
# distruggerebbe silenziosamente l'accesso al backup.
VERIFY_ROUNDTRIP=false
if [ -n "${BACKUP_VERIFY_KEY_FILE:-}" ] && [ -f "${BACKUP_VERIFY_KEY_FILE:-}" ]; then
  VERIFY_PUBKEY="$(age-keygen -y "$BACKUP_VERIFY_KEY_FILE" 2>/dev/null || true)"
  for r in "${NEW_RECIPIENTS_LIST[@]}"; do
    [ "$r" = "$VERIFY_PUBKEY" ] && VERIFY_ROUNDTRIP=true && break
  done
fi
if [ "$VERIFY_ROUNDTRIP" = true ]; then
  log_info "verifica round-trip attiva (BACKUP_VERIFY_KEY_FILE e' tra i nuovi recipient)"
else
  log_warn "nessuna chiave privata disponibile tra i nuovi recipient per verificare il round-trip — ogni file ri-cifrato NON verra' confermato decifrabile prima di sovrascrivere l'originale (rischio maggiore, procedere con cautela)"
fi

# Enumera tutti gli archivi cifrati, locale, sui tre DB.
FILES=()
for db in hapi keycloak hapi-audit; do
  archive_dir="$BACKUP_ROOT/$db/archive"
  [ -d "$archive_dir" ] || continue
  while IFS= read -r -d '' f; do
    FILES+=("$f")
  done < <(find "$archive_dir" -maxdepth 1 -type f -name '*.dump.age' -print0)
done

[ "${#FILES[@]}" -gt 0 ] || die "nessun archivio *.dump.age trovato sotto $BACKUP_ROOT/{hapi,keycloak,hapi-audit}/archive/ — nulla da ri-cifrare"

CURRENT_HOST="$(hostname)"

echo "=== reencrypt_archive.sh: ri-cifratura completa dell'archivio ===" >&2
echo "hostname corrente     : $CURRENT_HOST" >&2
echo "chiave da revocare     : $OLD_PUBKEY" >&2
echo "nuovi recipient (${#NEW_RECIPIENTS_LIST[@]})    : ${NEW_RECIPIENTS_LIST[*]}" >&2
echo "file da ri-cifrare      : ${#FILES[@]}" >&2
echo "verifica round-trip     : $VERIFY_ROUNDTRIP" >&2
echo "offsite (rclone)        : ${BACKUP_OFFSITE_METHOD:-none}" >&2
echo "===================================================================" >&2

CONFIRMED=false
if [[ "$CONFIRM_ARG" == --yes-i-am-sure=* ]]; then
  PROVIDED_HOST="${CONFIRM_ARG#--yes-i-am-sure=}"
  if [ "$PROVIDED_HOST" = "$CURRENT_HOST" ]; then
    CONFIRMED=true
  else
    die "conferma rifiutata: --yes-i-am-sure=\"$PROVIDED_HOST\" non corrisponde all'hostname reale \"$CURRENT_HOST\""
  fi
elif [ -n "$CONFIRM_ARG" ]; then
  die "argomento non riconosciuto: $CONFIRM_ARG (atteso --yes-i-am-sure=<hostname>)"
else
  if [ ! -t 0 ]; then
    die "nessun terminale interattivo e nessun --yes-i-am-sure=<hostname>: conferma impossibile, operazione annullata"
  fi
  read -r -p "Digita l'hostname corrente (\"$CURRENT_HOST\") per confermare la ri-cifratura di ${#FILES[@]} file: " TYPED_HOST
  if [ "$TYPED_HOST" = "$CURRENT_HOST" ]; then
    CONFIRMED=true
  else
    die "conferma rifiutata: hostname digitato non corrisponde, operazione annullata (nessun file toccato)"
  fi
fi
[ "$CONFIRMED" = true ] || die "conferma non ottenuta, operazione annullata"

log_info "conferma OK, avvio ri-cifratura di ${#FILES[@]} file"

OK_COUNT=0
FAIL_COUNT=0

for f in "${FILES[@]}"; do
  db_kind="$(basename "$(dirname "$(dirname "$f")")")"
  TMP_PLAIN="$(mktemp "${f}.plain.XXXXXX")"
  TMP_NEW="$(mktemp "${f}.new.XXXXXX")"

  cleanup_tmp() {
    [ -f "$TMP_PLAIN" ] && shred -u "$TMP_PLAIN" 2>/dev/null
    [ -f "$TMP_NEW" ] && rm -f "$TMP_NEW" 2>/dev/null
  }

  if ! age -d -i "$OLD_KEY_FILE" -o "$TMP_PLAIN" "$f" 2>/dev/null; then
    log_error "decifratura fallita con la vecchia chiave, file NON toccato: $f"
    cleanup_tmp
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  if ! age "${AGE_RECIPIENT_ARGS[@]}" -o "$TMP_NEW" "$TMP_PLAIN" 2>/dev/null; then
    log_error "ri-cifratura fallita, file NON toccato: $f"
    cleanup_tmp
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  if [ "$VERIFY_ROUNDTRIP" = true ]; then
    TMP_CHECK="$(mktemp "${f}.check.XXXXXX")"
    if ! age -d -i "$BACKUP_VERIFY_KEY_FILE" -o "$TMP_CHECK" "$TMP_NEW" 2>/dev/null || ! cmp -s "$TMP_PLAIN" "$TMP_CHECK"; then
      log_error "verifica round-trip fallita (il nuovo file cifrato non decifra allo stesso contenuto), file NON toccato: $f"
      rm -f "$TMP_CHECK"
      cleanup_tmp
      FAIL_COUNT=$((FAIL_COUNT + 1))
      continue
    fi
    rm -f "$TMP_CHECK"
  fi

  mv "$TMP_NEW" "$f"
  shred -u "$TMP_PLAIN" 2>/dev/null || rm -f "$TMP_PLAIN"
  log_info "ri-cifrato OK: $f"
  OK_COUNT=$((OK_COUNT + 1))

  # Offsite: sovrascrive la copia remota con la versione ri-cifrata. Best-
  # effort (come il resto della pulizia offsite) - un fallimento qui non
  # blocca gli altri file, ma lascia una divergenza locale/offsite da
  # correggere a mano (segnalata chiaramente nel log).
  if [ "${BACKUP_OFFSITE_METHOD:-none}" = "rclone" ] && [ -n "${BACKUP_OFFSITE_TARGET:-}" ]; then
    if command -v rclone >/dev/null 2>&1; then
      if rclone copy "$f" "$BACKUP_OFFSITE_TARGET/$db_kind/" 2>/dev/null; then
        log_info "offsite aggiornato: $f -> $BACKUP_OFFSITE_TARGET/$db_kind/"
      else
        log_warn "offsite NON aggiornato (rclone copy fallito), copia remota resta con la vecchia cifratura: $f"
      fi
    fi
  fi
done

log_info "ri-cifratura completata: ok=$OK_COUNT falliti=$FAIL_COUNT su ${#FILES[@]} file totali"

if [ "$FAIL_COUNT" -gt 0 ]; then
  die "ri-cifratura completata CON ERRORI: $FAIL_COUNT file non toccati (restano cifrati con la vecchia chiave), vedere log sopra"
fi

log_info "=== ri-cifratura completata con successo: tutti i file ora cifrati SOLO verso i nuovi recipient ==="
log_warn "la vecchia chiave privata ($OLD_PUBKEY) puo' essere considerata revocata per l'archivio SOLO ora — se era anche una delle chiavi custode in uso altrove, coordinare la sua distruzione definitiva"
