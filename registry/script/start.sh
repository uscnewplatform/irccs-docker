#!/bin/sh

COMPONENTPATH=/app/quarkus-run.jar

until [ \
  "$(curl -s -w '%{http_code}' -o /dev/null "http://fhir:8080/fhir/metadata")" \
  -eq 200 ]
do
  echo "I'm waiting for the FHIR Server is up...";
  sleep 5
done


if [ -f "$COMPONENTPATH" ]; then
    echo "Starting service"
    nohup java -jar $COMPONENTPATH &
fi


tail -f /dev/null
