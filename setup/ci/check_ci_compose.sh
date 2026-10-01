#!/usr/bin/env bash
# Verifica che l'override CI isoli lo stack: nessun container_name, nessuna porta host,
# reti con nome legato al progetto, e che ogni ex container_name resti raggiungibile come
# alias di rete (httpd e microservizi si chiamano per nome container). Uso: check_ci_compose.sh <env-file>
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ENV_FILE="${1:?uso: check_ci_compose.sh <env-file>}"
export CI_PROJECT="${CI_PROJECT:-pascale-ci-check}"
export CI_CONF_DIR="${CI_CONF_DIR:-/tmp/ci-conf-check}"
mkdir -p "$CI_CONF_DIR"; touch "$CI_CONF_DIR/httpd.conf" "$CI_CONF_DIR/irccs.conf" "$CI_CONF_DIR/zammad.conf" "$CI_CONF_DIR/config.js"
CREATED_ENV=false
if [ ! -f .env ]; then cp "$ENV_FILE" .env; CREATED_ENV=true; fi
trap '[ "$CREATED_ENV" = true ] && rm -f .env' EXIT

BASE="$(docker compose -p "$CI_PROJECT" -f docker-compose.yaml --env-file "$ENV_FILE" config --format json)"
JSON="$(docker compose -p "$CI_PROJECT" -f docker-compose.yaml -f docker-compose.ci.yml \
  --env-file "$ENV_FILE" config --format json)"

fail=0
n=$(echo "$JSON" | jq '[.services[] | select(has("container_name"))] | length')
[ "$n" = 0 ] || { echo "KO: $n servizi con container_name"; fail=1; }
p=$(echo "$JSON" | jq '[.services[] | (.ports // [])[] | select(.published != null)] | length')
[ "$p" = 0 ] || { echo "KO: $p porte pubblicate sull'host"; fail=1; }
for net in irccs irccs-audit-db; do
  name=$(echo "$JSON" | jq -r ".networks[\"$net\"].name")
  case "$name" in "$CI_PROJECT"-*) ;; *) echo "KO: rete $net ha nome '$name'"; fail=1 ;; esac
done
# ogni container_name del base deve essere alias sulla rete irccs (o coincidere col nome servizio)
PAIRS="$(echo "$BASE" | jq -r '.services | to_entries[] | select(.value.container_name) | [.key, .value.container_name] | @tsv')"
[ -n "$PAIRS" ] || { echo "KO: nessun container_name trovato nel base (jq fallito?)"; exit 1; }
while IFS=$'\t' read -r svc cname; do
  [ "$svc" = "$cname" ] && continue
  echo "$JSON" | jq -e --arg s "$svc" --arg c "$cname" \
    '.services[$s].networks.irccs.aliases // [] | index($c) != null' >/dev/null \
    || { echo "KO: $svc senza alias $cname"; fail=1; }
done <<< "$PAIRS"
# dashboard: config.js senza Zammad montato da CI_CONF_DIR (una sola mount su quel target)
n=$(echo "$JSON" | jq --arg d "$CI_CONF_DIR" '[.services["irccs-httpd"].volumes[] | select(.target == "/usr/local/apache2/htdocs/config.js" and .source == ($d + "/config.js"))] | length')
[ "$n" = 1 ] || { echo "KO: config.js del dashboard non montato da CI_CONF_DIR (mount trovate: $n)"; fail=1; }
# Keycloak: niente --import-realm in CI
echo "$JSON" | jq -e '.services["irccs-keycloak"].entrypoint | join(" ") | contains("--import-realm") | not' >/dev/null \
  || { echo "KO: keycloak usa ancora --import-realm"; fail=1; }
[ "$fail" = 0 ] && echo "OK: override CI isolato"
exit "$fail"
