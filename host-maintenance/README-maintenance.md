# Pagina di manutenzione

Sistema a due livelli, indipendenti tra loro.

## Livello 1 — backend/stack giu', httpd Docker ancora su

File coinvolti:
- `httpd-config/.maintenance-flag` — montato in `irccs-httpd-dashboard` come
  `/usr/local/apache2/htdocs/.maintenance-flag`. Vuoto = sito attivo.
  Non vuoto = manutenzione.
- `httpd-config/maintenance.html` — pagina statica servita in caso di
  manutenzione, montata come `/usr/local/apache2/htdocs/maintenance.html`.
- `httpd-config/irccs.conf` — blocco `RewriteCond .../.maintenance-flag -s`
  in cima al `VirtualHost`, prima di ogni `ProxyPass`. Se il flag non e'
  vuoto, ogni richiesta (SPA, API FHIR, auth, tutto) risponde 503 con
  `maintenance.html` come body (`ErrorDocument 503`) e header `Retry-After`.

Come funziona `-s` in `RewriteCond`: vero solo se il file esiste **e** ha
dimensione > 0. Un file vuoto (default) = condizione falsa = sito normale.

Copre: manutenzione dei microservizi backend (deploy, migrazioni, DB giu'),
mentre `irccs-httpd-dashboard` resta in esecuzione e serve la pagina.

Non copre: `irccs-httpd-dashboard` stesso fermo/in aggiornamento, o
`docker compose down` dell'intero stack — in quel caso nessun processo legge
il flag, nessuno risponde su 443. Per questo serve il Livello 2.

## Livello 2 — httpd Docker (o l'intero stack) fermo

Un nginx **dormiente** installato sull'host (non in Docker), che normalmente
NON e' in esecuzione e non e' abilitato al boot. Si avvia solo a mano quando
si ferma `irccs-httpd-dashboard` o l'intero stack, occupa la porta 443
(libera perche' Docker non la sta piu' usando) e serve la stessa pagina
statica con 503.

File in questa cartella (`host-maintenance/`), da installare sull'host (NON
dentro un container):
- `nginx-maintenance.conf` — vhost nginx **produzione**: porta 443 + TLS,
  stessi certificati gia' usati da `irccs-httpd-dashboard`.
- `nginx-maintenance-lab.conf` — vhost nginx **lab/test**: porta 80, no TLS,
  coerente con `VirtualHost *:80` usato in questo repo/ambiente.
  Usare questo in lab, l'altro in prod — entrambi si installano con lo
  stesso nome destinazione (vedi sotto), la unit systemd non cambia.
- `irccs-maintenance.service` — unit systemd, `disabled` di default (non
  parte al boot, va avviata a mano).
- `maintenance.html` — copia statica della stessa pagina.

## Installazione (una tantum, in lab prima di prod)

```bash
# 1. nginx sull'host, se non gia' presente
sudo apt install nginx

# 2. copia pagina e config
sudo mkdir -p /opt/irccs-maintenance
sudo cp host-maintenance/maintenance.html /opt/irccs-maintenance/
# LAB (porta 80, no TLS):
sudo cp host-maintenance/nginx-maintenance-lab.conf /etc/nginx/sites-available/irccs-maintenance.conf
# PROD (porta 443, TLS) - usare questo invece del precedente in produzione:
#   sudo cp host-maintenance/nginx-maintenance.conf /etc/nginx/sites-available/irccs-maintenance.conf
# NON creare link in sites-enabled: va avviato standalone via systemd,
# non tramite il nginx "principale" (se ce n'e' uno) per evitare conflitti
# di porta quando lo stack Docker e' su.

# 3. unit systemd
sudo cp host-maintenance/irccs-maintenance.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl disable irccs-maintenance   # resta dormiente, non parte al boot
```

In lab, verificare che `listen 80` (variante `-lab.conf`) non confligga con
altri servizi gia' presenti sull'host. In prod, verificare in
`nginx-maintenance.conf` che i path dei certificati corrispondano a quelli
reali sulla VM (`/home/savioadmin/cert-pasc-2026*`), e che `listen 443` non
confligga con altri servizi nginx eventualmente gia' presenti sull'host.

## Uso combinato

Script in questa cartella, entrambi eseguibili da `irccs-docker/`:

```bash
./host-maintenance/maintenance-on.sh
```
- Attiva sempre il flag Livello 1 (backend).
- Se `irccs-httpd-dashboard` non e' in esecuzione, avvisa di avviare anche
  il Livello 2 (`sudo systemctl start irccs-maintenance`) prima di fermare
  lo stack.

```bash
./host-maintenance/maintenance-off.sh
```
- Svuota il flag Livello 1.
- Se il fallback host-level (`irccs-maintenance`) e' attivo, lo ferma (cosi'
  la porta 443 torna libera per Docker).
- Ricorda di rifare `docker compose up -d` se lo stack era fermo.

Procedura consigliata per un update che richiede di fermare httpd/stack:

```bash
./host-maintenance/maintenance-on.sh          # flag ON
sudo systemctl start irccs-maintenance        # 443 coperta da nginx host
docker compose down                           # ora sicuro, 443 resta coperta
# ... aggiornamento ...
docker compose up -d                          # stack riparte
./host-maintenance/maintenance-off.sh         # ferma nginx host, svuota flag
```

## Test in lab prima di prod

1. Con stack su, `echo test > httpd-config/.maintenance-flag` (o lo script
   `maintenance-on.sh`) e verificare che qualunque URL risponda 503 con la
   pagina statica, incluse chiamate dirette a `/Patient`, `/auth`, ecc.
2. Svuotare il flag, verificare ritorno alla normalita' senza restart.
3. Fermare `irccs-httpd-dashboard` (`docker compose stop irccs-httpd`) SENZA
   avviare il fallback: verificare che il browser mostri errore di
   connessione (comportamento attuale, da migliorare).
4. Ripetere fermando `irccs-httpd-dashboard` ma con `irccs-maintenance`
   avviato: verificare che la pagina statica compaia comunque.
5. Verificare che riavviando lo stack (`docker compose up -d`) dopo aver
   fermato `irccs-maintenance`, il sito torni raggiungibile senza conflitti
   di porta (nginx deve essere gia' fermo prima che Docker riprenda 443).
