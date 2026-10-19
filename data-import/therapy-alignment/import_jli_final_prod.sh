#!/usr/bin/env bash
# Importa "JLI Final" (copia di J-LI NEW 32130) su PRODUZIONE passando dal proxy autenticato.
# Uso:  IRCCS_USER=... IRCCS_PASSWORD=... bash import_jli_final_prod.sh [--apply]
# Senza --apply fa solo il dry-run (bundle + report, nulla scritto). Gruppo/org: Admins Istituto Tumori (5579).
set -euo pipefail
HOST=pj.istitutotumori.na.it
SETUP="$(cd "$(dirname "$0")/../../../../git/pascale-local/setup" 2>/dev/null && pwd || echo "$HOME/Scrivania/sviluppo/IRCCS/git/pascale-local/setup")"
OUT="${OUT:-$HOME/Scrivania/sviluppo/IRCCS/backup-fhir/2026-10-10-jli-final-prod-import}"
: "${IRCCS_USER:?serve IRCCS_USER}" "${IRCCS_PASSWORD:?serve IRCCS_PASSWORD}"
TOKEN=$(python3 - <<'PY'
import json, os, urllib.parse, urllib.request
b = urllib.parse.urlencode({"grant_type": "password", "scope": "openid",
                            "username": os.environ["IRCCS_USER"], "password": os.environ["IRCCS_PASSWORD"]}).encode()
r = urllib.request.urlopen(urllib.request.Request("https://pj.istitutotumori.na.it/auth/users/token", b), timeout=30)
print(json.load(r)["access_token"])
PY
)
APPLY=""
[ "${1:-}" = "--apply" ] && APPLY="--apply --conferma-host $HOST"
mkdir -p "$OUT"
IRCCS_THROTTLE=0.2 IRCCS_TOKEN="$TOKEN" python3 "$SETUP/merge_studies_newest.py" \
  --a 32130 --b 32130 --title "JLI Final" --includi Questionnaire/15025 \
  --hapi "https://$HOST" --import-url "https://$HOST/Bundle/import" \
  --scope 1689f3a0-22d6-4e97-ade8-034753fe23c4 --organization-id 5579 \
  $APPLY --out "$OUT"
