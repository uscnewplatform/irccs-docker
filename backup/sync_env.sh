#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# sync_env.sh — Backup ambiente SOURCE (es. prod) + restore su ambiente
# TARGET (es. lab/preprod), lanciato dalla tua macchina via SSH.
#
# Non tocca MAI il DB target finché non conferma che il dump e' valido.
# Non tocca MAI il DB source in scrittura (solo pg_dump, read-only).
# Ferma solo i container app (hapi/keycloak) sul TARGET, mai sul SOURCE.
#
# USO INTERATTIVA (consigliata):
#   ./sync_env.sh
#   → chiede passo passo IP, porta, utente, dir per SOURCE e per TARGET.
#
# USO NON INTERATTIVA (per automazione):
#   ./sync_env.sh \
#     --src-host prod.example.it --src-port 22 --src-user infocube --src-dir /home/infocube/irccs-docker \
#     --dst-host lab.example.it  --dst-port 22 --dst-user infocube --dst-dir /home/infocube/irccs-docker \
#     [--yes]        # salta conferma interattiva prima del restore (comunque distruttivo su TARGET)
#     [--keep-local] # non cancella i dump scaricati in locale a fine run
#
# Richiede: accesso SSH (key-based, consigliato) a src e dst, docker/docker
# compose funzionanti su entrambi, utente con permessi docker.
#
# ALTERNATIVA A CHIAVE SSH (password via env var, uso locale):
#   sudo apt install sshpass   # (una tantum)
#   export SYNC_SRC_SSH_PASS='password ssh di SOURCE'
#   export SYNC_DST_SSH_PASS='password ssh di TARGET'
#   ./sync_env.sh
#   unset SYNC_SRC_SSH_PASS SYNC_DST_SSH_PASS   # a fine sessione
# Se sshpass non e' installato o le env var non sono impostate, lo script
# chiede la password normalmente ad ogni comando ssh/scp (nessuna rottura).
# Non salvare queste password in file committati o in chiaro su disco.
#
# NOTE (2026-09-17) — fix emersi da un restore prod->preprod andato storto:
#   - Wipe completo (DROP SCHEMA public CASCADE + unlink large object) PRIMA
#     del restore, al posto di "pg_restore --clean": --clean genera i DROP
#     solo per gli oggetti presenti nel dump di SOURCE, quindi si blocca se
#     TARGET ha oggetti extra (viste custom, BLOB residui) non presenti li'
#     dentro, lasciando un DB in stato MISTO (righe vecchie+nuove, chiavi
#     duplicate, FK rotte) con errori solo "ignorati" — un restore che sembra
#     riuscito ma non lo e'. Il wipe totale e' sicuro perche' il restore e'
#     sempre pensato come sovrascrittura integrale di TARGET.
#   - pg_restore ora usa --exit-on-error: qualsiasi errore reale fa fallire
#     subito lo script invece di proseguire silenziosamente.
#   - Riconciliazione partition_id (HAPI-1996 "resource not known" pur avendo
#     la riga nel DB) e' REATTIVA allo smoke test finale, non piu' basata su
#     un campione pre-restore di TARGET (si e' rivelato inaffidabile: dopo un
#     wipe completo non resta nessuna riga vecchia da cui dedurre la
#     semantica di partizione di quella specifica istanza HAPI).
#   - STEP 5.5 (backup secret Keycloak) prova a riavviare irccs-keycloak da
#     solo se lo trova gia' fermo, invece di fallire subito.
#   - Prompt esplicito prima del reindex (skippabile con --yes).
# ============================================================================

SRC_HOST="" ; SRC_PORT="" ; SRC_USER="" ; SRC_DIR=""
DST_HOST="" ; DST_PORT="" ; DST_USER="" ; DST_DIR=""
AUTO_YES=false
KEEP_LOCAL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-host) SRC_HOST="$2"; shift 2 ;;
    --src-port) SRC_PORT="$2"; shift 2 ;;
    --src-user) SRC_USER="$2"; shift 2 ;;
    --src-dir)  SRC_DIR="$2"; shift 2 ;;
    --dst-host) DST_HOST="$2"; shift 2 ;;
    --dst-port) DST_PORT="$2"; shift 2 ;;
    --dst-user) DST_USER="$2"; shift 2 ;;
    --dst-dir)  DST_DIR="$2"; shift 2 ;;
    --yes) AUTO_YES=true; shift ;;
    --keep-local) KEEP_LOCAL=true; shift ;;
    *) echo "Argomento sconosciuto: $1"; exit 1 ;;
  esac
done

ask() {
  # ask <var_name> <prompt> <default>
  local __var="$1" __prompt="$2" __default="$3" __input
  if [[ -n "${!__var}" ]]; then return; fi   # gia' passato via flag, non chiedere
  if [[ -n "$__default" ]]; then
    read -r -p "${__prompt} [${__default}]: " __input
    printf -v "$__var" '%s' "${__input:-$__default}"
  else
    while [[ -z "${!__var:-}" ]]; do
      read -r -p "${__prompt}: " __input
      [[ -z "$__input" ]] && echo "  campo obbligatorio, riprova." || printf -v "$__var" '%s' "$__input"
    done
  fi
}

echo "==================== CONFIGURAZIONE SOURCE (ambiente da cui leggere) ===================="
ask SRC_HOST "IP o hostname SOURCE" ""
ask SRC_PORT "Porta SSH SOURCE" "22"
ask SRC_USER "Utente SSH SOURCE" ""
ask SRC_DIR  "Path irccs-docker su SOURCE" "/home/${SRC_USER}/irccs-docker"

echo ""
echo "==================== CONFIGURAZIONE TARGET (ambiente su cui scrivere) ===================="
ask DST_HOST "IP o hostname TARGET" ""
ask DST_PORT "Porta SSH TARGET" "22"
ask DST_USER "Utente SSH TARGET" ""
ask DST_DIR  "Path irccs-docker su TARGET" "/home/${DST_USER}/irccs-docker"

if [[ "$SRC_HOST" == "$DST_HOST" && "$SRC_PORT" == "$DST_PORT" ]]; then
  echo ""
  echo "!!! SOURCE e TARGET puntano alla stessa macchina (${SRC_HOST}:${SRC_PORT})."
  echo "!!! Restore --clean sovrascriverebbe lo stesso DB da cui hai appena fatto il dump."
  echo "!!! Bloccato per sicurezza."
  exit 1
fi

echo ""
echo "==================== RIEPILOGO CONFIGURAZIONE ===================="
echo "  SOURCE: ${SRC_USER}@${SRC_HOST}:${SRC_PORT}  ${SRC_DIR}"
echo "  TARGET: ${DST_USER}@${DST_HOST}:${DST_PORT}  ${DST_DIR}"
echo "===================================================================="
if [[ "$AUTO_YES" == false ]]; then
  read -r -p "Procedo con backup SOURCE + restore TARGET? [s/N]: " GO
  [[ "$GO" =~ ^[sSyY]$ ]] || { echo "Annullato."; exit 0; }
fi

log() { echo "==> $*"; }
warn() { echo "!!! $*" >&2; }

# ----------------------------------------------------------------------------
# Password SSH via env var (uso locale, non salvate su disco): se
# SYNC_SRC_SSH_PASS / SYNC_DST_SSH_PASS sono valorizzate E sshpass e'
# installato, ssh/scp non chiedono la password interattivamente. Altrimenti
# fallback silenzioso al prompt normale (comportamento identico a prima).
# Impostale nella shell PRIMA di lanciare lo script (mai in un file committato
# o salvato in chiaro su disco), es.:
#   export SYNC_SRC_SSH_PASS='...'
#   export SYNC_DST_SSH_PASS='...'
#   ./sync_env.sh
#   unset SYNC_SRC_SSH_PASS SYNC_DST_SSH_PASS   # a fine sessione
# Nota: con 'sshpass -p' la password e' visibile per un istante a chi lancia
# 'ps aux' sulla tua macchina mentre lo script gira (locale, non sui server
# remoti). Se questo e' un problema nel tuo contesto, usa una chiave SSH
# (ssh-copy-id) invece: zero segreti in giro, revoca immediata.
# ----------------------------------------------------------------------------
SSHPASS_SRC=(); SSHPASS_DST=()
if command -v sshpass >/dev/null 2>&1; then
  [[ -n "${SYNC_SRC_SSH_PASS:-}" ]] && SSHPASS_SRC=(sshpass -p "$SYNC_SRC_SSH_PASS")
  [[ -n "${SYNC_DST_SSH_PASS:-}" ]] && SSHPASS_DST=(sshpass -p "$SYNC_DST_SSH_PASS")
elif [[ -n "${SYNC_SRC_SSH_PASS:-}" || -n "${SYNC_DST_SSH_PASS:-}" ]]; then
  warn "SYNC_*_SSH_PASS impostata ma 'sshpass' non e' installato: verra' comunque chiesta la password a mano."
  warn "Installa con: sudo apt install sshpass  (o 'brew install hudochenkov/sshpass/sshpass' su mac)"
fi

SSH_SRC=("${SSHPASS_SRC[@]}" ssh -o ConnectTimeout=8 -p "$SRC_PORT" "${SRC_USER}@${SRC_HOST}")
SSH_DST=("${SSHPASS_DST[@]}" ssh -o ConnectTimeout=8 -p "$DST_PORT" "${DST_USER}@${DST_HOST}")
SCP_SRC_PORT="$SRC_PORT"
SCP_DST_PORT="$DST_PORT"

DATE=$(date +%Y%m%d_%H%M%S)
LOCAL_TMP=$(mktemp -d "/tmp/sync_env_${DATE}_XXXX")
REMOTE_BACKUP_DIR_SRC="${SRC_DIR}/backup_${DATE}"
REMOTE_BACKUP_DIR_DST="${DST_DIR}/backup_${DATE}"

log "Source: ${SRC_USER}@${SRC_HOST}:${SRC_PORT}  (${SRC_DIR})"
log "Target: ${DST_USER}@${DST_HOST}:${DST_PORT}  (${DST_DIR})"
log "Tmp locale: ${LOCAL_TMP}"

cleanup() {
  if [[ "$KEEP_LOCAL" == false ]]; then
    rm -rf "$LOCAL_TMP"
  fi
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# STEP 0 — check connettivita' + docker su entrambi gli host
# ----------------------------------------------------------------------------
log "Check connessione SSH + docker su SOURCE..."
"${SSH_SRC[@]}" "docker ps --format '{{.Names}}' | grep -qE '^postgres-hapi-fhir$' && docker ps --format '{{.Names}}' | grep -qE '^postgres-keycloak$'" \
  || { warn "SOURCE: container postgres-hapi-fhir / postgres-keycloak non trovati o non attivi."; exit 1; }

log "Check connessione SSH + docker su TARGET..."
"${SSH_DST[@]}" "docker ps --format '{{.Names}}' | grep -qE '^postgres-hapi-fhir$' && docker ps --format '{{.Names}}' | grep -qE '^postgres-keycloak$'" \
  || { warn "TARGET: container postgres-hapi-fhir / postgres-keycloak non trovati o non attivi."; exit 1; }

# ----------------------------------------------------------------------------
# STEP 1 — conteggi SOURCE prima del dump (per confronto finale automatico)
# ----------------------------------------------------------------------------
log "Leggo conteggi di riferimento su SOURCE..."
SRC_HAPI_COUNT=$("${SSH_SRC[@]}" "docker exec postgres-hapi-fhir psql -U admin -d hapi -tAc 'SELECT count(*) FROM hfj_resource;'" | tr -d '[:space:]')
SRC_KC_COUNT=$("${SSH_SRC[@]}" "docker exec postgres-keycloak psql -U keycloak_owner -d keycloak -tAc 'SELECT count(*) FROM user_entity;'" | tr -d '[:space:]')
log "  SOURCE hfj_resource=${SRC_HAPI_COUNT}  user_entity=${SRC_KC_COUNT}"

# Nota su partition_id: HAPI puo' risolvere una "partizione di default"
# diversa da NULL (es. 0) a seconda della storia dell'istanza TARGET, in modo
# non deducibile dai dati (un DROP SCHEMA CASCADE + restore pulito azzera
# qualsiasi riga da cui dedurlo). Non tento piu' di indovinarlo PRIMA del
# restore: la riconciliazione (se serve) e' guidata dal risultato REALE dello
# smoke test dopo il restore — vedi STEP 7.5/7.6.

# Credenziali admin Keycloak SOURCE: dopo il restore il DB Keycloak TARGET
# conterra' gli utenti/admin di SOURCE, quindi per operare via kcadm.sh su
# TARGET post-restore serviranno queste credenziali (non quelle di TARGET).
SRC_KC_ADMIN=$("${SSH_SRC[@]}" "cd '${SRC_DIR}' && source .env 2>/dev/null; echo \$KEYCLOAK_ADMIN")
SRC_KC_ADMIN_PASSWORD=$("${SSH_SRC[@]}" "cd '${SRC_DIR}' && source .env 2>/dev/null; echo \$KEYCLOAK_ADMIN_PASSWORD")

# ----------------------------------------------------------------------------
# STEP 2 — dump su SOURCE (read-only, no downtime, niente -t su docker exec)
# ----------------------------------------------------------------------------
log "Eseguo pg_dump su SOURCE (nessun impatto scrittura, no downtime)..."
"${SSH_SRC[@]}" bash -s <<REMOTE_DUMP
set -euo pipefail
mkdir -p "${REMOTE_BACKUP_DIR_SRC}"
cd "${SRC_DIR}"
source .env 2>/dev/null || true
HAPI_DB_NAME="\${HAPI_DB_NAME:-hapi}"
HAPI_DB_USER="\${HAPI_DB_USER:-admin}"
KC_DB_NAME="\${POSTGRES_KEYCLOAK_DB:-keycloak}"
KC_DB_USER="\${POSTGRES_KEYCLOAK_USER:-keycloak_owner}"

verify_dump() {
  local file="\$1" container="\$2"
  local tmp_name="/tmp/verify_\$(basename "\$file")"
  docker cp "\$file" "\${container}:\${tmp_name}" > /dev/null
  if ! docker exec "\$container" pg_restore -l "\$tmp_name" > /dev/null 2>&1; then
    docker exec "\$container" rm -f "\$tmp_name"
    echo "DUMP_CORROTTO: \$file"
    return 1
  fi
  docker exec "\$container" rm -f "\$tmp_name"
}

echo "  dump HAPI FHIR..."
docker exec postgres-hapi-fhir pg_dump -U "\$HAPI_DB_USER" -F c -d "\$HAPI_DB_NAME" > "${REMOTE_BACKUP_DIR_SRC}/hapi_${DATE}.dump"
verify_dump "${REMOTE_BACKUP_DIR_SRC}/hapi_${DATE}.dump" postgres-hapi-fhir

echo "  dump Keycloak..."
docker exec postgres-keycloak pg_dump -U "\$KC_DB_USER" -F c -d "\$KC_DB_NAME" > "${REMOTE_BACKUP_DIR_SRC}/keycloak_${DATE}.dump"
verify_dump "${REMOTE_BACKUP_DIR_SRC}/keycloak_${DATE}.dump" postgres-keycloak

echo "  OK entrambi i dump validi su SOURCE."
REMOTE_DUMP

log "Dump completati e validati su SOURCE: ${REMOTE_BACKUP_DIR_SRC}"

# ----------------------------------------------------------------------------
# STEP 3 — trasferimento SOURCE -> locale -> TARGET (passa dalla tua macchina,
# cosi' hai sempre una copia locale del backup)
# ----------------------------------------------------------------------------
log "Scarico dump da SOURCE verso locale..."
"${SSHPASS_SRC[@]}" scp -o ConnectTimeout=8 -P "$SCP_SRC_PORT" -r "${SRC_USER}@${SRC_HOST}:${REMOTE_BACKUP_DIR_SRC}" "${LOCAL_TMP}/"
LOCAL_BACKUP_DIR="${LOCAL_TMP}/backup_${DATE}"

log "Verifico checksum locale..."
LOCAL_HAPI=$(ls "${LOCAL_BACKUP_DIR}"/hapi_*.dump)
LOCAL_KC=$(ls "${LOCAL_BACKUP_DIR}"/keycloak_*.dump)
ls -lh "$LOCAL_HAPI" "$LOCAL_KC"

log "Carico dump da locale verso TARGET..."
"${SSH_DST[@]}" "mkdir -p '${REMOTE_BACKUP_DIR_DST}'"
"${SSHPASS_DST[@]}" scp -o ConnectTimeout=8 -P "$SCP_DST_PORT" "$LOCAL_HAPI" "$LOCAL_KC" "${DST_USER}@${DST_HOST}:${REMOTE_BACKUP_DIR_DST}/"

# ----------------------------------------------------------------------------
# STEP 4 — verifica integrita' dump sul TARGET prima di toccare qualsiasi DB
# ----------------------------------------------------------------------------
log "Verifico integrita' dump su TARGET (nessuna modifica DB ancora)..."
"${SSH_DST[@]}" bash -s <<REMOTE_VERIFY
set -euo pipefail
verify_dump() {
  local file="\$1" container="\$2"
  local tmp_name="/tmp/verify_\$(basename "\$file")"
  docker cp "\$file" "\${container}:\${tmp_name}" > /dev/null
  if ! docker exec "\$container" pg_restore -l "\$tmp_name" > /dev/null 2>&1; then
    docker exec "\$container" rm -f "\$tmp_name"
    echo "DUMP_CORROTTO: \$file"
    exit 1
  fi
  docker exec "\$container" rm -f "\$tmp_name"
}
verify_dump "${REMOTE_BACKUP_DIR_DST}/$(basename "$LOCAL_HAPI")" postgres-hapi-fhir
verify_dump "${REMOTE_BACKUP_DIR_DST}/$(basename "$LOCAL_KC")" postgres-keycloak
echo "OK entrambi i dump validi su TARGET."
REMOTE_VERIFY

# ----------------------------------------------------------------------------
# STEP 5 — conferma esplicita (operazione distruttiva SOLO su TARGET)
# ----------------------------------------------------------------------------
if [[ "$AUTO_YES" == false ]]; then
  echo ""
  warn "STAI PER SOVRASCRIVERE i DB hapi + keycloak su TARGET: ${DST_HOST}"
  warn "SOURCE (${SRC_HOST}) non viene toccato in nessun modo."
  read -r -p "Scrivi 'RESTORE' per confermare: " CONFIRM
  if [[ "$CONFIRM" != "RESTORE" ]]; then
    echo "Annullato. Nessuna modifica fatta su TARGET."
    exit 1
  fi
fi

# ----------------------------------------------------------------------------
# STEP 5.5 — salvo secret/redirect URI dei client Keycloak di TARGET, PRIMA
# di toccare il DB. Il restore sovrascrive questi valori con quelli di
# SOURCE: senza questo passaggio, i client configurati nei .env/properties
# di TARGET smetterebbero di autenticarsi (secret non piu' corrispondente).
# ----------------------------------------------------------------------------
log "Salvo secret/redirect URI dei client Keycloak di TARGET (verranno ripristinati dopo)..."
DST_REALM=$("${SSH_DST[@]}" "cd '${DST_DIR}' && source .env 2>/dev/null; echo \${KEYCLOAK_REALM:-pascale}")
DST_KC_ADMIN=$("${SSH_DST[@]}" "cd '${DST_DIR}' && source .env 2>/dev/null; echo \$KEYCLOAK_ADMIN")
DST_KC_ADMIN_PASSWORD=$("${SSH_DST[@]}" "cd '${DST_DIR}' && source .env 2>/dev/null; echo \$KEYCLOAK_ADMIN_PASSWORD")
TARGET_KC_BACKUP="${LOCAL_TMP}/target_kc_clients_${DATE}.json"

# Se TARGET e' in uno stato di recovery precedente (es. dopo un intervento
# manuale) il container Keycloak potrebbe essere gia' fermo qui. Provo a
# rialzarlo prima di rinunciare: senza un Keycloak vivo l'export dei secret
# e' impossibile per definizione, ma non serve fallire subito se basta
# riaccenderlo.
if ! "${SSH_DST[@]}" "docker ps --format '{{.Names}}' | grep -qE '^irccs-keycloak$'" 2>/dev/null; then
  warn "irccs-keycloak non risulta attivo su TARGET: provo a riavviarlo prima dell'export secret..."
  "${SSH_DST[@]}" "cd '${DST_DIR}' && (docker compose up -d irccs-keycloak 2>/dev/null || docker-compose up -d irccs-keycloak)"
  for i in $(seq 1 15); do
    "${SSH_DST[@]}" "docker exec irccs-keycloak curl -sf http://localhost:8080/health/ready" >/dev/null 2>&1 && break
    sleep 4
  done
fi

if command -v jq >/dev/null 2>&1; then
  "${SSH_DST[@]}" "docker exec irccs-keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user '${DST_KC_ADMIN}' --password '${DST_KC_ADMIN_PASSWORD}' >/dev/null && docker exec irccs-keycloak /opt/keycloak/bin/kcadm.sh get clients -r '${DST_REALM}'" > "$TARGET_KC_BACKUP" \
    || { warn "Export client Keycloak TARGET fallito. Nessuna modifica fatta finora, controlla kcadm.sh/credenziali prima di continuare."; exit 1; }
  log "  salvati $(jq 'length' "$TARGET_KC_BACKUP") client (realm ${DST_REALM}) in ${TARGET_KC_BACKUP}"
else
  warn "jq non trovato in locale: SALTO salvataggio/ripristino automatico secret Keycloak."
  warn "Dopo il restore i client Keycloak avranno i secret di SOURCE — verifica manualmente."
fi

# ----------------------------------------------------------------------------
# STEP 6 — restore su TARGET
# ----------------------------------------------------------------------------
log "Fermo app (solo su TARGET, DB restano su) e lancio restore..."
"${SSH_DST[@]}" bash -s <<REMOTE_RESTORE
set -euo pipefail
cd "${DST_DIR}"
source .env 2>/dev/null || true
HAPI_DB_NAME="\${HAPI_DB_NAME:-hapi}"
HAPI_DB_USER="\${HAPI_DB_USER:-admin}"
KC_DB_NAME="\${POSTGRES_KEYCLOAK_DB:-keycloak}"
KC_DB_USER="\${POSTGRES_KEYCLOAK_USER:-keycloak_owner}"

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  echo "!!! Ne' 'docker compose' ne' 'docker-compose' disponibili su TARGET." >&2
  exit 1
fi
echo "  uso: \$COMPOSE"

\$COMPOSE stop irccs-hapi-fhir irccs-keycloak

# Wipe completo dello schema public PRIMA del restore, invece di affidarsi
# a "pg_restore --clean" (che genera i DROP solo per gli oggetti presenti
# nel dump di SOURCE). Se TARGET ha oggetti extra non presenti in SOURCE
# (viste/tabelle create a mano, es. report custom), --clean si blocca a
# meta' con errori di dipendenza ("cannot drop X because Y depends on it"),
# lasciando un DB in stato MISTO: righe vecchie + nuove, chiavi duplicate,
# FK rotte — un restore che sembra riuscito (errori solo "ignorati") ma
# lascia dati corrotti. Il DROP SCHEMA CASCADE elimina TUTTO senza dipendere
# dall'ordine o dal contenuto del dump: robusto qualsiasi cosa esista su
# TARGET. Sicuro perche' il restore e' sempre una sovrascrittura totale.
echo "  wipe schema public su HAPI (TARGET) prima del restore..."
docker exec postgres-hapi-fhir psql -U "\$HAPI_DB_USER" -d "\$HAPI_DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"\$HAPI_DB_USER\";"
# I large object (BLOB, usati da HAPI per res_text) vivono in un catalogo
# globale (pg_largeobject_metadata), NON nello schema: DROP SCHEMA CASCADE
# non li tocca. Vanno unlinkati esplicitamente, altrimenti pg_restore fallisce
# su collisione OID (lo_create tenta di riusare un OID di un BLOB vecchio
# ancora presente da TARGET).
echo "  unlink large object residui su HAPI (TARGET)..."
docker exec postgres-hapi-fhir psql -U "\$HAPI_DB_USER" -d "\$HAPI_DB_NAME" -c "SELECT lo_unlink(oid) FROM pg_largeobject_metadata;" >/dev/null

echo "  restore HAPI FHIR..."
docker cp "${REMOTE_BACKUP_DIR_DST}/$(basename "$LOCAL_HAPI")" postgres-hapi-fhir:/tmp/restore_hapi.dump
docker exec postgres-hapi-fhir pg_restore -U "\$HAPI_DB_USER" -d "\$HAPI_DB_NAME" --exit-on-error -v /tmp/restore_hapi.dump
docker exec postgres-hapi-fhir rm -f /tmp/restore_hapi.dump

echo "  wipe schema public su Keycloak (TARGET) prima del restore..."
docker exec postgres-keycloak psql -U "\$KC_DB_USER" -d "\$KC_DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"\$KC_DB_USER\";"

echo "  restore Keycloak..."
docker cp "${REMOTE_BACKUP_DIR_DST}/$(basename "$LOCAL_KC")" postgres-keycloak:/tmp/restore_keycloak.dump
docker exec postgres-keycloak pg_restore -U "\$KC_DB_USER" -d "\$KC_DB_NAME" --exit-on-error -v /tmp/restore_keycloak.dump
docker exec postgres-keycloak rm -f /tmp/restore_keycloak.dump

\$COMPOSE start irccs-hapi-fhir irccs-keycloak
echo "  app riavviate su TARGET."
REMOTE_RESTORE

# ----------------------------------------------------------------------------
# STEP 6.5 — ripristino secret/redirect URI TARGET sui client appena
# restorati (ora il DB contiene i client di SOURCE: stesso clientId, ma
# secret diverso). Usa le credenziali admin di SOURCE, perche' dopo il
# restore sono quelle valide nel DB.
# ----------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1 && [[ -s "${TARGET_KC_BACKUP:-}" ]]; then
  log "Attendo avvio Keycloak su TARGET prima di ripristinare i secret..."
  for i in $(seq 1 15); do
    "${SSH_DST[@]}" "docker exec irccs-keycloak curl -sf http://localhost:8080/health/ready" >/dev/null 2>&1 && break
    sleep 4
  done

  log "Ripristino secret/redirect URI dei client (valori originali di TARGET)..."
  "${SSH_DST[@]}" "docker exec irccs-keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user '${SRC_KC_ADMIN}' --password '${SRC_KC_ADMIN_PASSWORD}'" >/dev/null \
    || { warn "Login kcadm.sh su TARGET post-restore fallito. Ripristina i secret manualmente da ${TARGET_KC_BACKUP}."; }

  FAILED_CLIENTS=""
  while IFS= read -r client; do
    CID=$(echo "$client" | jq -r '.id')
    CLIENT_ID=$(echo "$client" | jq -r '.clientId')
    SECRET=$(echo "$client" | jq -r '.secret // empty')
    REDIRECTS=$(echo "$client" | jq -c '.redirectUris // []')
    ORIGINS=$(echo "$client" | jq -c '.webOrigins // []')
    [[ -z "$SECRET" || "$SECRET" == "null" ]] && continue
    if ! "${SSH_DST[@]}" "docker exec irccs-keycloak /opt/keycloak/bin/kcadm.sh update clients/${CID} -r '${DST_REALM}' -s 'secret=${SECRET}' -s 'redirectUris=${REDIRECTS}' -s 'webOrigins=${ORIGINS}'" >/dev/null 2>&1; then
      FAILED_CLIENTS="${FAILED_CLIENTS} ${CLIENT_ID}"
    fi
  done < <(jq -c '.[]' "$TARGET_KC_BACKUP")

  if [[ -n "$FAILED_CLIENTS" ]]; then
    warn "Ripristino secret fallito per:${FAILED_CLIENTS} — sistemali a mano (backup in ${TARGET_KC_BACKUP})."
  else
    log "  secret/redirect URI ripristinati su tutti i client di TARGET."
  fi
fi

# ----------------------------------------------------------------------------
# STEP 6.7 — reindex HAPI su TARGET. Dopo un restore, il DB contiene le
# risorse ma i SearchParameter custom (es. CarePlan:activity-outcomeReference)
# possono non essere ancora registrati/indicizzati dal motore di ricerca:
# senza reindex, alcune query REST falliscono con "Unknown search parameter"
# e la dashboard sembra non trovare dati che in realta' ci sono. Puo' richiedere
# diversi minuti su dataset grandi: chiedo conferma esplicita (skippabile con
# --yes, che lo esegue senza chiedere).
# ----------------------------------------------------------------------------
RUN_REINDEX=true
if [[ "$AUTO_YES" == false ]]; then
  read -r -p "Lancio \$reindex su TARGET ora? Consigliato, puo' richiedere minuti su dataset grandi [S/n]: " REINDEX_GO
  [[ "$REINDEX_GO" =~ ^[nN]$ ]] && RUN_REINDEX=false
fi

if [[ "$RUN_REINDEX" == false ]]; then
  warn "Reindex saltato su richiesta. La dashboard/REST potrebbe non vedere alcune risorse finche' non lo lanci a mano:"
  warn "  curl -X POST \"http://localhost:8080/fhir/\\\$reindex\" -H \"Content-Type: application/fhir+json\" -d '{\"resourceType\":\"Parameters\",\"parameter\":[]}'"
else
  log "Lancio \$reindex su TARGET (ricostruisce gli indici di ricerca, incluso SearchParameter custom)..."
  REINDEX_RESPONSE=$("${SSH_DST[@]}" 'curl -s -X POST "http://localhost:8080/fhir/\$reindex" -H "Content-Type: application/fhir+json" -d "{\"resourceType\":\"Parameters\",\"parameter\":[]}"')
  REINDEX_JOB_ID=$(echo "$REINDEX_RESPONSE" | jq -r '.parameter[]? | select(.name=="jobId") | .valueString' 2>/dev/null)

  if [[ -z "$REINDEX_JOB_ID" || "$REINDEX_JOB_ID" == "null" ]]; then
    warn "Reindex non avviato correttamente. Risposta HAPI:"
    echo "$REINDEX_RESPONSE" >&2
    warn "Puoi lanciarlo a mano: curl -X POST \"http://localhost:8080/fhir/\\\$reindex\" -H \"Content-Type: application/fhir+json\" -d '{\"resourceType\":\"Parameters\",\"parameter\":[]}'"
  else
    log "  reindex job: ${REINDEX_JOB_ID}"
    REINDEX_TIMEOUT_S=1800   # 30 min, alza se hai molte piu' risorse
    REINDEX_ELAPSED=0
    REINDEX_STAT="UNKNOWN"
    while (( REINDEX_ELAPSED < REINDEX_TIMEOUT_S )); do
      REINDEX_STAT=$("${SSH_DST[@]}" "docker exec postgres-hapi-fhir psql -U admin -d hapi -tAc \"SELECT stat FROM bt2_job_instance WHERE id='${REINDEX_JOB_ID}';\"" | tr -d '[:space:]')
      case "$REINDEX_STAT" in
        COMPLETED) log "  reindex COMPLETED."; break ;;
        ERRORED|FAILED|CANCELLED)
          ERR_MSG=$("${SSH_DST[@]}" "docker exec postgres-hapi-fhir psql -U admin -d hapi -tAc \"SELECT coalesce(error_msg,'') FROM bt2_job_instance WHERE id='${REINDEX_JOB_ID}';\"")
          warn "Reindex terminato con stato ${REINDEX_STAT}: ${ERR_MSG}"
          break
          ;;
        *) sleep 10; REINDEX_ELAPSED=$((REINDEX_ELAPSED + 10)) ;;
      esac
    done
    if [[ "$REINDEX_STAT" != "COMPLETED" && "$REINDEX_STAT" != "ERRORED" && "$REINDEX_STAT" != "FAILED" && "$REINDEX_STAT" != "CANCELLED" ]]; then
      warn "Reindex non completato entro ${REINDEX_TIMEOUT_S}s (ultimo stato: ${REINDEX_STAT}). Continua a girare in background su TARGET, controllalo con:"
      warn "  docker exec postgres-hapi-fhir psql -U admin -d hapi -c \"SELECT stat, progress_pct FROM bt2_job_instance WHERE id='${REINDEX_JOB_ID}';\""
    fi
  fi
fi

# ----------------------------------------------------------------------------
# STEP 7 — verifica finale automatica: confronto count SOURCE vs TARGET
# ----------------------------------------------------------------------------
log "Attendo qualche secondo per avvio app su TARGET..."
sleep 8

DST_HAPI_COUNT=$("${SSH_DST[@]}" "docker exec postgres-hapi-fhir psql -U admin -d hapi -tAc 'SELECT count(*) FROM hfj_resource;'" | tr -d '[:space:]')
DST_KC_COUNT=$("${SSH_DST[@]}" "docker exec postgres-keycloak psql -U keycloak_owner -d keycloak -tAc 'SELECT count(*) FROM user_entity;'" | tr -d '[:space:]')

# ----------------------------------------------------------------------------
# STEP 7.5 — smoke test: lettura REST diretta di una risorsa reale su TARGET,
# con riconciliazione partition_id REATTIVA se fallisce. Il confronto count(*)
# sopra verifica solo che le RIGHE ci siano nel DB, non che siano raggiungibili
# via HAPI REST (quello che usa davvero la dashboard). Non tentiamo piu' di
# INDOVINARE la partizione di default di TARGET prima del restore (si e'
# rivelato inaffidabile: un DROP SCHEMA CASCADE + restore pulito azzera
# qualsiasi riga da cui dedurlo) — reagiamo invece al fallimento REALE:
# se il read va in HAPI-1996 pur essendo la riga nel DB, e' la firma nota
# di questo bug (partition_id NULL non raggiungibile su un'istanza HAPI la
# cui risoluzione di default e' 0). Applichiamo il fix, reindicizziamo,
# ritentiamo UNA volta. Se fallisce ancora, ci fermiamo con errore chiaro
# invece di dichiarare falso successo.
# ----------------------------------------------------------------------------
smoke_test_patient() {
  local res_id="$1"
  local response
  response=$("${SSH_DST[@]}" "curl -s http://localhost:8080/fhir/Patient/${res_id}")
  echo "$response" | jq -r '.resourceType // empty' 2>/dev/null || true
}

log "Smoke test: lettura REST diretta di una risorsa reale su TARGET (non solo count DB)..."
SMOKE_RES_ID=$("${SSH_DST[@]}" "docker exec postgres-hapi-fhir psql -U admin -d hapi -tAc \"SELECT res_id FROM hfj_resource WHERE res_type='Patient' AND res_deleted_at IS NULL LIMIT 1;\"" | tr -d '[:space:]')
if [[ -n "$SMOKE_RES_ID" ]]; then
  SMOKE_TYPE=$(smoke_test_patient "$SMOKE_RES_ID")
  if [[ "$SMOKE_TYPE" == "Patient" ]]; then
    log "  OK: Patient/${SMOKE_RES_ID} raggiungibile via REST su TARGET."
  else
    warn "Smoke test fallito (Patient/${SMOKE_RES_ID} nel DB ma non raggiungibile via REST)."
    warn "  Firma nota: partition_id NULL non risolto dalla partizione di default di questa istanza HAPI."
    log "  Applico riconciliazione partition_id NULL -> 0 su TARGET e ritento..."
    "${SSH_DST[@]}" bash -s <<'REMOTE_PARTITION_FIX'
set -euo pipefail
TABLES=$(docker exec postgres-hapi-fhir psql -U admin -d hapi -tAc "SELECT table_name FROM information_schema.columns WHERE column_name='partition_id' AND table_schema='public';")
for t in $TABLES; do
  echo "  UPDATE $t..."
  docker exec postgres-hapi-fhir psql -U admin -d hapi -c "UPDATE $t SET partition_id = 0 WHERE partition_id IS NULL;"
done
REMOTE_PARTITION_FIX
    log "  Rilancio reindex per propagare la modifica agli indici..."
    "${SSH_DST[@]}" 'curl -s -X POST "http://localhost:8080/fhir/\$reindex" -H "Content-Type: application/fhir+json" -d "{\"resourceType\":\"Parameters\",\"parameter\":[]}"' >/dev/null
    sleep 15
    SMOKE_TYPE=$(smoke_test_patient "$SMOKE_RES_ID")
    if [[ "$SMOKE_TYPE" == "Patient" ]]; then
      log "  OK dopo riconciliazione: Patient/${SMOKE_RES_ID} ora raggiungibile via REST su TARGET."
    else
      warn "SMOKE TEST ANCORA FALLITO dopo riconciliazione partition_id. Causa non standard, serve indagine manuale su TARGET."
      exit 1
    fi
  fi
else
  warn "Nessuna risorsa Patient su TARGET: smoke test saltato (verifica manualmente con un altro resource type)."
fi

echo ""
echo "==================== RIEPILOGO ===================="
printf "%-20s %-15s %-15s %s\n" "" "SOURCE" "TARGET" "ESITO"
if [[ "$SRC_HAPI_COUNT" == "$DST_HAPI_COUNT" ]]; then HAPI_OK="OK"; else HAPI_OK="MISMATCH !!!"; fi
if [[ "$SRC_KC_COUNT" == "$DST_KC_COUNT" ]]; then KC_OK="OK"; else KC_OK="MISMATCH !!!"; fi
printf "%-20s %-15s %-15s %s\n" "hfj_resource" "$SRC_HAPI_COUNT" "$DST_HAPI_COUNT" "$HAPI_OK"
printf "%-20s %-15s %-15s %s\n" "user_entity" "$SRC_KC_COUNT" "$DST_KC_COUNT" "$KC_OK"
echo "====================================================="

if [[ "$HAPI_OK" != "OK" || "$KC_OK" != "OK" ]]; then
  warn "Conteggi non coincidono. Verifica log restore su TARGET prima di considerare l'ambiente allineato."
  exit 1
fi

log "Allineamento riuscito. Backup locale in: ${LOCAL_BACKUP_DIR} ($([[ "$KEEP_LOCAL" == true ]] && echo 'conservato' || echo 'verra cancellato ora'))"
