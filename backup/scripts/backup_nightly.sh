#!/usr/bin/env bash
# Entrypoint del container backup (vedi ../Dockerfile), lanciato ogni notte
# da systemd timer via scripts/run_backup_container.sh sull'host.
# Pipeline: dump -> verify -> encrypt+offsite -> retention.
# Se verify fallisce su un dump, quel dump NON viene cifrato ne' ruotato:
# resta in staging/ per analisi manuale e lo script esce con errore (per l'alert).
#
# Le variabili d'ambiente (credenziali DB + config backup) arrivano gia'
# iniettate da `docker run --env-file` (vedi run_backup_container.sh): qui non
# si fa piu' alcun sourcing di file .env.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

require_env BACKUP_ROOT

log_info "=== backup notturno avviato ==="

mapfile -t DUMPS < <("$SCRIPT_DIR/backup_db.sh")
HAPI_DUMP="${DUMPS[0]}"
KEYCLOAK_DUMP="${DUMPS[1]}"

FAILED=0

for entry in "hapi:$HAPI_DUMP" "keycloak:$KEYCLOAK_DUMP"; do
  kind="${entry%%:*}"
  dump="${entry#*:}"

  if "$SCRIPT_DIR/verify_restore.sh" "$kind" "$dump"; then
    "$SCRIPT_DIR/encrypt_and_offsite.sh" "$kind" "$dump"
    "$SCRIPT_DIR/retention_cleanup.sh" "$kind"
  else
    log_error "verify fallita per $kind, dump conservato in staging per analisi: $dump"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  die "backup notturno completato CON ERRORI: vedere log sopra"
fi

log_info "=== backup notturno completato con successo ==="
