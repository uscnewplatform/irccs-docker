#!/usr/bin/env bash
# Verifica periodica di integrita' sull'archivio cifrato (bitrot/corruzione
# silenziosa), non solo al momento della creazione del dump. `verify_restore.sh`
# gia' valida ogni dump appena creato (dentro backup_nightly.sh), ma un
# archivio di settimane/mesi fa non viene mai piu' toccato fino al giorno in
# cui serve davvero per un restore — se nel frattempo si e' corrotto silenzio-
# samente su disco (o sul remote), lo scopriresti solo nel disaster reale.
#
# Campiona 1 archivio per DB (hapi, keycloak, hapi-audit) ad ogni esecuzione,
# ruotando nel tempo su tutti i file presenti in $BACKUP_ROOT/<db>/archive/
# (stato in $BACKUP_ROOT/.verify-state/<db>.last-verified), lo decifra e lo
# passa a verify_restore.sh (stessa logica di restore-su-scratch gia' usata
# per i dump appena creati). Pensato per girare settimanalmente via
# irccs-backup-verify.timer, non ogni notte: un restore reale su container
# scratch per 3 DB non e' gratis, farlo ogni notte oltre al verify gia'
# integrato in backup_nightly.sh sarebbe ridondante e costoso.
#
# TRADE-OFF CHIAVE PRIVATA: per decifrare serve la chiave privata age, che
# per principio (vedi RESTORE_PLAYBOOK.md) NON dovrebbe mai risiedere
# sull'host di backup. Questo script richiede BACKUP_VERIFY_KEY_FILE (path
# alla chiave privata) reso disponibile su questo host solo per lo scopo
# della verifica periodica: e' un compromesso esplicito, non un default
# sicuro. Alternativa piu' sicura, se il rischio non e' accettabile: NON
# schedulare questo timer sullo stesso host di backup, eseguire invece questo
# script manualmente/periodicamente da un host separato che possiede la
# chiave (scaricando gli archivi da verificare via rclone/rsync), oppure
# lasciare la verifica periodica come procedura manuale trimestrale.
#
# Uso: verify_archive_integrity.sh
# Richiede: BACKUP_ROOT, BACKUP_VERIFY_KEY_FILE, docker CLI, age.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

# Rete di sicurezza: un comando non avvolto in if/||true che fallisce sotto
# `set -e` termina lo script senza passare da log_error — vedi lo stesso
# trap e spiegazione in run_backup_container.sh.
set -E
trap 'log_error "crash inatteso alla linea $LINENO (comando: $BASH_COMMAND)"' ERR

require_env BACKUP_ROOT BACKUP_VERIFY_KEY_FILE

[ -f "$BACKUP_VERIFY_KEY_FILE" ] || die "chiave privata age non trovata: $BACKUP_VERIFY_KEY_FILE (BACKUP_VERIFY_KEY_FILE)"
command -v age >/dev/null 2>&1 || die "age non installato"
command -v age-keygen >/dev/null 2>&1 || die "age-keygen non installato"

VERIFY_PUBKEY="$(age-keygen -y "$BACKUP_VERIFY_KEY_FILE" 2>/dev/null || true)"
[ -n "$VERIFY_PUBKEY" ] && log_info "chiave di verifica: $VERIFY_PUBKEY (annotare quale recipient in BACKUP_AGE_RECIPIENTS corrisponde a questa chiave, per audit)"

# Best-practice check: BACKUP_VERIFY_KEY_FILE dovrebbe essere una chiave
# DEDICATA solo a questa verifica (aggiunta in piu' ai custodi reali in
# BACKUP_AGE_RECIPIENTS, non in sostituzione) — se compromessa, basta
# ruotarla senza coinvolgere/revocare le chiavi dei custodi usate per il
# disaster recovery vero. Non possiamo dimostrare con certezza che sia
# "dedicata" (solo il numero di recipient totali e' verificabile da qui):
# se in BACKUP_AGE_RECIPIENTS ci sono meno di 3 chiavi totali (2+ custodi
# reali + 1 di verifica), e' probabile che questa chiave stia riusando lo
# slot di un custode reale invece di averne una propria — in quel caso
# compromettere questo host vanifica silenziosamente il vantaggio del
# multi-recipient (vedi encrypt_and_offsite.sh). Solo un warning, non blocca.
RECIPIENTS_RAW="${BACKUP_AGE_RECIPIENTS:-${BACKUP_AGE_RECIPIENT:-}}"
if [ -n "$RECIPIENTS_RAW" ]; then
  RECIPIENT_TOTAL=0
  while IFS= read -r recipient; do
    recipient="${recipient//,/}"
    [ -z "$recipient" ] && continue
    case "$recipient" in
      \#*) continue ;;
      age1*) RECIPIENT_TOTAL=$((RECIPIENT_TOTAL + 1)) ;;
    esac
  done < <(tr ' ,' '\n\n' <<<"$RECIPIENTS_RAW")

  if [ "$RECIPIENT_TOTAL" -lt 3 ]; then
    log_warn "BACKUP_AGE_RECIPIENTS ha solo $RECIPIENT_TOTAL recipient totali: BACKUP_VERIFY_KEY_FILE dovrebbe essere una chiave DEDICATA in aggiunta ad almeno 2 custodi reali (3+ recipient totali raccomandati). Se questa chiave coincide con quella di un custode, compromettere questo host vanifica il vantaggio del multi-recipient — generare una chiave separata solo per la verifica periodica."
  fi
else
  log_warn "BACKUP_AGE_RECIPIENTS/BACKUP_AGE_RECIPIENT non impostate: impossibile verificare se BACKUP_VERIFY_KEY_FILE e' una chiave dedicata"
fi

STATE_DIR="$BACKUP_ROOT/.verify-state"
mkdir -p "$STATE_DIR"

TMP_DECRYPTED=""
cleanup() {
  # L'ultimo comando eseguito in un trap EXIT sovrascrive l'exit code dello
  # script: senza il "|| true" finale, un $TMP_DECRYPTED vuoto (caso normale
  # a fine run) farebbe uscire lo script con exit 1 anche a successo pieno.
  [ -n "$TMP_DECRYPTED" ] && [ -f "$TMP_DECRYPTED" ] && rm -f "$TMP_DECRYPTED"
  true
}
trap cleanup EXIT

log_info "=== verifica periodica integrita' archivio avviata ==="

FAILED=0

for DB_KIND in hapi keycloak hapi-audit; do
  ARCHIVE_DIR="$BACKUP_ROOT/$DB_KIND/archive"
  STATE_FILE="$STATE_DIR/$DB_KIND.last-verified"

  if [ ! -d "$ARCHIVE_DIR" ]; then
    log_warn "archivio inesistente, salto: db=$DB_KIND dir=$ARCHIVE_DIR"
    continue
  fi

  # Ordine ascendente per nome file (contengono YYYY-MM-DD): garantisce un
  # giro deterministico e stabile nel tempo su tutti gli archivi presenti.
  mapfile -t FILES < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.dump.age' | sort)

  if [ "${#FILES[@]}" -eq 0 ]; then
    log_warn "nessun archivio da verificare: db=$DB_KIND dir=$ARCHIVE_DIR"
    continue
  fi

  # Riprende dal file successivo all'ultimo verificato con successo; se lo
  # stato manca, punta a un file ormai rimosso dalla retention, o siamo gia'
  # all'ultimo della lista, si riparte dal primo (giro completo nel tempo).
  PICK_INDEX=0
  if [ -f "$STATE_FILE" ]; then
    LAST="$(cat "$STATE_FILE")"
    for i in "${!FILES[@]}"; do
      if [ "$(basename "${FILES[$i]}")" = "$LAST" ]; then
        PICK_INDEX=$(( (i + 1) % ${#FILES[@]} ))
        break
      fi
    done
  fi

  TARGET="${FILES[$PICK_INDEX]}"
  log_info "campione selezionato: db=$DB_KIND archivio=$TARGET"

  TMP_DECRYPTED="$(mktemp "/tmp/verify-integrity-${DB_KIND}-XXXXXX.dump")"

  if ! age -d -i "$BACKUP_VERIFY_KEY_FILE" -o "$TMP_DECRYPTED" "$TARGET"; then
    log_error "decifratura fallita: db=$DB_KIND archivio=$TARGET (possibile corruzione o chiave errata)"
    FAILED=1
    rm -f "$TMP_DECRYPTED"
    TMP_DECRYPTED=""
    continue
  fi

  if "$SCRIPT_DIR/verify_restore.sh" "$DB_KIND" "$TMP_DECRYPTED"; then
    echo -n "$(basename "$TARGET")" > "$STATE_FILE"
    log_info "verifica periodica OK: db=$DB_KIND archivio=$TARGET"
  else
    log_error "verifica periodica FALLITA (restore/sanity): db=$DB_KIND archivio=$TARGET — stato non avanzato, verra' ritentato al prossimo giro"
    FAILED=1
  fi

  rm -f "$TMP_DECRYPTED"
  TMP_DECRYPTED=""
done

if [ "$FAILED" -ne 0 ]; then
  die "verifica periodica integrita' completata CON ERRORI: vedere log sopra"
fi

log_info "=== verifica periodica integrita' completata con successo ==="
