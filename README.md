## Introduzione.
La presente guida si pone l'obiettivo di semplificare la prima installazione del portale
su una nuova piattaforma


## PREREQUISITI INSTALLAZIONE :

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


## Per avviare il progetto:

```
git clone git@github.com:infocube-it/irccs-docker.git
cd irccs-docker
cp .env_example .env
(il file .env va richiesto al team di sviluppo e NON VA COMMITTATO)

docker-compose up -d
```

## CONFIGURAZIONI FHIR/KEYCLOAK

## 1. Installazione SearchParameters FHIR

```bash
chmod +x install_searchparameters.sh
bash setup/install_searchparameters.sh hostname:port
Usage: install_searchparameters.sh hostname:port
```
##### hostname:port deve corrispondere all’istanza FHIR target.

Lo script installerà i parametri di ricerca necessari per garantire il corretto funzionamento dei microservizi che interagiscono con il server FHIR.

## 2. Configurazione SMTP in Keycloak

Accedere alla dashboard di Keycloak ed effettuare i seguenti passaggi:

- Autenticarsi con utenza di ADMIN (fornita nel file .env):


**Assicurarsi di cambiare password di quest'ultimo**

- Selezionare il realm: _pascale_.

- Nel menu laterale, aprire _Realm Settings_ → scheda _Email_.

- Nella sezione Connection & Authentication (in fondo alla pagina):

- Inserire i parametri SMTP forniti dall’infrastruttura.

- Verificare la connessione cliccando su _Test connection_.

## 3 Cambio SECRET Keycloak

Loggarsi con l'utenza di Admin alla UI di keycloak , (http://irccs-keycloak:9445)
Accedi a Keycloak (porta 9445): Realm pascale → Clients → irccs → Credentials → REGENERATE CLIENT SECRET (premere si al popup)
Copiare il secret generato ed inserirlo nel file .env (variabile KEYCLOAK_CLIENT_SECRET) ed eseguire i comandi:
docker-compose down
docker-compose up -d

## Installazione PJ J-LI
Portarsi nella cartella setup ed eseguire il comando
chmod +x install_jli.sh

Eseguire poi il comando
./install_jli.sh http://{ip}:{port}/fhir  

ip e port sono quelle del container di fhir (vedi docker-compose, la porta esposta per hapi-fhir è 8080) : http://irccs-hapi-fhir:8080/fhir

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
