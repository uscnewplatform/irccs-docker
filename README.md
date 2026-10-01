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
cp .env_example .env (con permessi il lettura e scrittura! 777) 
(il file .env va richiesto al team di sviluppo e NON VA COMMITTATO)

docker-compose up -d
```

## CONFIGURAZIONI FHIR/KEYCLOAK

### Sequenza prima installazione (ordine consigliato)

Da eseguire **una volta** dopo `docker-compose up -d`, con lo stack sano
(keycloak `healthy`, HAPI raggiungibile). `HAPI` = `http://irccs-hapi-fhir:8080/fhir`
(dal container) o `http://localhost:8080/fhir` (dalla macchina host, porta esposta 8080).

| # | Passo | Tipo |
|---|-------|------|
| 1 | SMTP Keycloak | Manuale (UI) |
| 2 | Rigenera CLIENT_SECRET Keycloak | Manuale (UI) |
| 3 | Lingua IT + theme | Manuale (UI) |
| 4-9 | SearchParameters, J-LI, tipi di consenso, librerie CRF, farmaci AIFA | Automatico — un comando |

> Gli step manuali (1-3) vanno fatti a mano da UI Keycloak, vedi sotto.
> Gli step automatici (4-9) sono un unico comando:
> ```bash
> ./setup/install/install-all.sh http://irccs-hapi-fhir:8080/fhir
> ```
> Guida completa passo-passo, con dettaglio di cosa fa ciascuno step e cosa resta manuale (LOINC): `docs/modules/ROOT/pages/installazione.adoc`.
> Tutti gli step sono **idempotenti** (PUT/POST conditional): ri-lanciabili senza duplicati.

## 2. Configurazione SMTP in Keycloak

Accedere alla dashboard di Keycloak ed effettuare i seguenti passaggi:

- Autenticarsi con utenza di ADMIN (fornita nel file .env):


**Assicurarsi di cambiare password di quest'ultimo** ed assegnargli il ruolo di admin cliccando su users->gennaro.aurilia@gmail.com ->Role mapping->assign role = ADMIN

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

## 4 Aggiunta lingua italiano e themes customizzati

Loggarsi con l'utenza di Admin alla UI di keycloak , (http://irccs-keycloak:9445)
Accedi al realm pascale e poi clicca su REALM CONFIG
Cliccare sulla tab Languages e aggiungere italiano
Clicca su Themes e poi su Custom Theme e selezionare il provider customizzato pascale-theme per il tema

## Installazione dati FHIR (SearchParameters, J-LI, consensi, librerie CRF, farmaci AIFA)

Un solo comando esegue tutti gli step di import dati (idempotenti, rilanciabili senza duplicati):

```bash
./setup/install/install-all.sh http://irccs-hapi-fhir:8080/fhir
```

Lo script richiede il modulo Python `requests` per gli step farmaci AIFA (su host con Python
gestito dal sistema, PEP 668, serve un venv — lo script lo segnala con le istruzioni se manca).

Dettaglio di cosa fa ciascuno step, esecuzione singola per debug, e guida completa alla prima
installazione (incluso cosa resta manuale — LOINC): `docs/modules/ROOT/pages/installazione.adoc`.

Per la sola architettura/rigenerazione delle librerie CRF: `data-import/crf-libraries/README.md`.
Per il solo dettaglio pipeline farmaci AIFA: `data-import/farmaci-aifa/README.md`.

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


Verifiche:

in keycloak, verificare che l'utente di servizio nel realm pascale "service-account-irccs" abbia il ruolo /admin (necessario per le chiamate di signup)


Nel caso in cui si voglia disabilitare la gestione dei ticket, va commentato/eliminato la property VITE_APP_ZAMMAD_HOST all'interno di httpd-config/config-prod.js : questo
nasconderà i bottoni e bloccherà le chiamate di polling di ricerca dei ticket


## Setup WebPush DB (installazioni esistenti)

Su fresh install il file `postgres-init/01-create-webpush-db.sh` viene eseguito automaticamente da PostgreSQL al primo avvio.

Su installazioni esistenti (volume già inizializzato) eseguire manualmente:

```bash
source .env

docker exec -it postgres-keycloak psql -U "$POSTGRES_KEYCLOAK_USER" -d postgres \
  -c "CREATE USER webpush WITH PASSWORD '$WEBPUSH_DB_PASSWORD';"

docker exec -it postgres-keycloak psql -U "$POSTGRES_KEYCLOAK_USER" -d postgres \
  -c "CREATE DATABASE webpush OWNER webpush;"

docker exec -it postgres-keycloak psql -U "$POSTGRES_KEYCLOAK_USER" -d postgres \
  -c "GRANT ALL PRIVILEGES ON DATABASE webpush TO webpush;"

docker compose up -d irccs-webpush
```

## Stack di Monitoraggio (Loki/Grafana/Alloy)

Logging centralizzato: dettagli completi in `docs/modules/ROOT/pages/monitoraggio.adoc`.

### Avvio

Richiede la rete esterna `irccs` (creata dallo stack applicativo principale):

```bash
docker compose -f docker-compose-monitoring.yaml up -d
```

### Cron: archiviazione log oltre retention (3 mesi)

Loki tiene i log interrogabili in Grafana per 3 mesi (`retention_period: 2160h` in
`monitoring-config/loki-config.yml`), poi il compactor li cancella. Per non perderli,
uno snapshot mensile del volume `loki_data` va eseguito **prima** che scada la finestra
di retention. Installazione automatica (idempotente, sostituisce il vecchio
`crontab -e` manuale — verificato durante l'audit trail Fase 3 che nessuno l'aveva mai
effettivamente eseguito):

```bash
./setup/install/install_loki_archive_cron.sh [directory_archivio] [mesi_da_conservare]
# default: /var/backup/loki-archive, 12 mesi
```

Schedula il giorno 1 di ogni mese alle 03:00 (log in `/var/log/loki-archive.log`).
Gli archivi (`.tar.gz`, uno per snapshot) piu' vecchi della soglia `mesi_da_conservare`
vengono cancellati automaticamente ad ogni run — prima non c'era alcuna pulizia, lo
spazio disco cresceva senza limite. Verificare comunque periodicamente lo spazio in
`directory_archivio` (default `/var/backup/loki-archive`).

## Stack PWA (stack separato)

La PWA questionari (`irccs-pwa`) gira in uno stack Docker separato che si aggancia alla rete `irccs-docker_irccs`. Il backend è integrato in `irccs-httpd` (non più un servizio separato).

### Build mode (HTTP vs HTTPS)

Le immagini Flutter (PWA paziente e admin) sono buildate con `BUILD_MODE`:

| Valore | Quando usarlo |
|--------|--------------|
| `profile` (default) | Preprod/locale senza HTTPS — `kReleaseMode=false`, HTTP consentito |
| `release` | Produzione con HTTPS attivo — `kReleaseMode=true`, HTTPS obbligatorio |

Per cambiare mode: triggera il job Jenkins `irccs-pwa` con parametro `BUILD_MODE=release` (o `profile`), poi rideploya le immagini.

### Avvio completo (prima installazione)

**1. Avvia lo stack IRCCS principale** (se non già up):
```bash
docker-compose up -d
```

**2. Avvia lo stack PWA:**
```bash
docker-compose -f docker-compose.pwa.yml up -d
```

**3. Verifica che il container sia up:**
```bash
docker-compose -f docker-compose.pwa.yml ps
```

**4. Apri nel browser:**

| Servizio | URL |
|----------|-----|
| PWA paziente | http://\<IP\>:8090/app/ |

### Aggiornamento immagini

```bash
docker-compose -f docker-compose.pwa.yml pull
docker-compose -f docker-compose.pwa.yml up -d
```

### Stop stack PWA

```bash
docker-compose -f docker-compose.pwa.yml down
```

### Troubleshooting

- **Flutter crasha con "API_BASE_URL deve essere HTTPS"** → le immagini sono state buildate con `BUILD_MODE=release`. Rebuildare con `BUILD_MODE=profile` (job Jenkins `irccs-pwa`).
- **Rete non trovata all'avvio** → lo stack IRCCS principale deve essere up prima (`docker-compose up -d`).

## Note application.properties MS
Questa nota serve per gli sviluppatori per capire come funziona la gestione dell'application.properties dei microservizi.
I file di properiets deployati all'interno delle diverse cartelle del progetto vanno in aggiunta e/o modifica dei file application.properties "interni" dei microservizi.
Questo significa che ci sono delle proprietà interne dei MS che non sono esposte , volutamente, all'esterno(vedi rootpath dei controller).
