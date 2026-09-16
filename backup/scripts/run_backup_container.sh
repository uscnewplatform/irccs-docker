#!/usr/bin/env bash
# Wrapper lanciato da systemd (irccs-backup.service). Orchestratore host del
# backup notturno.
#
# ARCHITETTURA (2026-09-16, rivista per chiudere un escape verificato): dump
# (backup_db.sh) e verify (verify_restore.sh) girano QUI, direttamente
# sull'host, usando il docker.sock reale — questo script gira gia' come
# processo root gestito da systemd, con accesso Docker completo per gestione
# della stack: non e' un privilegio nuovo, e' lo stesso livello di fiducia
# che l'host ha sempre avuto. Un giro precedente aveva instradato queste
# operazioni attraverso un container "irccs-backup-run" dietro un
# docker-socket-proxy a permessi ridotti (CONTAINERS+EXEC+NETWORKS+IMAGES):
# verificato EMPIRICAMENTE che con quella configurazione un container
# compromesso puo' comunque fare `docker create --privileged -v /:/host` e
# uscire verso root host (tecnativa/docker-socket-proxy filtra per categoria
# di endpoint, non per campo del payload — CONTAINERS+POST=1 abilita anche
# /containers/create, non solo l'exec su container esistenti; non esiste
# nel proxy un modo per separare "exec su container esistente" da "crea
# container nuovo" una volta che POST e' abilitato).
#
# Fix strutturale: il container "irccs-backup-run" ora fa SOLO cifratura
# (age) + push offsite (rclone) + retention sui dump GIA' verificati — non
# ha e non deve avere alcun accesso alla Docker API (nessun socket, nessun
# proxy, nessun DOCKER_HOST, nessun docker-cli nell'immagine). Chi lo
# compromette puo' al massimo leggere/scrivere dentro BACKUP_ROOT e usare
# age/rclone: nessuna via di escape verso l'host via Docker, perche' la
# Docker API semplicemente non e' raggiungibile da dentro quel container.
# Il container gira comunque con --cap-drop=ALL --security-opt=no-new-
# privileges come difesa in profondita' aggiuntiva.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
# STACK_DIR: normalmente il repo padre (prod). Override con BACKUP_STACK_DIR
# per puntare a un altro .env (es. test su pascale-local).
STACK_DIR="${BACKUP_STACK_DIR:-$(dirname "$BACKUP_DIR")}"
IMAGE="${BACKUP_IMAGE:-irccs-backup:latest}"

[ -f "$STACK_DIR/.env" ] || { echo ".env stack non trovato: $STACK_DIR/.env" >&2; exit 1; }
[ -f "$BACKUP_DIR/.env.backup" ] || { echo "backup/.env.backup non trovato (copiare da .env.backup.example)" >&2; exit 1; }

# BACKUP_ROOT serve qui per il bind mount host<->container (stesso path dentro
# e fuori, cosi' gli script interni non devono sapere se girano in container).
# .env.backup e' un file pulito, semplice KEY=VALUE: sourcing diretto sicuro
# (a differenza del .env della stack, che passa solo via --env-file sotto,
# mai sourced in bash).
set -a
# shellcheck source=/dev/null
source "$BACKUP_DIR/.env.backup"
set +a

[ -n "${BACKUP_ROOT:-}" ] || { echo "BACKUP_ROOT non definito in .env.backup" >&2; exit 1; }
mkdir -p "$BACKUP_ROOT"

# Usato SOLO qui sull'host (extract_env_var sotto), mai passato al container:
# .env della stack contiene molti segreti non correlati al backup (JWT_SECRET,
# password di altri servizi...) — filtrarlo per sintassi (KEY=VALUE valida)
# non basterebbe a scremare il CONTENUTO, quindi non deve mai raggiungere
# --env-file di un container. Le uniche variabili che servono davvero
# (POSTGRES_KEYCLOAK_*, HAPI_DB_*, HAPI_AUDIT_DB_*) vengono estratte una per
# una qui sotto e tenute nel processo bash dell'host.
STACK_ENV_SANITIZED="$(mktemp)"
trap 'rm -f "$STACK_ENV_SANITIZED"' EXIT
grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$STACK_DIR/.env" > "$STACK_ENV_SANITIZED" || true

# Dump/verify girano qui, sull'host: servono le stesse variabili DB nel
# processo bash corrente. NON si fa `source` di STACK_ENV_SANITIZED: e' un
# grep del .env della stack, filtra solo la SINTASSI (KEY=VALUE), non il
# CONTENUTO — un valore con caratteri shell-unsafe (es. JWT_SECRET con `$`
# o backtick) verrebbe eseguito come comando da un source diretto. Si
# estraggono con grep+cut solo le variabili DB che servono davvero qui,
# trattandole come dato, mai come codice.
# Non sovrascrive se gia' presente nell'ambiente (es. HAPI_AUDIT_DB_NAME e
# talvolta HAPI_AUDIT_DB_USER non sono nel .env della stack su alcuni
# ambienti — hardcoded nel docker-compose del servizio — e vanno impostati
# a mano in backup/.env.backup in quel caso, vedi .env.backup.example).
extract_env_var() {
  local var="$1" from_stack
  from_stack="$(grep -E "^$var=" "$STACK_ENV_SANITIZED" | tail -1 | cut -d= -f2-)" || true
  if [ -n "$from_stack" ]; then
    export "$var=$from_stack"
  fi
}
extract_env_var HAPI_DB_USER
extract_env_var HAPI_DB_NAME
extract_env_var POSTGRES_KEYCLOAK_USER
extract_env_var POSTGRES_KEYCLOAK_DB
extract_env_var HAPI_AUDIT_DB_USER
extract_env_var HAPI_AUDIT_DB_NAME

# Log: sia le operazioni host (dump/verify) sia l'output del container
# (cifratura/retention) finiscono nello stesso file, letto da Alloy via
# loki.source.file (tailing, nessuna dipendenza da discovery/timing su
# container one-shot). Questo script gira come ExecStart di
# irccs-backup.service: il SUO intero stdout/stderr (incluso quanto scritto
# dagli script host-side E dal `docker run` sottostante) finisce anche nel
# journal di quell'unit, ingerito da loki.source.journal con label
# unit="irccs-backup.service" — e' la sorgente usata dalle regole di alert
# in backup/alerting/backup-rules.yaml (stesso pattern gia' usato da
# irccs-backup-verify.service).
LOG_FILE="${BACKUP_LOG_FILE:-/var/log/irccs-backup/backup.log}"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

# Rete di sicurezza per l'alerting: ogni step gestito esplicitamente (if/else
# sotto) produce gia' un log_error corretto se fallisce, ma un comando "nudo"
# non avvolto in if/||true che fallisce sotto `set -e` termina lo script
# SENZA passare da log_error/die — dimostrato empiricamente in questa sessione
# (due bug reali trovati: un `source` fallito e una pipe con grep senza match
# hanno ucciso lo script prima di qualunque log strutturato, l'alert veloce
# "backup fallito" non li avrebbe visti, solo il lento "backup assente" 26h
# dopo). set -E fa ereditare il trap ERR anche dentro le funzioni.
set -E
trap 'log_error "crash inatteso alla linea $LINENO (comando: $BASH_COMMAND)"' ERR

log_info "=== backup notturno avviato ==="

check_disk_space "$BACKUP_ROOT" "${BACKUP_MIN_FREE_MB:-2048}"

mapfile -t DUMPS < <("$SCRIPT_DIR/backup_db.sh")
HAPI_DUMP="${DUMPS[0]}"
KEYCLOAK_DUMP="${DUMPS[1]}"
HAPI_AUDIT_DUMP="${DUMPS[2]}"

FAILED=0
VERIFIED_DBS=()

for entry in "hapi:$HAPI_DUMP" "keycloak:$KEYCLOAK_DUMP" "hapi-audit:$HAPI_AUDIT_DUMP"; do
  kind="${entry%%:*}"
  dump="${entry#*:}"

  if "$SCRIPT_DIR/verify_restore.sh" "$kind" "$dump"; then
    VERIFIED_DBS+=("$entry")
  else
    log_error "verify fallita per $kind, dump conservato in staging per analisi: $dump"
    FAILED=1
  fi
done

if [ "${#VERIFIED_DBS[@]}" -gt 0 ]; then
  VERIFIED_LIST="$(IFS=','; echo "${VERIFIED_DBS[*]}")"

  # Container SENZA alcun accesso Docker: nessun -v /var/run/docker.sock,
  # nessun proxy, nessun DOCKER_HOST. Fa solo cifratura+offsite+retention sui
  # dump gia' verificati sopra, ricevuti via env (non tocca mai la Docker API).
  # cap-drop ALL + le sole CHOWN/DAC_OVERRIDE/FOWNER: servono per scrivere
  # come root nel bind mount di BACKUP_ROOT quando l'owner sull'host non
  # coincide con l'UID del container (senza queste tre, il container non
  # riesce nemmeno a fare `mkdir` dentro BACKUP_ROOT — verificato con test
  # reale). Nessuna di queste tre permette escape verso l'host: agiscono
  # solo su file all'interno dei mount del container stesso.
  # NIENTE --env-file su STACK_ENV_SANITIZED qui: encrypt_and_offsite.sh e
  # retention_cleanup.sh non leggono ne' usano alcuna credenziale DB della
  # stack (dump/verify sono gia' finiti sull'host sopra). Passare comunque
  # l'intero .env della stack esporrebbe inutilmente al container anche
  # segreti non correlati (JWT_SECRET, WEBPUSH_DB_PASSWORD, ecc.) — solo
  # backup/.env.backup (config age/rclone/retention) e VERIFIED_DBS servono.
  if ! docker run --rm --name irccs-backup-run \
      --cap-drop=ALL --cap-add=CHOWN --cap-add=DAC_OVERRIDE --cap-add=FOWNER \
      --security-opt=no-new-privileges \
      -e VERIFIED_DBS="$VERIFIED_LIST" \
      -v "$BACKUP_ROOT:$BACKUP_ROOT" \
      --env-file "$BACKUP_DIR/.env.backup" \
      "$IMAGE"; then
    FAILED=1
  fi
else
  log_warn "nessun dump verificato con successo: nessuna cifratura/offsite/retention da eseguire questa notte"
fi

if [ "$FAILED" -ne 0 ]; then
  die "backup notturno completato CON ERRORI: vedere log sopra"
fi

log_info "=== backup notturno completato con successo ==="
