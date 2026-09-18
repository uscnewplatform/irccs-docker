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
- `nginx-maintenance-standalone.conf` — config nginx **completo**
  (events{}/http{}), e' quello che la unit systemd passa a `nginx -c`.
  Include il vhost vero e proprio (sotto). Va installato SEMPRE, uguale
  in lab e in prod (cambia solo quale vhost include, vedi sotto).
- `nginx-maintenance.conf` — vhost **produzione**: porta 443 + TLS, stessi
  certificati gia' usati da `irccs-httpd-dashboard`.
- `nginx-maintenance-lab.conf` — vhost **lab/test**: porta 80, no TLS,
  coerente con `VirtualHost *:80` usato in questo repo/ambiente.
  Uno dei due va installato come `/etc/nginx/sites-available/irccs-maintenance-vhost.conf`
  (nome fisso, referenziato dal config standalone).
- `irccs-maintenance.service` — unit systemd, `disabled` di default (non
  parte al boot, va avviata a mano).
- `maintenance.html` — copia statica della stessa pagina.

Nota: `nginx -c <file>` prende quel file come l'INTERO `nginx.conf` (deve
avere `events{}`/`http{}`), non come un singolo vhost — per questo la unit
punta al file standalone, che a sua volta fa `include` del vhost giusto.

## Installazione (una tantum, in lab prima di prod)

```bash
# 1. nginx sull'host, se non gia' presente
sudo apt install nginx

# 2. copia pagina, config standalone e vhost
sudo mkdir -p /opt/irccs-maintenance /etc/nginx/sites-available
sudo cp host-maintenance/maintenance.html /opt/irccs-maintenance/
sudo cp host-maintenance/nginx-maintenance-standalone.conf /etc/nginx/irccs-maintenance-standalone.conf
# LAB (porta 80, no TLS):
sudo cp host-maintenance/nginx-maintenance-lab.conf /etc/nginx/sites-available/irccs-maintenance-vhost.conf
# PROD (porta 443, TLS) - usare questo invece del precedente in produzione:
#   sudo cp host-maintenance/nginx-maintenance.conf /etc/nginx/sites-available/irccs-maintenance-vhost.conf
# NON creare link in sites-enabled del nginx "principale" (se presente): va
# avviato standalone via systemd, per evitare conflitti di porta quando lo
# stack Docker e' su.

# 3. unit systemd
sudo cp host-maintenance/irccs-maintenance.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl disable irccs-maintenance   # resta dormiente, non parte al boot

# 4. verifica sintassi PRIMA di avviare
sudo nginx -t -c /etc/nginx/irccs-maintenance-standalone.conf
```

In lab, verificare che `listen 80` (variante `-lab.conf`) non confligga con
altri servizi gia' presenti sull'host. In prod, verificare in
`nginx-maintenance.conf` che i path dei certificati corrispondano a quelli
reali sulla VM (`/home/savioadmin/cert-pasc-2026*`), e che `listen 443` non
confligga con altri servizi nginx eventualmente gia' presenti sull'host.

## Uso combinato

Script in questa cartella, entrambi eseguibili da `irccs-docker/`. Fanno
TUTTI i passaggi in un colpo (richiedono il fallback gia' installato, vedi
sopra):

```bash
./host-maintenance/maintenance-on.sh
```
1. Scrive il flag Livello 1 (backend).
2. Avvia il fallback host-level (`sudo systemctl start irccs-maintenance`)
   se non gia' attivo.
3. `docker compose down` — sicuro perche' la porta resta coperta dal nginx
   host-level, nessuna finestra di 502/connection refused.

```bash
./host-maintenance/maintenance-off.sh
```
1. `docker compose up -d`.
2. Attende (fino a 60s) che `irccs-httpd-dashboard` sia up prima di
   proseguire — se non ce la fa si ferma e NON tocca il fallback, per non
   lasciare la porta scoperta.
3. Ferma il fallback host-level.
4. Svuota il flag Livello 1.

Richiede `sudo` senza password per `systemctl start/stop irccs-maintenance`
(o va lanciato con utente che ha i permessi), altrimenti si ferma a
chiedere la password a meta' sequenza.

Rilevano da soli quale comando compose usare: `docker compose` (v2, plugin)
se disponibile, altrimenti fallback su `docker-compose` (v1, binario a
parte) — non tutte le macchine hanno entrambi. Se non trovano ne' l'uno ne'
l'altro, escono con errore prima di toccare nulla.

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
