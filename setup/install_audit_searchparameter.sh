#!/bin/bash
# Installa sul server FHIR dell'AUDIT il solo SearchParameter necessario alla
# consultazione: `entity-identifier` (token su AuditEvent.entity.what.identifier).
# Vedi install_searchparameters.sh per il perche' serve (HAPI v8 non auto-indicizza
# il .identifier dei search param reference).
#
# Uso: ./install_audit_searchparameter.sh <host>:<port>
#   es. ./install_audit_searchparameter.sh 127.0.0.1:8081
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Uso: $0 hostname:port (es. 127.0.0.1:8081)" >&2
  exit 1
fi
HOSTNAME_PORT="$1"

JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://irccs.pascale.it/SearchParameter/AuditEvent-entity-identifier",
  "name": "entity-identifier",
  "status": "active",
  "description": "Search AuditEvent by the logical identifier of entity.what",
  "code": "entity-identifier",
  "base": ["AuditEvent"],
  "type": "token",
  "expression": "AuditEvent.entity.what.identifier"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
  -H "Content-Type: application/json" -d "$JSON_BODY"
echo
