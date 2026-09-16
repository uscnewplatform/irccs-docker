#!/usr/bin/env bash
# Test leggero (statico) per gli script di backup: sintassi bash + shellcheck
# (se disponibile) su tutti gli script, validazione YAML/JSON sui file di
# configurazione derivati. NON esercita la logica (nessun mock DB/simulazione
# fallimenti) — vedi backup/README.md "Rischi noti" per il limite di
# copertura. Pensato per essere lanciato manualmente prima di ogni modifica
# e, quando possibile, collegato a un job CI (repo irccs-jenkinsfile).
#
# Uso: backup/scripts/run_tests.sh
# Exit 0 = tutti i controlli passati. Exit != 0 = almeno un controllo fallito.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$BACKUP_DIR")"

FAILED=0
CHECKED=0

echo "=== sintassi bash ==="
for f in "$SCRIPT_DIR"/*.sh; do
  CHECKED=$((CHECKED + 1))
  if bash -n "$f"; then
    echo "OK: $(basename "$f")"
  else
    echo "FAIL: $(basename "$f")" >&2
    FAILED=1
  fi
done

echo
echo "=== shellcheck ==="
if command -v shellcheck >/dev/null 2>&1; then
  for f in "$SCRIPT_DIR"/*.sh; do
    if shellcheck -x "$f"; then
      echo "OK: $(basename "$f")"
    else
      echo "FAIL: $(basename "$f")" >&2
      FAILED=1
    fi
  done
else
  echo "shellcheck non installato, salto (apt/brew install shellcheck per abilitarlo)"
fi

echo
echo "=== YAML/JSON di configurazione ==="
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "import yaml" 2>/dev/null; then
    python3 -c "import yaml; yaml.safe_load(open('$BACKUP_DIR/alerting/backup-rules.yaml')); print('OK: backup-rules.yaml')" \
      || { echo "FAIL: backup-rules.yaml" >&2; FAILED=1; }
  else
    echo "modulo python yaml non disponibile, salto backup-rules.yaml"
  fi
  python3 -c "import json; json.load(open('$REPO_ROOT/monitoring-config/dashboards/irccs-backup.json')); print('OK: irccs-backup.json')" \
    || { echo "FAIL: irccs-backup.json" >&2; FAILED=1; }
else
  echo "python3 non disponibile, salto validazione YAML/JSON"
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "=== run_tests.sh: FALLITO ===" >&2
  exit 1
fi
echo "=== run_tests.sh: tutti i controlli OK ($CHECKED script) ==="
