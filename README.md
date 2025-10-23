Introduzione.
La presente guida si pone l'obiettivo di semplificare la prima installazione del portale
su una nuova piattaforma


Prerequisiti:

Installare docker
Installare docker-compose
Installare git
Copiare una valida ssh_key per accedere al repository git
Installare openssl openssl-dev openssh

I seguenti passi sono necessari solo per installazioni su Proxmox
Su un Container Proxmox Alpine v3.22
Va configurato il repository nexus di infocube in docker: 
 - docker login nexus.infocube.it (chiedere le credenziali)


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




Per avviare il progetto:

```
git clone git@github.com:infocube-it/irccs-docker.git
cd irccs-docker
cp .env_example .env
# Modifica .env e imposta valori sicuri per tutte le variabili richieste
# (non committare il file .env)
docker-compose up -d
```

### Variabili d'ambiente richieste (.env)
- **KEYCLOAK_ADMIN**, **KEYCLOAK_ADMIN_PASSWORD**
- **KEYCLOAK_CLIENT_ID**, **KEYCLOAK_CLIENT_SECRET**, **KEYCLOAK_REALM**
- **POSTGRES_KEYCLOAK_PASSWORD**
- **HAPI_DB_USER**, **HAPI_DB_PASSWORD**
- **REDIS_PASSWORD**
- **JWT_SECRET** (genera un valore robusto, ad es.: `openssl rand -hex 64`)

### Sicurezza
- **Non committare** `.env` (è già in `.gitignore`).
- Se credenziali sono state già pubblicate, **ruotale immediatamente** (Keycloak admin, client secret, Postgres, Redis, JWT).
- Valuta la **pulizia della storia git** per rimuovere segreti esposti (BFG o `git filter-repo`).



Una volta avviato dovremo passare alla configurazione:

A) Set up user and password keycloak admin
   Select new user from menu and add to super admin
   Remove predefined user
 
B) Reset Passwork irccs admin
   Select new user from menu and add to super admin
   Remove predefined user
C) Set Mail mail server
    Set the mail server and mail address to change password 
Nel docker compose yaml, in entrypoint sono state inserite comandi per installare le search parameters in hapi fhir. La chiamata viene fatta solo dopo 60 secondi, perche è necessario che HAPI FHIR sia disponibile, ed il check viene fatto tramite chiamata a HAPI FHIR (ogni 15 secondi)




---configurare smtp in keycloak da ADMIN

NOTE:

Per attivare Keycloak in SSL è necessario:
inserire certificato e chiave tramite volume, e riportarli nel keycloak.conf.
rimuovere lo start-dev dal docker-compose

Momentaneamente inserito in /etc/hosts:

127.0.0.1 keycloak.irccs.infocube.it

per testare keycloak.

Va verificato come impostare l'hostname di Keycloak in funzione delle chiamate che arrivano dai microservizi, altrimenti non è raggiungibile se non fa match l'url chiamato con quello dichiarato nel conf.

Notare che in SSL la porta passa da 9445 a 8443 (inserita nella versione corrente del docker-compose) 

Configurazione suggerita per un container test mode
8Core
10GByte MEM
10GByte Swap
5000GB Disk
