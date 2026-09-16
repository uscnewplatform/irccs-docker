#!/bin/bash
# ==============================================================================
# Validazione formale: BACKUP -> RESTORE -> CONTINUITA' della hash-chain
# (domanda auditor #8 / test pre-go-live #2).
#
# Sequenza:
#   1. pg_dump dello store di audit                         (backup)
#   2. verifica FULL della catena sul dato vivo             (stato noto)
#   3. restore del dump in un DATABASE SCRATCH separato     (non distruttivo)
#   4. confronto conteggi + presenza trigger nel restore
#   5. restart di irccs-hapi-audit                          (re-seed catena)
#   6. scrittura di un AuditEvent dopo il restart
#   7. verifica FULL: la catena continua, NESSUN nuovo fork
#
# Variante DISTRUTTIVA (opzionale, --destructive): droppa e ricrea il DB vivo
# dal dump. Solo su ambiente dedicato. Richiede lo stop di irccs-hapi-audit.
#
# Uso:
#   ./validate_restore_continuity.sh \
#       --pg-container pascale-local-postgres-hapi-audit \
#       --audit-container irccs-hapi-audit \
#       --compose-dir ../../pascale-local \
#       --audit-fhir http://localhost:8081/fhir \
#       --proxy-base http://localhost \
#       [--token "$BEARER"] [--patient Patient/1532] [--evidence-dir ./09-restore-test]
#       [--destructive]
# ==============================================================================
set -euo pipefail

PG_CONTAINER="pascale-local-postgres-hapi-audit"
PG_USER="auditadmin"; PG_DB="hapiaudit"
AUDIT_CONTAINER="irccs-hapi-audit"
COMPOSE_DIR="../../pascale-local"
COMPOSE_FILES="-f docker-compose.yaml -f docker-compose.monitoring.yml"
AUDIT_FHIR="http://localhost:8081/fhir"
PROXY_BASE="http://localhost"
TOKEN=""; PATIENT="Patient/1532"
EVIDENCE_DIR="./09-restore-test"
DESTRUCTIVE=0

# docker compose v2 (plugin) se disponibile, altrimenti docker-compose v1 (legacy).
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --pg-container) PG_CONTAINER="$2"; shift 2;;
    --pg-user) PG_USER="$2"; shift 2;;
    --pg-db) PG_DB="$2"; shift 2;;
    --audit-container) AUDIT_CONTAINER="$2"; shift 2;;
    --compose-dir) COMPOSE_DIR="$2"; shift 2;;
    --audit-fhir) AUDIT_FHIR="$2"; shift 2;;
    --proxy-base) PROXY_BASE="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --patient) PATIENT="$2"; shift 2;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2;;
    --destructive) DESTRUCTIVE=1; shift;;
    *) echo "argomento sconosciuto: $1" >&2; exit 2;;
  esac
done

mkdir -p "$EVIDENCE_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$SCRIPT_DIR/verify_audit_hash_chain.py"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
PSQL="docker exec -i $PG_CONTAINER psql -U $PG_USER -tA"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

fork_count() { grep -oE '[0-9]+ biforcazioni' "$1" 2>/dev/null | grep -oE '^[0-9]+' | head -1 || echo 0; }

# --- 1. backup -------------------------------------------------------------
log "1/7  pg_dump -> $EVIDENCE_DIR/backup-$STAMP.dump"
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" -Fc -f "/tmp/backup-$STAMP.dump"
docker cp "$PG_CONTAINER:/tmp/backup-$STAMP.dump" "$EVIDENCE_DIR/backup-$STAMP.dump"
BK_SHA=$(sha256sum "$EVIDENCE_DIR/backup-$STAMP.dump" | cut -d' ' -f1)
log "     sha256=$BK_SHA"

# --- 2. verifica FULL sul vivo ------------------------------------------
log "2/7  verifica FULL (stato pre-restore)"
set +e
python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --full \
  --checkpoint-file "$EVIDENCE_DIR/cp-pre.json" \
  --report-file "$EVIDENCE_DIR/01-pre-restore-report.json" | tee "$EVIDENCE_DIR/01-pre-restore.txt" | tail -2
set -e
FORKS_PRE=$(fork_count "$EVIDENCE_DIR/01-pre-restore.txt")
LIVE_ROWS=$($PSQL -d "$PG_DB" -c "select count(*) from hfj_resource where res_type='AuditEvent';")
log "     AuditEvent vivi=$LIVE_ROWS  fork storici=$FORKS_PRE"

# --- 3. restore in scratch --------------------------------------------
SCRATCH="audit_restore_$(echo "$STAMP" | tr 'A-Z' 'a-z')"
log "3/7  restore in DB scratch '$SCRATCH'"
$PSQL -d postgres -c "DROP DATABASE IF EXISTS $SCRATCH;" >/dev/null
$PSQL -d postgres -c "CREATE DATABASE $SCRATCH;" >/dev/null
RESTORE_ERR=$(docker exec "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$SCRATCH" --no-owner "/tmp/backup-$STAMP.dump" 2>&1 | grep -ci "error" || true)

# --- 4. confronto -----------------------------------------------------
SCRATCH_ROWS=$($PSQL -d "$SCRATCH" -c "select count(*) from hfj_resource where res_type='AuditEvent';")
TRIGGERS=$($PSQL -d "$SCRATCH" -c "select count(*) from pg_trigger where tgname like 'trg_auditevent%';")
log "4/7  restore: errori=$RESTORE_ERR  righe scratch=$SCRATCH_ROWS (dump precede eventi post-dump)  trigger=$TRIGGERS/4"
$PSQL -d postgres -c "DROP DATABASE $SCRATCH;" >/dev/null

# --- 5. restart hapi-audit -----------------------------------------
log "5/7  restart $AUDIT_CONTAINER"
( cd "$COMPOSE_DIR" && $DC $COMPOSE_FILES restart "$AUDIT_CONTAINER" ) >/dev/null 2>&1 || \
  docker restart "$AUDIT_CONTAINER" >/dev/null
for i in $(seq 1 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$AUDIT_FHIR/metadata")" = "200" ] && { log "     su (${i}x5s)"; break; }
  sleep 5
done
sleep 3
# il re-seed della catena e' lazy: avviene alla prima scrittura (step 6), non al boot

# --- 6. scrittura post-restart --------------------------------------
log "6/7  scrittura AuditEvent dopo il restart"
HTTP=$(curl -s -o "$EVIDENCE_DIR/06-post-restart-write.json" -w '%{http_code}' \
  -X POST "$PROXY_BASE/Consent" "${AUTH[@]}" -H 'Content-Type: application/fhir+json' -d "{
    \"resourceType\":\"Consent\",\"status\":\"active\",
    \"scope\":{\"coding\":[{\"system\":\"http://terminology.hl7.org/CodeSystem/consentscope\",\"code\":\"research\"}]},
    \"category\":[{\"coding\":[{\"system\":\"http://terminology.hl7.org/CodeSystem/consentcategorycodes\",\"code\":\"rsdid\"}]}],
    \"patient\":{\"reference\":\"$PATIENT\"},
    \"policy\":[{\"uri\":\"urn:irccs:consent-study:restore-test\"}],
    \"provision\":{\"type\":\"permit\"}}")
log "     Consent POST -> $HTTP"
sleep 3
SEED=$(docker logs "$AUDIT_CONTAINER" 2>&1 | grep -E "marker=hash-chain-init" | tail -1 || true)
log "     re-seed: ${SEED##*AUDIT-TRAIL }"

# --- 7. verifica FULL post-restart --------------------------------
log "7/7  verifica FULL (post-restart): la catena continua, nessun nuovo fork"
set +e
python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --full \
  --checkpoint-file "$EVIDENCE_DIR/cp-post.json" \
  --report-file "$EVIDENCE_DIR/07-post-restart-report.json" | tee "$EVIDENCE_DIR/07-post-restart.txt" | tail -3
set -e
FORKS_POST=$(fork_count "$EVIDENCE_DIR/07-post-restart.txt")

RESULT="PASS"
grep -q "AUDIT-INTEGRITY-OK" "$EVIDENCE_DIR/07-post-restart.txt" || RESULT="FAIL"
[ "$FORKS_POST" -le "$FORKS_PRE" ] || RESULT="FAIL"

cat > "$EVIDENCE_DIR/00-summary.md" <<EOF
# Backup / Restore / Continuity validation — $STAMP

| Voce | Valore |
|---|---|
| Backup | \`backup-$STAMP.dump\` — sha256 \`$BK_SHA\` |
| AuditEvent nel dato vivo (pre) | $LIVE_ROWS |
| Verifica FULL pre-restore | $(grep -oE 'AUDIT-INTEGRITY-[A-Z-]+' "$EVIDENCE_DIR/01-pre-restore.txt" | head -1) |
| Fork storici pre | $FORKS_PRE |
| Restore in scratch — errori pg_restore | $RESTORE_ERR |
| Restore in scratch — righe AuditEvent | $SCRATCH_ROWS |
| Restore in scratch — trigger append-only | $TRIGGERS / 4 |
| Re-seed dopo restart | \`${SEED##*AUDIT-TRAIL }\` |
| Scrittura post-restart | HTTP $HTTP |
| Verifica FULL post-restart | $(grep -oE 'AUDIT-INTEGRITY-[A-Z-]+' "$EVIDENCE_DIR/07-post-restart.txt" | head -1) |
| Fork storici post | $FORKS_POST |
| **Esito** | **$RESULT** |

Criterio di superamento: dopo restore + restart la verifica FULL torna OK e il
numero di fork storici NON aumenta (il re-seed della catena si aggancia alla
foglia reale, fix \`irccs-common@92abc4e\`). I fork storici pre-esistenti sono
biforcazioni gia' presenti da riavvii precedenti alla fix e sono attese.

Report macchina: 01/07-*.json.
EOF

echo; cat "$EVIDENCE_DIR/00-summary.md"

if [ "$DESTRUCTIVE" = "1" ]; then
  echo
  log "VARIANTE DISTRUTTIVA richiesta: droppo e ricreo $PG_DB dal dump"
  read -r -p "Confermi la distruzione di $PG_DB su $PG_CONTAINER? (scrivi DISTRUGGI) " ans
  [ "$ans" = "DISTRUGGI" ] || { echo "annullato"; exit 0; }
  ( cd "$COMPOSE_DIR" && $DC $COMPOSE_FILES stop "$AUDIT_CONTAINER" ) >/dev/null 2>&1 || docker stop "$AUDIT_CONTAINER"
  $PSQL -d postgres -c "DROP DATABASE $PG_DB;"
  $PSQL -d postgres -c "CREATE DATABASE $PG_DB;"
  docker exec "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$PG_DB" --no-owner "/tmp/backup-$STAMP.dump" 2>&1 | tail -3
  ( cd "$COMPOSE_DIR" && $DC $COMPOSE_FILES start "$AUDIT_CONTAINER" ) >/dev/null 2>&1 || docker start "$AUDIT_CONTAINER"
  for i in $(seq 1 30); do [ "$(curl -s -o /dev/null -w '%{http_code}' "$AUDIT_FHIR/metadata")" = "200" ] && break; sleep 5; done
  python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --full \
    --checkpoint-file "$EVIDENCE_DIR/cp-destructive.json" \
    --report-file "$EVIDENCE_DIR/08-destructive-restore-report.json" | tee "$EVIDENCE_DIR/08-destructive-restore.txt" | tail -3
fi

[ "$RESULT" = "PASS" ] || exit 1
