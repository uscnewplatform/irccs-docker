#!/bin/bash
# Crea (idempotente) la partizione logica "AUDIT" su HAPI FHIR, usata da
# AuditPartitionInterceptor per isolare gli AuditEvent dai dati clinici
# (piano rimedio audit trail Fase 1). Va rieseguito ogni volta che il volume
# postgres-hapi-fhir viene ricreato da zero, prima che venga scritto un
# qualunque AuditEvent — altrimenti la prima scrittura fallisce con
# "Partition name \"AUDIT\" is not valid".

if [ -z "$1" ]; then
  echo "Uso: $0 hostname:port (es. localhost:8080)"
  exit 1
fi

HOSTNAME_PORT=$1
FHIR_BASE="http://${HOSTNAME_PORT}/fhir"

EXISTING=$(curl -s "${FHIR_BASE}/\$partition-management-list-partitions" \
  | grep -oE '"valueCode": *"AUDIT"|"valueString": *"AUDIT"')

if [ -n "$EXISTING" ]; then
  echo "Partizione AUDIT gia' presente su ${FHIR_BASE} — nulla da fare."
  exit 0
fi

echo "Creo la partizione AUDIT su ${FHIR_BASE}..."
RESPONSE=$(curl -s -X POST "${FHIR_BASE}/\$partition-management-create-partition" \
  -H "Content-Type: application/fhir+json" \
  -d '{
    "resourceType":"Parameters",
    "parameter":[
      {"name":"id","valueInteger":1},
      {"name":"name","valueString":"AUDIT"},
      {"name":"description","valueString":"Audit trail isolato - piano rimedio GDPR Fase 1 (test locale pascale-local)"}
    ]
  }')

if echo "$RESPONSE" | grep -q '"name"'; then
  echo "Partizione AUDIT creata."
else
  echo "Creazione partizione AUDIT fallita. Risposta HAPI:"
  echo "$RESPONSE"
  exit 1
fi
