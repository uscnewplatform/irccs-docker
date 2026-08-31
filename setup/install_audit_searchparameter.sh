#!/bin/bash
# Installa sul server FHIR dell'AUDIT i SearchParameter necessari alla
# consultazione: `entity-identifier` (token su AuditEvent.entity.what.identifier) e
# `agent-identifier` (token su AuditEvent.agent.who.identifier, per filtrare per
# utente - stesso pattern, entrambi Identifier logici urn:internal|... non Reference
# vere, vedi FhirClient.createAuditEvent/AuditTrailService). Vedi install_searchparameters.sh
# per il perche' serve (HAPI v8 non auto-indicizza il .identifier dei search param reference).
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

JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://irccs.pascale.it/SearchParameter/AuditEvent-agent-identifier",
  "name": "agent-identifier",
  "status": "active",
  "description": "Search AuditEvent by the logical identifier of agent.who (utente autore)",
  "code": "agent-identifier",
  "base": ["AuditEvent"],
  "type": "token",
  "expression": "AuditEvent.agent.who.identifier"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
  -H "Content-Type: application/json" -d "$JSON_BODY"
echo

# Varianti "string" degli stessi due campi, per il match PARZIALE (:contains) nella
# vista admin /audit-trail - i token sopra restano exact-match, usati da
# AuditTrailDialog (lookup preciso su una risorsa). Un search param FHIR di tipo
# token non supporta :contains per spec; string si', quindi due SearchParameter
# separati sullo stesso path invece di uno solo con doppio comportamento. Richiede
# allow_contains_searches: true (hapi-audit-config/application.yaml).
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://irccs.pascale.it/SearchParameter/AuditEvent-entity-identifier-text",
  "name": "entity-identifier-text",
  "status": "active",
  "description": "Search AuditEvent by a partial match on the entity.what identifier value (es. solo \"Patient\" senza id)",
  "code": "entity-identifier-text",
  "base": ["AuditEvent"],
  "type": "string",
  "expression": "AuditEvent.entity.what.identifier.value"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
  -H "Content-Type: application/json" -d "$JSON_BODY"
echo

JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://irccs.pascale.it/SearchParameter/AuditEvent-agent-identifier-text",
  "name": "agent-identifier-text",
  "status": "active",
  "description": "Search AuditEvent by a partial match on the agent.who identifier value (username/email)",
  "code": "agent-identifier-text",
  "base": ["AuditEvent"],
  "type": "string",
  "expression": "AuditEvent.agent.who.identifier.value"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
  -H "Content-Type: application/json" -d "$JSON_BODY"
echo
