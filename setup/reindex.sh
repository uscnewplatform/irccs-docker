#!/bin/bash
# One-time reindex trigger for HAPI FHIR.
#
# Needed after installing new SearchParameters (see install_searchparameters.sh)
# when resources already exist that predate them - HAPI only auto-indexes on
# save, so pre-existing resources stay invisible to the new search params until
# reindexed. Safe to re-run (idempotent, just re-walks all resources).
#
# Fa DUE cose, entrambe necessarie in questa istanza:
#
#   1. $reindex batch2 - ricostruisce gli indici JPA (HFJ_SPIDX_*). Job async,
#      ritorna subito con un jobId.
#
#   2. $mark-all-resources-for-reindexing + N x $perform-reindexing-pass -
#      reindicizzazione "legacy" sincrona che ricostruisce ANCHE l'indice
#      full-text Hibernate Search / Lucene. Con `advanced_lucene_indexing: true`
#      in application.yaml le ricerche token vengono servite da Lucene, e il solo
#      $reindex batch2 NON aggiorna quell'indice per le risorse preesistenti
#      (il SearchParameter risulta indicizzato in Postgres ma la search torna
#      comunque risultati parziali). Verificato su HAPI v8.0.0 in pascale-local.
#
# Nota partizioni: se e' montato AuditPartitionInterceptor (audit trail Fase 1),
# assicurarsi di avere la versione che ritorna allPartitions() per le letture
# senza tipo, altrimenti il $reindex degli AuditEvent processa 0 record.

if [ -z "$1" ]; then
  echo "Usage: $0 hostname:port"
  exit 1
fi

HOSTNAME_PORT=$1
BASE="http://$HOSTNAME_PORT/fhir"
PASSES=${2:-10}

echo "1) \$reindex batch2 (indici JPA)..."
curl -s -X POST "$BASE/\$reindex" \
      -H "Content-Type: application/fhir+json" \
      -d '{"resourceType":"Parameters","parameter":[]}'
echo

echo "2) reindicizzazione legacy (indice full-text Lucene)..."
curl -s -X POST "$BASE/\$mark-all-resources-for-reindexing" -o /dev/null -w "   mark-all -> %{http_code}\n"
for i in $(seq 1 "$PASSES"); do
  curl -s -X POST "$BASE/\$perform-reindexing-pass" -o /dev/null -w "   pass $i -> %{http_code}\n"
  sleep 2
done
echo "Fatto. Ripetere se il dataset e' grande (ogni pass processa un batch limitato)."
