#!/usr/bin/env bash
# Ripristina i DB di test (keycloak, hapi, hapi-audit se presente) nello stack CI $CI_PROJECT dal dump
# fornito in $DUMP_DIR. Riusa backup/scripts/restore_db.sh. Va lanciato con i soli Postgres
# healthy e PRIMA di avviare Keycloak/HAPI/microservizi.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"
DUMP_DIR="${DUMP_DIR:-/var/jenkins_home/e2e-dump}"
: "${CI_PROJECT:?CI_PROJECT obbligatorio (es. pascale-ci-42)}"

# keycloak e hapi sono obbligatori; hapi-audit.dump e' opzionale: se manca l'audit store
# parte vuoto (i test E2E non dipendono da audit storici).
for f in keycloak.dump hapi.dump; do
  [ -f "$DUMP_DIR/$f" ] || { echo "dump mancante: $DUMP_DIR/$f" >&2; exit 1; }
done
KINDS="keycloak hapi"
DUMPS="keycloak.dump hapi.dump"
if [ -f "$DUMP_DIR/hapi-audit.dump" ]; then
  KINDS="$KINDS hapi-audit"; DUMPS="$DUMPS hapi-audit.dump"
else
  echo "hapi-audit.dump assente: audit store non ripristinato (parte vuoto)" >&2
fi
echo "sha256 dump usati:"; (cd "$DUMP_DIR" && sha256sum $DUMPS)

# Senza container_name i container si chiamano <progetto>-<servizio>-N: risolvere via compose
# e passarli a restore_db.sh tramite le variabili BACKUP_*_CONTAINER che gia' supporta.
cid() {
  docker ps --filter "label=com.docker.compose.project=$CI_PROJECT" \
            --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | head -n1
}
BACKUP_HAPI_CONTAINER="$(cid postgres-hapi-fhir)"
BACKUP_KEYCLOAK_CONTAINER="$(cid postgres-keycloak)"
BACKUP_HAPI_AUDIT_CONTAINER="$(cid postgres-hapi-audit)"
export BACKUP_HAPI_CONTAINER BACKUP_KEYCLOAK_CONTAINER BACKUP_HAPI_AUDIT_CONTAINER
for v in BACKUP_HAPI_CONTAINER BACKUP_KEYCLOAK_CONTAINER BACKUP_HAPI_AUDIT_CONTAINER; do
  [ -n "${!v}" ] || { echo "container Postgres non trovato per $v (progetto $CI_PROJECT)" >&2; exit 1; }
done

# L'immagine Jenkins non ha pg_restore: restore_db.sh lo usa in locale solo per `--list`
# (controllo di sanita' del dump). Shim in testa al PATH che lo esegue nel container Postgres
# (client con la versione del server). Qualsiasi altra invocazione fallisce in modo esplicito.
SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "$SHIM_DIR"' EXIT
cat > "$SHIM_DIR/pg_restore" <<'SHIM'
#!/usr/bin/env bash
if [ "$#" -eq 2 ] && [ "$1" = "--list" ] && [ -f "$2" ]; then
  exec docker exec -i "${SHIM_PG_CONTAINER:?SHIM_PG_CONTAINER non impostato}" pg_restore --list < "$2"
fi
echo "shim pg_restore: invocazione non supportata ($*): solo '--list <file>'" >&2
exit 97
SHIM
chmod +x "$SHIM_DIR/pg_restore"
export PATH="$SHIM_DIR:$PATH"

for kind in $KINDS; do
  case "$kind" in
    keycloak) SHIM_PG_CONTAINER="$BACKUP_KEYCLOAK_CONTAINER" ;;
    hapi) SHIM_PG_CONTAINER="$BACKUP_HAPI_CONTAINER" ;;
    hapi-audit) SHIM_PG_CONTAINER="$BACKUP_HAPI_AUDIT_CONTAINER" ;;
  esac
  export SHIM_PG_CONTAINER
  bash "$STACK_DIR/backup/scripts/restore_db.sh" "$kind" "$DUMP_DIR/$kind.dump" \
    --yes-i-am-sure="$(hostname)"
done
echo "restore dump di test completato"
