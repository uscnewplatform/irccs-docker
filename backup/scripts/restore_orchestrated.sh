#!/usr/bin/env bash
# Orchestratore della parte MECCANICA del restore (stop servizi -> decifra ->
# restore_db.sh per ogni DB -> riavvio ordinato), seguendo RESTORE_PLAYBOOK.md
# §2-4,6-7. Automatizza solo i passi senza ambiguita': la SCELTA del dump da
# usare (playbook §1 - critica in scenario ransomware/tampering, richiede
# giudizio umano su QUALE generazione restorare) e la verifica funzionale
# finale (§8) restano fuori da questo script, apposta - vedi discussione nel
# README "perche' non un unico mega-script".
#
# Uso:
#   restore_orchestrated.sh --date=YYYY-MM-DD --key=<path/chiave/privata/age> \
#     [--db=hapi,keycloak,hapi-audit] [--yes-i-am-sure=<hostname>] [--keep-plaintext]
#
# --db default: hapi,keycloak (hapi-audit va richiesto esplicitamente: dopo un
# suo restore la hash-chain riparte dal tail nel dump, vedi playbook §4).
#
# Interattivo per la conferma finale (hostname), a meno di --yes-i-am-sure.
# Fa SEMPRE il preflight dipendenze (lib_preflight.sh) prima di toccare
# qualunque container: se manca qualcosa (age, pg_restore di major giusta,
# docker compose...) si ferma con la lista di cosa installare, invece di
# fallire a meta' con un container gia' droppato.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
STACK_DIR="$(dirname "$BACKUP_DIR")"
# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"
# shellcheck source=./lib_preflight.sh
source "$SCRIPT_DIR/lib_preflight.sh"

set -E
trap 'log_error "crash inatteso alla linea $LINENO (comando: $BASH_COMMAND)"' ERR

DATE=""
KEY_FILE=""
DB_LIST="hapi,keycloak"
CONFIRM_ARG=""
KEEP_PLAINTEXT=false

for arg in "$@"; do
  case "$arg" in
    --date=*) DATE="${arg#--date=}" ;;
    --key=*) KEY_FILE="${arg#--key=}" ;;
    --db=*) DB_LIST="${arg#--db=}" ;;
    --yes-i-am-sure=*) CONFIRM_ARG="$arg" ;;
    --keep-plaintext) KEEP_PLAINTEXT=true ;;
    *) die "argomento non riconosciuto: $arg (attesi --date=, --key=, --db=, --yes-i-am-sure=, --keep-plaintext)" ;;
  esac
done

[ -n "$DATE" ] || die "uso: restore_orchestrated.sh --date=YYYY-MM-DD --key=<chiave-privata> [--db=hapi,keycloak,hapi-audit] [--yes-i-am-sure=<hostname>]"
[ -n "$KEY_FILE" ] || die "manca --key=<path/alla/chiave/privata/age> (NON deve risiedere stabilmente su questo host, vedi RESTORE_PLAYBOOK.md §0)"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--date deve essere in formato YYYY-MM-DD, ricevuto: $DATE"

IFS=',' read -ra DBS <<< "$DB_LIST"
for db in "${DBS[@]}"; do
  case "$db" in
    hapi|keycloak|hapi-audit) ;;
    *) die "db sconosciuto in --db: $db (attesi hapi|keycloak|hapi-audit)" ;;
  esac
done

# --- preflight -------------------------------------------------------------
preflight_restore "$STACK_DIR" || die "preflight fallito: risolvere le dipendenze mancanti sopra prima di riprovare"

[ -f "$KEY_FILE" ] || die "chiave privata non trovata: $KEY_FILE"
command -v age >/dev/null 2>&1 || die "age non installato"

set -a
# shellcheck source=/dev/null
[ -f "$BACKUP_DIR/.env.backup" ] && source "$BACKUP_DIR/.env.backup"
set +a
BACKUP_ROOT="${BACKUP_ROOT:-/opt/irccs-backup}"

# --- individua gli archivi cifrati per la data richiesta --------------------
declare -A ARCHIVE_FILE
for db in "${DBS[@]}"; do
  f="$BACKUP_ROOT/$db/archive/${db}_${DATE}.dump.age"
  [ -f "$f" ] || die "archivio non trovato per db=$db data=$DATE: $f (vedi playbook §1 per elencare le date disponibili)"
  ARCHIVE_FILE["$db"]="$f"
done

log_info "=== restore_orchestrated.sh: piano ==="
log_info "data selezionata : $DATE"
log_info "DB da restorare   : ${DBS[*]}"
for db in "${DBS[@]}"; do
  log_info "  - $db -> ${ARCHIVE_FILE[$db]}"
done

CURRENT_HOST="$(hostname)"
CONFIRMED=false
if [[ "$CONFIRM_ARG" == --yes-i-am-sure=* ]]; then
  PROVIDED_HOST="${CONFIRM_ARG#--yes-i-am-sure=}"
  [ "$PROVIDED_HOST" = "$CURRENT_HOST" ] && CONFIRMED=true \
    || die "conferma rifiutata: --yes-i-am-sure=\"$PROVIDED_HOST\" non corrisponde all'hostname reale \"$CURRENT_HOST\""
else
  if [ ! -t 0 ]; then
    die "nessun terminale interattivo e nessun --yes-i-am-sure=<hostname>: conferma impossibile, operazione annullata"
  fi
  echo "=== OPERAZIONE DISTRUTTIVA: fermera' i servizi applicativi e sostituira' i DB (${DBS[*]}) con la data $DATE ===" >&2
  read -r -p "Digita l'hostname corrente (\"$CURRENT_HOST\") per confermare: " TYPED_HOST
  [ "$TYPED_HOST" = "$CURRENT_HOST" ] && CONFIRMED=true \
    || die "conferma rifiutata: hostname digitato non corrisponde, operazione annullata (nessuna modifica eseguita)"
fi
[ "$CONFIRMED" = true ] || die "conferma non ottenuta"

# --- §2: ferma i servizi applicativi -----------------------------------
_pf_check_compose
COMPOSE="$PF_COMPOSE_CMD"
[ -n "$COMPOSE" ] || die "nessun comando docker compose/docker-compose disponibile (dovrebbe essere gia' stato bloccato dal preflight)"

log_info "fermo i servizi applicativi (docker compose stop)"
cd "$STACK_DIR"
$COMPOSE stop irccs-microservice-auth irccs-microservice-anagrafica-pazienti \
  irccs-microservice-studio-clinico irccs-microservice-centro-ricerca \
  irccs-microservice-practitioner irccs-microservice-clinical-reasoning \
  irccs-microservice-notification irccs-microservice-tac irccs-microservice-zammad \
  irccs-microservice-webpush irccs-microservice-patient-interview \
  irccs-httpd irccs-keycloak irccs-hapi-fhir irccs-hapi-audit irccs-audit-integrity \
  2>&1 | while IFS= read -r line; do log_info "  $line"; done

# --- §3-4: decifra + restore_db.sh per ogni DB -------------------------
for db in "${DBS[@]}"; do
  PLAIN="$(mktemp "/tmp/restore-orchestrated-${db}-XXXXXX.dump")"
  log_info "decifro: ${ARCHIVE_FILE[$db]} -> $PLAIN"
  if ! age -d -i "$KEY_FILE" -o "$PLAIN" "${ARCHIVE_FILE[$db]}"; then
    rm -f "$PLAIN"
    die "decifratura fallita per db=$db archivio=${ARCHIVE_FILE[$db]} (chiave sbagliata o archivio corrotto)"
  fi

  log_info "restore_db.sh per db=$db"
  if ! "$SCRIPT_DIR/restore_db.sh" "$db" "$PLAIN" "--yes-i-am-sure=$CURRENT_HOST"; then
    [ "$KEEP_PLAINTEXT" = true ] || shred -u "$PLAIN" 2>/dev/null || rm -f "$PLAIN"
    die "restore_db.sh fallito per db=$db, interrompo (i DB non ancora processati restano nello stato precedente)"
  fi

  if [ "$KEEP_PLAINTEXT" = true ]; then
    log_warn "--keep-plaintext: $PLAIN NON rimosso, ricordarsi di cancellarlo a mano (shred -u)"
  else
    shred -u "$PLAIN" 2>/dev/null || rm -f "$PLAIN"
    log_info "plaintext rimosso: $PLAIN"
  fi
done

# --- §7: riavvio ordinato -----------------------------------------------
log_info "riavvio ordinato: keycloak"
$COMPOSE up -d irccs-keycloak

log_info "attesa readiness Keycloak..."
# Stesso probe dell'healthcheck in docker-compose.yaml (porta 9000, management
# interface, non 8080): l'immagine Keycloak e' UBI micro, curl non e'
# garantito presente, e /health/ready sulla 8080 e' comunque la porta
# sbagliata dalla KC26 in poi.
for _ in $(seq 1 30); do
  docker exec irccs-keycloak sh -c \
    "exec 3<>/dev/tcp/localhost/9000 && echo -e 'GET /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3 && cat <&3 | grep -q '200 OK'" \
    >/dev/null 2>&1 && break
  sleep 2
done

log_info "riavvio ordinato: hapi-fhir"
$COMPOSE up -d irccs-hapi-fhir

log_info "attesa readiness HAPI FHIR..."
# HAPI e' esposto su 127.0.0.1:8080 dell'HOST (vedi docker-compose.yaml),
# curlare da qui invece che con docker exec - stessa convenzione degli
# script di setup del progetto (install_searchparameters.sh ecc.).
for _ in $(seq 1 30); do
  curl -sf http://127.0.0.1:8080/fhir/metadata >/dev/null 2>&1 && break
  sleep 2
done

log_info "riavvio ordinato: resto della stack"
$COMPOSE up -d

log_info "=== restore_orchestrated.sh completato ==="
log_warn "RESTANO MANUALI (playbook §8-9): verifica funzionale (login, query FHIR, dashboard, hash-chain audit se restorato), annotare RTO/esito nello storico del playbook, riattivare i timer di backup se erano stati fermati, notificare DPO se restore reale"
