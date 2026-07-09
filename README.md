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

| # | Passo | Sezione |
|---|-------|---------|
| 1 | SearchParameters FHIR | [§1](#1-installazione-searchparameters-fhir) |
| 2 | SMTP Keycloak | [§2](#2-configurazione-smtp-in-keycloak) |
| 3 | Rigenera CLIENT_SECRET Keycloak | [§3-cambio-secret-keycloak](#3-cambio-secret-keycloak) |
| 4 | Lingua IT + theme | [§4](#4-aggiunta-lingua-italiano-e-themes-customizzati) |
| 5 | J-LI | [Installazione PJ J-LI](#installazione-pj-j-li) |
| 6 | Tipi di consenso | [Installazione tipi di consenso](#installazione-tipi-di-consenso) |
| 7 | CRF Libraries (CTCAE, EORTC, EuroQol…) | [Installazione CRF Libraries](#installazione-crf-libraries) |
| 8 | Farmaci AIFA (opzionale) | [Import Farmaci AIFA](#import-farmaci-aifa) |

> Tutti gli step sono **idempotenti** (PUT/POST conditional): ri-lanciabili senza duplicati.

## 1. Installazione SearchParameters FHIR

Portarsi nella cartella setup ed eseguire il comando
```bash
chmod +x install_searchparameters.sh
bash install_searchparameters.sh hostname:port
Usage: install_searchparameters.sh hostname:port
```
##### hostname:port deve corrispondere all’istanza FHIR target.

Lo script installerà i parametri di ricerca necessari per garantire il corretto funzionamento dei microservizi che interagiscono con il server FHIR.

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

## Installazione PJ J-LI
Portarsi nella cartella setup ed eseguire il comando
chmod +x install_jli.sh

Eseguire poi il comando
```bash
./install_jli.sh http://{ip}:{port}/fhir  
```

ip e port sono quelle del container di fhir (vedi docker-compose, la porta esposta per hapi-fhir è 8080) : http://irccs-hapi-fhir:8080/fhir

## Installazione tipi di consenso
Registry dinamico dei tipi di consenso come CodeSystem FHIR (`urn:irccs:consent-type`). Precarica i 9 tipi base (terminologia HL7). Necessario per il designer e per il tipo `privacy`.
```bash
chmod +x install_consent_types.sh
bash install_consent_types.sh hostname:port
```
Idempotente (PUT conditional). Gestione successiva da dashboard: Back-office → Tipi di consenso (SuperAdmin).

## Installazione CRF Libraries
Carica le terminologie CRF (CTCAE v4/v5/v6, PRO-CTCAE, EORTC QLQ-C30/HCC18, EuroQol EQ-5D-5L, USC PROFFIT)
come `CodeSystem + ValueSet + StructureDefinition` su HAPI. Ogni libreria ha un `*-bundle.json`
committato = unica sorgente (solo `curl`, zero dipendenze). Idempotenti (PUT per url).

```bash
cd importCrfLibraries
HAPI=http://irccs-hapi-fhir:8080/fhir   # o http://localhost:8080/fhir dall'host

bash ctcae-v4/install-ctcae-v4.sh             "$HAPI"
bash ctcae-v5/install-ctcae-v5.sh             "$HAPI"
bash ctcae-v6/install-ctcae-v6.sh             "$HAPI"
bash proctc-v1/install-proctc-v1.sh           "$HAPI"
bash eortc-qlq-c30/install-eortc-v1.sh        "$HAPI"
bash eortc_hcc18/install-eortc-hcc18.sh       "$HAPI"
bash euroqol_eq5d5l/install-euroqol-eq5d5l.sh "$HAPI"
bash usc_proffit/install-usc-proffit.sh       "$HAPI"
```

La UI scopre le library **automaticamente** da HAPI: caricata una libreria, il bottone di import
compare nel Questionnaire builder senza modifiche al frontend.
Dettagli e rigenerazione bundle: `importCrfLibraries/README.md`.

## Import Farmaci AIFA
Catalogo farmaci AIFA come terminology FHIR. Due pipeline **indipendenti** (vedi
`import-farmaci-aifa/README.md`). Richiede `requests` (usa un venv, PEP 668):

```bash
cd import-farmaci-aifa
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
HAPI=http://localhost:8080/fhir

# Pipeline A — Classe A/H (~12.9k, snapshot committato)
.venv/bin/python import-aifa-per-classi/import-aifa-farmaci.py "$HAPI" --version 2026-05

# Pipeline B — Confezioni ATC (~159k, a lotti; prima uno smoke test)
.venv/bin/python import-confezioni-atc/import-confezioni-atc-batch.py "$HAPI" --limit 2000
.venv/bin/python import-confezioni-atc/import-confezioni-atc-batch.py "$HAPI"
```

La ricerca `$expand?filter` richiede la pre-espansione ValueSet (`pre_expand_value_sets: true`
già attivo su HAPI): gira in background dopo l'import, nessun `$reindex` necessario.

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
schedulare uno snapshot mensile del volume `loki_data` **prima** che scada la finestra
di retention:

```bash
crontab -e
```

Aggiungere (esegue il giorno 1 di ogni mese alle 03:00, log dell'esecuzione in
`/var/log/loki-archive.log`):

```cron
0 3 1 * * /path/to/irccs-docker/setup/archive_loki_snapshot.sh /var/backup/loki-archive >> /var/log/loki-archive.log 2>&1
```

Sostituire `/path/to/irccs-docker` con il path reale di checkout su questa macchina.
Gli archivi (`.tar.gz`, uno per snapshot) non vengono mai cancellati automaticamente —
pulizia a mano quando non servono più. Verificare periodicamente lo spazio disco in
`/var/backup/loki-archive`.

## Stack PWA (stack separato)

La PWA questionari (`irccs-pwa`) gira in uno stack Docker separato che si aggancia alla rete `irccs-docker_irccs`.

### Prerequisiti

Aggiungere al `.env` prima di avviare:

```bash
# OBBLIGATORIO: openssl rand -hex 32
PWA_SECRET_KEY=

# staging = no ENFORCE_HTTPS richiesto; production = richiede ENFORCE_HTTPS=true
PWA_ENVIRONMENT=staging
PWA_ENFORCE_HTTPS=false

# Origini CORS ammesse (porta admin + eventuale dominio pubblico)
# Esempio: http://10.99.88.240:8092,https://pwa.irccs.infocube.it
PWA_CORS_ORIGINS=
```

### Build mode (HTTP vs HTTPS)

Le immagini Flutter (PWA paziente e admin) sono buildate con `BUILD_MODE`:

| Valore | Quando usarlo |
|--------|--------------|
| `profile` (default) | Preprod/locale senza HTTPS — `kReleaseMode=false`, HTTP consentito |
| `release` | Produzione con HTTPS attivo — `kReleaseMode=true`, HTTPS obbligatorio |

Per cambiare mode: triggera il job Jenkins `irccs-pwa` con parametro `BUILD_MODE=release` (o `profile`), poi rideploya le immagini.

### Avvio completo (prima installazione)

**1. Configura `.env`** (vedi sezione Prerequisiti sopra)

**2. Avvia lo stack IRCCS principale** (se non già up):
```bash
docker-compose up -d
```

**3. Avvia lo stack PWA:**
```bash
docker-compose -f docker-compose.pwa.yml up -d
```

**4. Verifica che i container siano up:**
```bash
docker-compose -f docker-compose.pwa.yml ps
# tutti e 3 devono essere in stato "Up"
```

**5. Seed iniziale — obbligatorio alla prima installazione:**
```bash
docker exec irccs-pwa-backend python seed.py
```
Crea l'utente admin PWA e i dati demo. **Senza questo step il login admin non funziona.**

**6. Verifica backend:**
```bash
docker exec irccs-pwa-backend curl -s http://localhost:8000/health
# atteso: {"status":"ok"}
```

**7. Apri nel browser:**

| Servizio | URL |
|----------|-----|
| PWA paziente | http://\<IP\>:8090/app/ |
| PWA admin panel | http://\<IP\>:8092/pwa-admin/ |
| Backend API (Swagger) | http://\<IP\>:8091/docs |

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
- **Login admin non funziona** → eseguire `docker exec irccs-pwa-backend python seed.py`.
- **Backend non risponde** → `docker-compose -f docker-compose.pwa.yml logs --tail=50 irccs-pwa-backend`.
- **Rete non trovata all'avvio** → lo stack IRCCS principale deve essere up prima (`docker-compose up -d`).

## Note application.properties MS
Questa nota serve per gli sviluppatori per capire come funziona la gestione dell'application.properties dei microservizi.
I file di properiets deployati all'interno delle diverse cartelle del progetto vanno in aggiunta e/o modifica dei file application.properties "interni" dei microservizi.
Questo significa che ci sono delle proprietà interne dei MS che non sono esposte , volutamente, all'esterno(vedi rootpath dei controller).
