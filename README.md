Per attivare Keycloak in SSL è necessario:
inserire certificato e chiave tramite volume, e riportarli nel keycloak.conf.
rimuovere lo start-dev dal docker-compose

Momentaneamente inserito in /etc/hosts:

127.0.0.1 keycloak.irccs.infocube.it

per testare keycloak.

Va verificato come impostare l'hostname di Keycloak in funzione delle chiamate che arrivano dai microservizi, altrimenti non è raggiungibile se non fa match l'url chiamato con quello dichiarato nel conf.

Notare che in SSL la porta passa da 9445 a 8443 (inserita nella versione corrente del docker-compose) 

Prerequisiti:

Installare docker
Installare docker-compose
Installare git
Copiare una valida ssh_key per accedere al repository git
Installare openssl openssl-dev openssh


Su un Container Proxmox Alpine v3.22

   1 apk update && apk upgrade
   2 apk add docker docker-compose
   3 rc-service docker up
   4 rc-service docker start
   5 rc-update add docker
   6 mkdir -p /etc/docker
   7 cat > /etc/docker/daemon.json << EOF
   8 {
   9  "log-driver": "json-file",
  10  "log-opts": {
  11     "max-size": "20m",
  12     "max-file": "3"
  13  },
  14  "storage-driver": "vfs"
  15 }
  16 EOF
  17 cat /etc/docker/daemon.json 
  18 rc-service docker restart
  19 apk add git
  20 apk add openssl openssl-dev openssh

Va configurato il repository nexus di infocube in docker:

docker login nexus.infocube.it (chiedere le credenziali)


Per avviare il progetto:


git clone git@github.com:infocube-it/irccs-docker.git
cd irccs-docker
docker-compose up -d

Nel docker compose yaml, in entrypoint sono state inserite comandi per installare le search parameters in hapi fhir. La chiamata viene fatta solo dopo 60 secondi, perche è necessario che HAPI FHIR sia disponibile, ed il check viene fatto tramite chiamata a HAPI FHIR (ogni 15 secondi)
