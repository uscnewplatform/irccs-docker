#!/bin/bash
# One-time $reindex trigger for HAPI FHIR.
#
# Needed after installing new SearchParameters (see install_searchparameters.sh)
# when resources already exist that predate them - HAPI only auto-indexes on
# save, so pre-existing resources stay invisible to the new search params until
# reindexed. Safe to re-run (idempotent, just re-walks all resources).
#
# Kicks off an async batch job and returns immediately with a jobId; check
# progress via GET [base]/$reindex-job-status?jobId=... or the HAPI admin UI.

if [ -z "$1" ]; then
  echo "Usage: $0 hostname:port"
  exit 1
fi

HOSTNAME_PORT=$1

curl -s -X POST "http://$HOSTNAME_PORT/fhir/\$reindex" \
      -H "Content-Type: application/fhir+json" \
      -d '{"resourceType":"Parameters","parameter":[]}'
echo
