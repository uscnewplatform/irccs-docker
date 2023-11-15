#!/bin/sh

AUTHPATH=/home/irccs-auth-service/quarkus-run.jar
CTCPATH=/home/irccs-ctcae-service/quarkus-run.jar
PATIENTPATH=/home/irccs-microservice-anagrafica-pazienti/quarkus-run.jar
CENTRORICERCAPATH=/home/irccs-microservice-centro-ricerca/quarkus-run.jar
STUDIOCLINICOPATH=/home/irccs-microservice-studio-clinico/quarkus-run.jar

if [ -f "$AUTHPATH" ]; then
    echo "Starting auth service"
    nohup java -jar $AUTHPATH &
fi

if [ -f "$CTCPATH" ]; then
  echo "Starting ctcae service"
  nohup java -jar $CTCPATH &
fi


if [ -f "$PATIENTPATH" ]; then
  echo "Starting anagrafica pazienti"
  nohup java -jar $PATIENTPATH &
fi

if [ -f "$CENTRORICERCAPATH" ]; then
  echo "Starting centro ricerca"
  nohup java -jar $CENTRORICERCAPATH &
fi

if [ -f "$STUDIOCLINICOPATH" ]; then
  echo "Starting studio clinico"
  nohup java -jar $STUDIOCLINICOPATH &
fi

tail -f /dev/null