#!/bin/sh

# Path config
AUTHPATH=/home/irccs-auth-service/quarkus-run.jar
CTCPATH=/home/irccs-ctcae-service/quarkus-run.jar
PATIENTPATH=/home/irccs-microservice-anagrafica-pazienti/quarkus-run.jar
CENTRORICERCAPATH=/home/irccs-microservice-centro-ricerca/quarkus-run.jar
STUDIOCLINICOPATH=/home/irccs-microservice-studio-clinico/quarkus-run.jar
PRACTITIONERPATH=/home/irccs-microservice-practitioner/quarkus-run.jar


until [ \
  "$(curl -s -w '%{http_code}' -o /dev/null "http://fhir-server:8080/fhir/metadata")" \
  -eq 200 ]
do
  echo "I'm waiting for the FHIR Server is up...";
  sleep 5
done


if [ -f "$AUTHPATH" ]; then
    echo "Starting Auth service"
    nohup java -jar $AUTHPATH &
fi

if [ -f "$CTCPATH" ]; then
  echo "Starting Ctcae service"
  nohup java -jar $CTCPATH &
fi


if [ -f "$PATIENTPATH" ]; then
  echo "Starting Anagrafica pazienti"
  nohup java -jar $PATIENTPATH &
fi

if [ -f "$CENTRORICERCAPATH" ]; then
  echo "Starting Centro ricerca"
  nohup java -jar $CENTRORICERCAPATH &
fi

if [ -f "$STUDIOCLINICOPATH" ]; then
  echo "Starting Studio clinico"
  nohup java -jar $STUDIOCLINICOPATH &
fi


if [ -f "$PRACTITIONERPATH" ]; then
  echo "Starting Practitioner"
  nohup java -jar $PRACTITIONERPATH &
fi

tail -f /dev/null