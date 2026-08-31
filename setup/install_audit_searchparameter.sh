#!/bin/bash
# Installa sul server FHIR dell'AUDIT i SearchParameter necessari alla
# consultazione: `entity-identifier` (token su AuditEvent.entity.what.identifier) e
# `agent-identifier` (token su AuditEvent.agent.who.identifier, per filtrare per
# utente - stesso pattern, entrambi Identifier logici urn:internal|... non Reference
# vere, vedi FhirClient.createAuditEvent/AuditTrailService), piu' le varianti string
# entity-identifier-text/agent-identifier-text per il match parziale (:contains,
# richiede allow_contains_searches: true - vedi hapi-audit-config/application.yaml).
# Vedi install_searchparameters.sh per il perche' serve il SearchParameter esplicito
# (HAPI v8 non auto-indicizza il .identifier dei search param reference).
#
# Idempotente: usa PUT condizionale su `url` (create-or-update), non POST - rieseguire
# lo script non crea duplicati.
#
# Uso: ./install_audit_searchparameter.sh <host>:<port>
#   es. ./install_audit_searchparameter.sh 127.0.0.1:8081
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Uso: $0 hostname:port (es. 127.0.0.1:8081)" >&2
  exit 1
fi
HOSTNAME_PORT="$1"

put_search_param() {
  local url="$1" body="$2"
  curl -s -X PUT "http://$HOSTNAME_PORT/fhir/SearchParameter?url=$url" \
    -H "Content-Type: application/json" -d "$body"
  echo
}

put_search_param "http://irccs.pascale.it/SearchParameter/AuditEvent-entity-identifier" "$(cat <<'EOF'
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
)"

put_search_param "http://irccs.pascale.it/SearchParameter/AuditEvent-agent-identifier" "$(cat <<'EOF'
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
)"

# Varianti "string" degli stessi due campi, per il match PARZIALE (:contains) nella
# vista admin /audit-trail - i token sopra restano exact-match, usati da
# AuditTrailDialog (lookup preciso su una risorsa). Un search param FHIR di tipo
# token non supporta :contains per spec; string si', quindi due SearchParameter
# separati sullo stesso path invece di uno solo con doppio comportamento.
put_search_param "http://irccs.pascale.it/SearchParameter/AuditEvent-entity-identifier-text" "$(cat <<'EOF'
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
)"

put_search_param "http://irccs.pascale.it/SearchParameter/AuditEvent-agent-identifier-text" "$(cat <<'EOF'
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
)"
