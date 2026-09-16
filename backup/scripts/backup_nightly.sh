#!/usr/bin/env bash
# Entrypoint del container di backup (vedi ../Dockerfile). Fa SOLO cifratura
# (age) + push offsite (rclone) + retention sui dump gia' verificati — dump
# (backup_db.sh) e verify (verify_restore.sh) girano PRIMA di questo container,
# sull'host, orchestrati da run_backup_container.sh (che passa qui l'elenco
# dei dump gia' verificati con successo via VERIFIED_DBS).
#
# Questo container non ha e non deve avere alcun accesso alla Docker API:
# nessun socket, nessun proxy, nessun docker-cli nell'immagine — vedi il
# commento in run_backup_container.sh per il perche' (escape verificato
# empiricamente attraverso un giro precedente che instradava dump+verify
# qui dentro via un docker-socket-proxy a permessi ridotti).
#
# Le variabili d'ambiente (credenziali DB + config backup) arrivano gia'
# iniettate da `docker run --env-file` (vedi run_backup_container.sh): qui non
# si fa piu' alcun sourcing di file .env.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# shellcheck source=./lib_common.sh
source "$SCRIPT_DIR/lib_common.sh"

# Rete di sicurezza: un comando non avvolto in if/||true che fallisce sotto
# `set -e` termina lo script senza passare da log_error — vedi lo stesso
# trap e spiegazione in run_backup_container.sh.
set -E
trap 'log_error "crash inatteso alla linea $LINENO (comando: $BASH_COMMAND)"' ERR

require_env VERIFIED_DBS

FAILED=0

IFS=',' read -ra ENTRIES <<< "$VERIFIED_DBS"
for entry in "${ENTRIES[@]}"; do
  kind="${entry%%:*}"
  dump="${entry#*:}"

  if "$SCRIPT_DIR/encrypt_and_offsite.sh" "$kind" "$dump"; then
    "$SCRIPT_DIR/retention_cleanup.sh" "$kind"
  else
    log_error "cifratura/offsite fallita per $kind, dump=$dump"
    FAILED=1
  fi
done

exit "$FAILED"
