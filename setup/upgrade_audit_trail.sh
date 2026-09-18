#!/usr/bin/env bash
# ==============================================================================
# Upgrade in-place dell'audit trail su uno stack irccs-docker ESISTENTE, con dati
# reali. Orchestra gli script idempotenti gia' presenti in setup/ nell'ordine
# corretto, con conferma esplicita prima di ogni passo che tocca container o dati
# in esecuzione. Pensato per un ambiente di laboratorio/staging che ha gia' lo
# stack su una versione precedente (con o senza lo store audit separato) e va
# portato alla versione corrente (segmentazione rete irccs-audit-db, backup WORM
# hapi-audit, riconciliazione orfani verify_audit_coverage.py - vedi
# docs/modules/ROOT/pages/audit-trail.adoc per il dettaglio di ciascun pezzo).
#
# NON fa: git pull, build delle immagini, restore/rollback. Il codice aggiornato
# (immagini Docker con i fix di irccs-common/auth/zammad, e questo stesso
# docker-compose.yaml) deve essere gia' presente sull'host PRIMA di lanciare
# questo script - vedi la checklist "Attivazione (deploy)" in audit-trail.adoc.
#
# Uso:
#   cd irccs-docker
#   ./setup/upgrade_audit_trail.sh                 # interattivo, chiede conferma
#   ./setup/upgrade_audit_trail.sh --yes            # non interattivo (automazione)
#   ./setup/upgrade_audit_trail.sh --skip-migration # salta il passo di migrazione storici
#
# Idempotente nel suo complesso: rieseguirlo dopo un'interruzione (Ctrl+C, errore)
# riprende senza duplicare nulla - ogni script sottostante lo e' gia' singolarmente.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

CLINICAL_HOST="${AUDIT_UPGRADE_CLINICAL_HOST:-127.0.0.1:8080}"
AUDIT_HOST="${AUDIT_UPGRADE_AUDIT_HOST:-127.0.0.1:8081}"
AUTO_YES=false
SKIP_MIGRATION=false

for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    --skip-migration) SKIP_MIGRATION=true ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Argomento sconosciuto: $arg (vedi --help)" >&2; exit 2 ;;
  esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[upgrade-audit]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[FALLITO]${NC} $*"; exit 1; }

confirm() {
  local prompt="$1"
  if [ "$AUTO_YES" = true ]; then
    return 0
  fi
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

step() { echo ""; echo -e "${CYAN}=== $* ===${NC}"; }

# ---- 0. Preflight ------------------------------------------------------------
step "0/8 Preflight"

command -v docker >/dev/null 2>&1 || fail "docker non trovato nel PATH"
# docker compose v2 (plugin) se disponibile, altrimenti docker-compose v1 (legacy) -
# alcuni host hanno solo uno dei due installato. v1 con immagini BuildKit ha un bug
# noto (KeyError 'ContainerConfig' sul recreate) - preferire v2 quando c'e'.
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
  warn "docker compose v2 non trovato, uso docker-compose v1 (legacy) - se il recreate"
  warn "fallisce con 'ContainerConfig', vedi audit-trail.adoc per il workaround."
else
  fail "ne' 'docker compose' (v2) ne' 'docker-compose' (v1) disponibili"
fi
[ -f "$PROJECT_ROOT/.env" ] || fail ".env non trovato in $PROJECT_ROOT (richiesto da $DC)"
[ -f "$PROJECT_ROOT/docker-compose.yaml" ] || fail "docker-compose.yaml non trovato — sei nella directory giusta?"

if ! grep -q "^HAPI_AUDIT_DB_" "$PROJECT_ROOT/.env" 2>/dev/null; then
  fail "HAPI_AUDIT_DB_USER/PASSWORD/NAME non trovate in .env — vedi audit-trail.adoc §Attivazione prima di continuare"
fi

ok "docker/.env/docker-compose.yaml presenti"

# ---- 1. Ricrea lo stack con la config aggiornata ------------------------------
step "1/8 Ricrea i container con docker-compose.yaml aggiornato"

warn "Questo passo recrea i container il cui config e' cambiato (rete irccs-audit-db,"
warn "nuove variabili d'ambiente). I container INVARIATI non vengono toccati. Downtime"
warn "atteso: solo per i container ricreati, tipicamente pochi secondi ciascuno."
if ! confirm "Procedere con '$DC up -d'?"; then
  fail "Annullato dall'operatore prima di ricreare i container"
fi

$DC up -d
ok "$DC up -d completato"

log "Attendo che postgres-hapi-audit e irccs-hapi-audit siano pronti..."
for i in $(seq 1 30); do
  if $DC ps postgres-hapi-audit 2>/dev/null | grep -q "Up\|running" \
     && curl -sf "http://$AUDIT_HOST/fhir/metadata" >/dev/null 2>&1; then
    ok "irccs-hapi-audit risponde su http://$AUDIT_HOST/fhir"
    break
  fi
  [ "$i" -eq 30 ] && fail "irccs-hapi-audit non risponde dopo 30 tentativi (150s) — controllare '$DC logs irccs-hapi-audit'"
  sleep 5
done

# ---- 2. Verifica rete di isolamento -------------------------------------------
step "2/8 Verifica segmentazione di rete"

AUDIT_NET_CONTAINERS="$(docker network inspect irccs-audit-db --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
if [ -z "$AUDIT_NET_CONTAINERS" ]; then
  warn "rete irccs-audit-db non trovata o vuota — atteso solo su docker-compose.yaml aggiornato (vedi step 1)"
else
  ok "rete irccs-audit-db: $AUDIT_NET_CONTAINERS"
  UNEXPECTED="$(echo "$AUDIT_NET_CONTAINERS" | tr ' ' '\n' | grep -v -E "postgres-hapi-audit|hapi-audit|^$" || true)"
  if [ -n "$UNEXPECTED" ]; then
    warn "container inattesi sulla rete audit: $UNEXPECTED — verificare manualmente"
  fi
fi

# ---- 3. Partizione AUDIT sull'istanza clinica ---------------------------------
step "3/8 Partizione AUDIT (istanza clinica)"
bash "$SCRIPT_DIR/setup_audit_partition.sh" "$CLINICAL_HOST" \
  && ok "partizione AUDIT ok su $CLINICAL_HOST" \
  || fail "setup_audit_partition.sh fallito"

# ---- 4. SearchParameter sull'istanza audit ------------------------------------
step "4/8 SearchParameter entity-identifier/agent-identifier (istanza audit)"
bash "$SCRIPT_DIR/install_audit_searchparameter.sh" "$AUDIT_HOST" \
  && ok "SearchParameter installati su $AUDIT_HOST" \
  || fail "install_audit_searchparameter.sh fallito"

# ---- 5. Trigger DB di immodificabilita' ---------------------------------------
step "5/8 Trigger Postgres di immodificabilita' (istanza audit)"
bash "$SCRIPT_DIR/install_audit_db_protection.sh" \
  && ok "trigger installati su postgres-hapi-audit" \
  || fail "install_audit_db_protection.sh fallito"

# ---- 6. pgaudit ----------------------------------------------------------------
step "6/8 Estensione pgaudit (istanza audit)"
if bash "$SCRIPT_DIR/install_audit_pgaudit.sh"; then
  ok "pgaudit attiva su postgres-hapi-audit"
else
  warn "install_audit_pgaudit.sh fallito — probabile immagine postgres-hapi-audit non ancora ricostruita"
  warn "con postgres-audit-image/ (serve shared_preload_libraries=pgaudit all'avvio)."
  warn "Rieseguire dopo: docker compose up -d --build postgres-hapi-audit"
fi

# ---- 7. Migrazione storici (se presenti) --------------------------------------
step "7/8 Migrazione AuditEvent storici verso lo store dedicato"
if [ "$SKIP_MIGRATION" = true ]; then
  warn "saltato (--skip-migration)"
else
  log "Verifico se ci sono AuditEvent storici ancora sull'istanza clinica..."
  HISTORIC_COUNT="$(curl -s "http://$CLINICAL_HOST/fhir/AuditEvent?_summary=count&_total=accurate" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")"

  if [ "$HISTORIC_COUNT" = "0" ]; then
    ok "nessun AuditEvent storico sull'istanza clinica — nulla da migrare"
  elif [ "$HISTORIC_COUNT" = "?" ]; then
    warn "impossibile determinare il conteggio storico su $CLINICAL_HOST — saltare o investigare manualmente"
  else
    warn "$HISTORIC_COUNT AuditEvent trovati sull'istanza clinica (pre-separazione)."
    log "Dry-run della migrazione (nessuna scrittura)..."
    python3 "$SCRIPT_DIR/migrate_auditevents_to_audit_store.py" \
      --source-url "http://$CLINICAL_HOST/fhir" --target-url "http://$AUDIT_HOST/fhir" --dry-run
    echo ""
    warn "Se lo store di destinazione NON e' vuoto (microservizi separati gia' in esercizio),"
    warn "serve --allow-nonempty: gli storici finiscono in coda alla catena esistente."
    if confirm "Eseguire ORA la migrazione reale (POST verso $AUDIT_HOST)?"; then
      TARGET_COUNT="$(curl -s "http://$AUDIT_HOST/fhir/AuditEvent?_summary=count&_total=accurate" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")"
      EXTRA_FLAG=""
      if [ "$TARGET_COUNT" != "0" ]; then
        warn "store destinazione non vuoto ($TARGET_COUNT eventi) — uso --allow-nonempty"
        EXTRA_FLAG="--allow-nonempty"
      fi
      python3 "$SCRIPT_DIR/migrate_auditevents_to_audit_store.py" \
        --source-url "http://$CLINICAL_HOST/fhir" --target-url "http://$AUDIT_HOST/fhir" $EXTRA_FLAG \
        && ok "migrazione completata (idempotente via checkpoint, --resume se interrotta)" \
        || fail "migrazione fallita — rilanciare con --resume dopo aver investigato i log sopra"
    else
      warn "migrazione rimandata — rilanciare in seguito: python3 setup/migrate_auditevents_to_audit_store.py --source-url http://$CLINICAL_HOST/fhir --target-url http://$AUDIT_HOST/fhir"
    fi
  fi
fi

# ---- 8. Verifica finale ---------------------------------------------------------
step "8/8 Verifica hash-chain e copertura orfani"

log "verify_audit_hash_chain.py --full (una tantum, il container irccs-audit-integrity la ripete in loop)..."
python3 "$SCRIPT_DIR/verify_audit_hash_chain.py" --audit-fhir "http://$AUDIT_HOST/fhir" --full \
  && ok "hash-chain integra" \
  || warn "verify_audit_hash_chain.py ha segnalato un'anomalia — vedi output sopra prima di considerare l'upgrade concluso"

log "verify_audit_coverage.py (riconciliazione orfani, lookback 30gg)..."
python3 "$SCRIPT_DIR/verify_audit_coverage.py" \
  --clinical-fhir "http://$CLINICAL_HOST/fhir" --audit-fhir "http://$AUDIT_HOST/fhir" \
  --reset-checkpoint --lookback-days 30 \
  && ok "nessuna risorsa critica orfana negli ultimi 30 giorni" \
  || warn "verify_audit_coverage.py ha segnalato orfani — vedi output sopra"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Upgrade audit trail completato${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Checklist manuale residua (non automatizzabile da questo script):"
echo "  - backup/.env.backup: impostare BACKUP_AUDIT_RETENTION_YEARS (default 25 se assente)"
echo "  - verificare che TUTTI i microservice-config-*/application.properties abbiano"
echo "    org.quarkus.irccs.audit-fhir-server impostato (altrimenti il prossimo restart"
echo "    fallisce per il fail-fast di isolamento — vedi audit-trail.adoc)"
echo "  - se il backup e' gia' schedulato, il prossimo giro applica da solo la nuova"
echo "    retention WORM-like su hapi-audit (nessuna azione retroattiva necessaria)"
echo "  - rivedere il log di questo script per eventuali [!] non risolti sopra"
