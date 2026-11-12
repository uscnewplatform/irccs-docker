#!/bin/bash
# ==============================================================================
# Validazione formale: rilevamento di una MANOMISSIONE su un AuditEvent gia'
# verificato con successo (domanda auditor #7 / test pre-go-live #3).
#
# Simula il caso di minaccia peggiore realistico: un attore con privilegi di
# superuser sul database di audit (DBA / root dell'host) che
#   1. disabilita i trigger append-only,
#   2. altera il contenuto di un AuditEvent storico (gia' incluso in una full
#      verification riuscita),
#   3. riabilita i trigger per nascondere la traccia.
# Attesa: la verifica FULL della hash-chain rileva la manomissione (mismatch
# dell'hash del record + rottura del puntatore prev del record successivo) ed
# emette AUDIT-INTEGRITY-VIOLATION -> alert Grafana irccs-audit-integrity-tamper.
# La verifica INCREMENTALE NON la rileva (controlla solo il delta di eventi
# nuovi): e' il motivo per cui la full gira comunque ogni ~24h.
#
# LO SCRIPT RIPRISTINA il contenuto originale a fine test. Eseguire SOLO su un
# ambiente non di produzione (pascale-local / staging dedicato).
#
# Uso:
#   ./validate_tamper_detection.sh \
#       --pg-container pascale-local-postgres-hapi-audit \
#       --audit-fhir  http://localhost:8081/fhir \
#       [--token "$BEARER"] [--event-id <id>] [--evidence-dir ./09-tamper-test]
# ==============================================================================
set -euo pipefail

PG_CONTAINER="pascale-local-postgres-hapi-audit"
PG_USER="auditadmin"
PG_DB="hapiaudit"
AUDIT_FHIR="http://localhost:8081/fhir"
TOKEN=""
EVENT_ID=""
EVIDENCE_DIR="./09-tamper-test"
MARKER="[TAMPER-VALIDATION $(date -u +%Y%m%dT%H%M%SZ)]"

while [ $# -gt 0 ]; do
  case "$1" in
    --pg-container) PG_CONTAINER="$2"; shift 2;;
    --pg-user) PG_USER="$2"; shift 2;;
    --pg-db) PG_DB="$2"; shift 2;;
    --audit-fhir) AUDIT_FHIR="$2"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --event-id) EVENT_ID="$2"; shift 2;;
    --evidence-dir) EVIDENCE_DIR="$2"; shift 2;;
    *) echo "argomento sconosciuto: $1" >&2; exit 2;;
  esac
done

mkdir -p "$EVIDENCE_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFY="$SCRIPT_DIR/verify_audit_hash_chain.py"
AUTH_HEADER=()
[ -n "$TOKEN" ] && AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
PSQL="docker exec -i $PG_CONTAINER psql -U $PG_USER -d $PG_DB -tA"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- 0. scegli un evento storico da manomettere -------------------------------
if [ -z "$EVENT_ID" ]; then
  EVENT_ID=$(curl -s "${AUTH_HEADER[@]}" \
    "$AUDIT_FHIR/AuditEvent?_sort=date&_count=1&_offset=50&_elements=id" \
    | python3 -c 'import sys,json;e=json.load(sys.stdin).get("entry",[]);print(e[0]["resource"]["id"] if e else "")')
fi
[ -n "$EVENT_ID" ] || { echo "impossibile determinare un event-id" >&2; exit 1; }
log "evento bersaglio: AuditEvent/$EVENT_ID"

# --- 1. verifica FULL di baseline (deve passare) ------------------------------
log "1/6  verifica FULL di baseline"
python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --full \
  --checkpoint-file "$EVIDENCE_DIR/checkpoint.json" \
  --report-file "$EVIDENCE_DIR/01-baseline-report.json" | tee "$EVIDENCE_DIR/01-baseline.txt"
grep -q "AUDIT-INTEGRITY-OK" "$EVIDENCE_DIR/01-baseline.txt" || {
  echo "BASELINE NON PULITA: interrompo (nessuna manomissione applicata)" >&2; exit 1; }

# --- 2. snapshot del contenuto originale --------------------------------------
log "2/6  snapshot contenuto originale"
ORIG=$($PSQL <<SQL
select res_text_vc from hfj_res_ver
 where res_id=$EVENT_ID and res_type='AuditEvent'
 order by res_ver desc limit 1;
SQL
)
printf '%s' "$ORIG" > "$EVIDENCE_DIR/02-original-content.json"
echo "$ORIG" | grep -q '\[TAMPERED\]' && { echo "il record contiene gia' il marcatore: abortito" >&2; exit 1; }

# --- 3. MANOMISSIONE (bypass trigger) ----------------------------------------
log "3/6  manomissione: disabilito i trigger, altero un detail, riabilito"
$PSQL <<SQL
SET session_replication_role = replica;
UPDATE hfj_res_ver
   SET res_text_vc = regexp_replace(res_text_vc, '("text"\s*:\s*"[^"]{0,80}?)"', '\1 [TAMPERED]"')
 WHERE res_id=$EVENT_ID AND res_type='AuditEvent'
   AND res_ver = (select max(res_ver) from hfj_res_ver where res_id=$EVENT_ID and res_type='AuditEvent');
SET session_replication_role = origin;
SQL
$PSQL <<SQL | grep -q TAMPERED && log "    manomissione applicata" || { echo "manomissione non applicata" >&2; exit 1; }
select case when res_text_vc like '%[TAMPERED]%' then 'TAMPERED' else 'clean' end
 from hfj_res_ver where res_id=$EVENT_ID and res_type='AuditEvent' order by res_ver desc limit 1;
SQL

# --- 4. verifica INCREMENTALE (NON deve rilevare: e' storico) -----------------
log "4/6  verifica INCREMENTALE (attesa: non rileva, evento fuori dal delta)"
set +e
python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --incremental --strict \
  --checkpoint-file "$EVIDENCE_DIR/checkpoint.json" \
  --report-file "$EVIDENCE_DIR/03-incremental-report.json" | tee "$EVIDENCE_DIR/03-incremental.txt"
set -e

# --- 5. verifica FULL (DEVE rilevare) ---------------------------------------
log "5/6  verifica FULL (attesa: AUDIT-INTEGRITY-VIOLATION)"
set +e
python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --full \
  --checkpoint-file "$EVIDENCE_DIR/checkpoint-full.json" \
  --report-file "$EVIDENCE_DIR/04-full-after-tamper-report.json" 2>&1 | tee "$EVIDENCE_DIR/04-full-after-tamper.txt"
DETECTED=$?
set -e
if grep -q "AUDIT-INTEGRITY-VIOLATION\|TAMPER-VIOLATION\|CHAIN-BREAK" "$EVIDENCE_DIR/04-full-after-tamper.txt"; then
  log "    RILEVATA (atteso)"
  RESULT="PASS"
else
  log "    NON rilevata (FALLIMENTO del test)"
  RESULT="FAIL"
fi

# --- 6. RIPRISTINO del contenuto originale ----------------------------------
log "6/6  ripristino contenuto originale"
python3 - "$PG_CONTAINER" "$PG_USER" "$PG_DB" "$EVENT_ID" "$EVIDENCE_DIR/02-original-content.json" <<'PY'
import subprocess, sys
container, user, db, eid, path = sys.argv[1:6]
orig = open(path, "r", encoding="utf-8").read()
# passa il contenuto via stdin come parametro per evitare problemi di quoting
sql = ("SET session_replication_role = replica;\n"
       "UPDATE hfj_res_ver SET res_text_vc = :c "
       f"WHERE res_id={eid} AND res_type='AuditEvent' "
       f"AND res_ver = (select max(res_ver) from hfj_res_ver where res_id={eid} and res_type='AuditEvent');\n"
       "SET session_replication_role = origin;\n")
p = subprocess.run(["docker","exec","-i",container,"psql","-U",user,"-d",db,
                    "-v", "c=" + orig.replace("'", "''"), "-c",
                    sql.replace(":c", "'" + orig.replace("'", "''") + "'")],
                   capture_output=True, text=True)
print(p.stdout.strip() or p.stderr.strip())
PY
RESTORED=$($PSQL <<SQL
select case when res_text_vc like '%[TAMPERED]%' then 'STILL-TAMPERED' else 'restored' end
 from hfj_res_ver where res_id=$EVENT_ID and res_type='AuditEvent' order by res_ver desc limit 1;
SQL
)
log "    stato record: $RESTORED"

# --- verifica finale: catena di nuovo integra dopo il ripristino -------------
python3 "$VERIFY" --audit-fhir "$AUDIT_FHIR" ${TOKEN:+--token "$TOKEN"} --full \
  --checkpoint-file "$EVIDENCE_DIR/checkpoint-post-restore.json" \
  --report-file "$EVIDENCE_DIR/05-post-restore-report.json" | tee "$EVIDENCE_DIR/05-post-restore.txt" | tail -2

# --- riepilogo -------------------------------------------------------------
cat > "$EVIDENCE_DIR/00-summary.md" <<EOF
# Tamper-detection validation — $MARKER

| Passo | Esito |
|---|---|
| Baseline FULL verify | $(grep -o 'AUDIT-INTEGRITY-OK[^"]*' "$EVIDENCE_DIR/01-baseline.txt" | head -1) |
| Evento manomesso | AuditEvent/$EVENT_ID (detail \`text\` -> "... [TAMPERED]") |
| INCREMENTALE dopo manomissione | $(grep -oE 'AUDIT-INTEGRITY-[A-Z-]+' "$EVIDENCE_DIR/03-incremental.txt" | head -1) — atteso: NON rileva |
| FULL dopo manomissione | $(grep -oE 'AUDIT-INTEGRITY-[A-Z-]+' "$EVIDENCE_DIR/04-full-after-tamper.txt" | head -1) — atteso: VIOLATION |
| Rilevamento | **$RESULT** |
| Ripristino contenuto | $RESTORED |
| FULL post-ripristino | $(grep -oE 'AUDIT-INTEGRITY-[A-Z-]+' "$EVIDENCE_DIR/05-post-restore.txt" | head -1) — atteso: OK |

## Alert atteso
Regola Grafana \`irccs-audit-integrity-tamper\` (uid) — query
\`{container_name="irccs-audit-integrity"} |~ "AUDIT-INTEGRITY-VIOLATION"\`.
In esercizio la VIOLATION arriva dal container di verifica continua entro il
ciclo full successivo (default 24h; su pascale-local ridotto). Per l'evidenza
dell'alert: eseguire questo script mentre il container \`irccs-audit-integrity\`
e' attivo e allegare lo screenshot della regola in stato *Firing* + la riga Loki.

Report macchina: 01..05-*.json in questa cartella.
EOF

echo
cat "$EVIDENCE_DIR/00-summary.md"
[ "$RESULT" = "PASS" ] || exit 1
