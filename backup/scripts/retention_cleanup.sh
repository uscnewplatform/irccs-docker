#!/usr/bin/env bash
# Retention GFS (Grandfather-Father-Son) sull'archivio cifrato locale (*.dump.age)
# E, se configurato un offsite, sulla stessa copia remota — altrimenti le copie
# offsite crescono illimitatamente (costo storage + dati che dovrebbero essere
# cancellabili, es. per diritto all'oblio GDPR, restanti per sempre sul remote).
# Politica: tiene sempre gli ultimi N giornalieri; tra i restanti, tiene il piu'
# recente di ogni settimana (fino a BACKUP_KEEP_WEEKLY) e il piu' recente di ogni
# mese (fino a BACKUP_KEEP_MONTHLY). Il resto viene cancellato.
#
# Retention offsite: applica lo STESSO set KEEP (calcolato sui nomi file, validi
# sia in locale che offsite visto che il basename e' identico) al remote.
# - rclone: supportata (rclone deletefile per ogni file fuori da KEEP).
# - rsync: non c'e' un modo pulito/sicuro per cancellare selettivamente un file
#   remoto per nome senza assumere accesso SSH diretto al target (formato
#   'user@host:/path' non sempre garantito, rischio di comandi errati su host
#   sbagliato) — non implementato: log_warn esplicito, pulizia offsite rsync
#   resta manuale.
# - none: nessuna azione (nessuna copia offsite da pulire).
# Un fallimento della pulizia offsite NON blocca lo script (retention locale
# gia' riuscita): viene loggato con log_warn, non e' motivo di alert critico
# come un fallimento di backup vero e proprio.
#
# Margine di sicurezza sulla cancellazione offsite (BACKUP_OFFSITE_DELETE_GRACE_DAYS):
# un file remoto fuori dal set KEEP non viene cancellato alla prima esecuzione
# in cui risulta fuori set, ma solo dopo essere rimasto "candidato" per almeno
# N giorni consecutivi. La retention locale e' gia' la copia "usa e getta"
# (ricostruibile da offsite); l'offsite e' l'ultima linea di difesa, quindi un
# bug nel calcolo del set KEEP (o una vecchia divergenza locale/remoto) ha una
# finestra di N giorni in cui un operatore puo' accorgersi del problema (alert
# Loki, controllo manuale) prima che la cancellazione remota diventi definitiva.
# Stato del "candidato" tracciato in file su disco (timestamp epoch della prima
# volta visto fuori set) sotto $BACKUP_ROOT/.retention-offsite-state/<db>/ —
# scelto un file per basename invece di un unico DB/indice perche' e' piu'
# semplice da ispezionare/pulire a mano e resiliente a corruzioni parziali
# (un file di stato rotto non impatta gli altri candidati).
#
# Uso: retention_cleanup.sh <hapi|keycloak|hapi-audit>

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

require_env BACKUP_ROOT BACKUP_KEEP_DAILY BACKUP_KEEP_WEEKLY BACKUP_KEEP_MONTHLY

DB_KIND="${1:?uso: retention_cleanup.sh <hapi|keycloak|hapi-audit>}"
ARCHIVE_DIR="$BACKUP_ROOT/$DB_KIND/archive"

[ -d "$ARCHIVE_DIR" ] || { log_warn "archivio inesistente, nulla da pulire: $ARCHIVE_DIR"; exit 0; }

# hapi-audit (AuditEvent store, hash-chain tamper-evidence) ha un floor di
# retention di 25 anni (org.quarkus.irccs.audit.retention.floor-years, vedi
# irccs-common) che la normale politica GFS daily/weekly/monthly (pensata per
# backup operativi, non per compliance) violerebbe: con KEEP_DAILY/WEEKLY/
# MONTHLY tipici (14gg + 8 settimane + 6 mesi) i dump audit piu' vecchi di
# ~8 mesi verrebbero cancellati, sia in locale che offsite. Il thinning GFS
# qui sotto NON si applica a hapi-audit: gli archivi audit si cancellano solo
# oltre BACKUP_AUDIT_RETENTION_YEARS (default 25), mai per conteggio.
if [ "$DB_KIND" = "hapi-audit" ]; then
  RETENTION_YEARS="${BACKUP_AUDIT_RETENTION_YEARS:-25}"
  CUTOFF_EPOCH="$(date -d "-${RETENTION_YEARS} years" +%s)"
  mapfile -t AUDIT_FILES < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.dump.age' | sort -r)
  REMOVED=0
  for f in "${AUDIT_FILES[@]}"; do
    stamp="$(basename "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)"
    [ -z "$stamp" ] && continue
    file_epoch="$(date -d "$stamp" +%s 2>/dev/null || true)"
    [ -z "$file_epoch" ] && continue
    if [ "$file_epoch" -lt "$CUTOFF_EPOCH" ]; then
      log_info "retention audit: rimozione $f (oltre floor ${RETENTION_YEARS} anni)"
      chattr -i "$f" 2>/dev/null || true
      rm -f "$f"
      REMOVED=$((REMOVED + 1))
    fi
  done
  log_info "retention audit completata: db=$DB_KIND floor=${RETENTION_YEARS}anni rimossi=$REMOVED totale=${#AUDIT_FILES[@]}"
  # Nessuna pulizia offsite per hapi-audit: stesso ragionamento, il file resta
  # sul remote finche' non supera il floor di retention (non gestito qui,
  # in pratica mai in automatico — decisione operatore dopo 25 anni).
  exit 0
fi

# File ordinati dal piu' recente al piu' vecchio (nome contiene YYYY-MM-DD).
mapfile -t ALL_FILES < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.dump.age' | sort -r)

KEEP=()
KEEP+=("${ALL_FILES[@]:0:$BACKUP_KEEP_DAILY}")
REST=("${ALL_FILES[@]:$BACKUP_KEEP_DAILY}")

pick_one_per_bucket() {
  local bucket_fmt="$1" limit="$2"
  shift 2
  # limit=0 (o negativo per errore di config) deve tenere zero file da questo
  # bucket — senza questo controllo il ciclo sotto aggiunge comunque 1 file
  # prima di verificare il limite (bug trovato testando il floor di sicurezza
  # qui sotto: con BACKUP_KEEP_WEEKLY/MONTHLY=0 venivano comunque tenuti file).
  [ "$limit" -le 0 ] && return 0
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
      # "if...then break; fi" (non "test && break"): sotto set -e, quando la
      # condizione e' falsa e il ciclo finisce senza piu' elementi, l'ultimo
      # comando eseguito nella funzione sarebbe il test fallito ([ ] -> exit
      # 1) invece di un "break" mai raggiunto — con "test && break" questo fa
      # terminare l'intero script (bug pre-esistente, si manifesta con meno
      # file del limite weekly/monthly, es. installazione fresca). La forma
      # if/then/fi restituisce sempre 0 quando la condizione e' falsa.
      if [ "$count" -ge "$limit" ]; then
        break
      fi
    fi
  done
}

pick_one_per_bucket "%G-W%V" "$BACKUP_KEEP_WEEKLY" "${REST[@]}"
pick_one_per_bucket "%Y-%m" "$BACKUP_KEEP_MONTHLY" "${REST[@]}"

# Floor di sicurezza: se c'erano archivi ma il set da tenere risulta vuoto,
# e' quasi certamente un bug (nel calcolo sopra, o BACKUP_KEEP_DAILY=0 per
# misconfigurazione) — non e' uno stato legittimo in condizioni normali.
# Senza questo controllo lo script cancellerebbe silenziosamente TUTTO
# l'archivio (locale e, con retention offsite, anche remoto dopo la grazia)
# con solo un log_info, nessun alert critico. Meglio fermarsi ed alertare.
if [ "${#ALL_FILES[@]}" -gt 0 ] && [ "${#KEEP[@]}" -eq 0 ]; then
  die "retention: set da tenere vuoto con ${#ALL_FILES[@]} archivi presenti (db=$DB_KIND) — sembra un bug o BACKUP_KEEP_DAILY/WEEKLY/MONTHLY misconfigurati, nessun file cancellato"
fi

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

# --- retention offsite ------------------------------------------------------
# Stesso set KEEP (per basename, identico in locale e offsite) applicato al
# remote configurato. Best-effort: errori qui non fanno fallire lo script.
KEEP_BASENAMES=()
for k in "${KEEP[@]}"; do
  KEEP_BASENAMES+=("$(basename "$k")")
done

is_kept_basename() {
  local name="$1" b
  for b in "${KEEP_BASENAMES[@]}"; do
    [ "$name" = "$b" ] && return 0
  done
  return 1
}

GRACE_DAYS="${BACKUP_OFFSITE_DELETE_GRACE_DAYS:-3}"
STATE_DIR="$BACKUP_ROOT/.retention-offsite-state/$DB_KIND"

# Ritorna 0 (elimina ora) se il candidato ha superato la grazia, 1 altrimenti
# (crea/lascia lo stato "candidato" e non elimina). Best-effort: un errore
# nel leggere/scrivere lo stato non deve mai bloccare la pipeline — in quel
# caso si sceglie di NON eliminare (fail-safe verso "tieni troppo", non verso
# "cancella troppo").
past_grace() {
  local name="$1"
  local state_file="$STATE_DIR/$name.first-candidate"
  local now first age_days
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log_warn "retention offsite: impossibile creare $STATE_DIR, salto grazia per $name (non elimino)"
    return 1
  fi
  now="$(date +%s)"
  if [ -f "$state_file" ]; then
    first="$(cat "$state_file" 2>/dev/null || true)"
    if ! [[ "$first" =~ ^[0-9]+$ ]]; then
      log_warn "retention offsite: stato corrotto per $name, riparto da ora (non elimino)"
      echo "$now" > "$state_file" 2>/dev/null || true
      return 1
    fi
    age_days=$(( (now - first) / 86400 ))
    if [ "$age_days" -ge "$GRACE_DAYS" ]; then
      rm -f "$state_file" 2>/dev/null || true
      return 0
    fi
    log_info "retention offsite: candidato $name ancora in grazia (${age_days}gg/${GRACE_DAYS}gg, db=$DB_KIND)"
    return 1
  fi
  log_info "retention offsite: $name diventa candidato a cancellazione (grazia ${GRACE_DAYS}gg, db=$DB_KIND)"
  echo "$now" > "$state_file" 2>/dev/null || true
  return 1
}

# File rientrato nel set KEEP prima di scadere la grazia: resetta lo stato,
# non deve accumularsi silenziosamente in attesa di una futura uscita dal set.
reset_candidate_state() {
  local name="$1"
  local state_file="$STATE_DIR/$name.first-candidate"
  [ -f "$state_file" ] && rm -f "$state_file" 2>/dev/null
  return 0
}

case "${BACKUP_OFFSITE_METHOD:-none}" in
  none)
    : # nessuna copia offsite da pulire
    ;;
  rclone)
    if ! command -v rclone >/dev/null 2>&1; then
      log_warn "retention offsite saltata: rclone non installato (db=$DB_KIND)"
    elif [ -z "${BACKUP_OFFSITE_TARGET:-}" ]; then
      log_warn "retention offsite saltata: BACKUP_OFFSITE_TARGET non impostato (db=$DB_KIND)"
    else
      OFFSITE_DIR="$BACKUP_OFFSITE_TARGET/$DB_KIND/"
      if REMOTE_FILES="$(rclone lsf "$OFFSITE_DIR" 2>/dev/null)"; then
        REMOVED_OFFSITE=0
        while IFS= read -r remote_name; do
          [ -z "$remote_name" ] && continue
          case "$remote_name" in
            *.dump.age) ;;
            *) continue ;;
          esac
          if is_kept_basename "$remote_name"; then
            reset_candidate_state "$remote_name"
            continue
          fi
          if past_grace "$remote_name"; then
            log_info "retention offsite: rimozione $OFFSITE_DIR$remote_name (grazia scaduta)"
            if rclone deletefile "$OFFSITE_DIR$remote_name" 2>/dev/null; then
              REMOVED_OFFSITE=$((REMOVED_OFFSITE + 1))
            else
              log_warn "retention offsite: rimozione fallita per $OFFSITE_DIR$remote_name (db=$DB_KIND)"
            fi
          fi
        done <<< "$REMOTE_FILES"
        log_info "retention offsite completata: db=$DB_KIND rimossi=$REMOVED_OFFSITE"
      else
        log_warn "retention offsite saltata: impossibile listare $OFFSITE_DIR (db=$DB_KIND)"
      fi
    fi
    ;;
  rsync)
    log_warn "retention offsite non supportata per rsync (db=$DB_KIND): le copie remote in $BACKUP_OFFSITE_TARGET/$DB_KIND/ vanno pulite manualmente secondo la stessa policy GFS"
    ;;
  *)
    log_warn "BACKUP_OFFSITE_METHOD sconosciuto per retention offsite: ${BACKUP_OFFSITE_METHOD:-} (db=$DB_KIND)"
    ;;
esac
