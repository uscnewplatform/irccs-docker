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

Script in questa cartella (`maintenance-lib.sh` = funzioni comuni, non va
lanciato). Gestiscono TUTTI gli stack, con il fallback gia' installato (vedi sopra):

| Stack | Compose |
|---|---|
| main (incl. `irccs-httpd-dashboard`) | `docker-compose.yaml` |
| monitoring (Loki/Grafana/Alloy) | `docker-compose-monitoring.yaml` |
| zammad | `zammad-ticketing/docker-compose.yaml` |
| pwa | `docker-compose.pwa.yml` |

```bash
./host-maintenance/maintenance-on.sh
```
1. Scrive il flag Livello 1.
2. Salva in `host-maintenance/.maintenance-stacks` quali stack erano su.
3. Ferma PER PRIMO `irccs-httpd-dashboard` e avvia subito il nginx di
   cortesia (`sudo systemctl start irccs-maintenance`): httpd e nginx vogliono
   la stessa porta, httpd deve essere gia' fermo.
4. `down` di pwa, zammad, monitoring e per ultimo main (main possiede la rete
   `irccs` usata dagli altri).

La pagina di assistenza e' visibile ovunque: nginx risponde 503 a qualunque
host/path sulla porta (dashboard, `/app` della PWA, host Zammad `pj-tk...`);
in piu', col solo Livello 1 (httpd su), anche il vhost Zammad
(`httpd-config/zammad.conf`) onora `.maintenance-flag`.

```bash
./host-maintenance/maintenance-off.sh
```
1. Rialza lo stack main SENZA httpd (nginx serve ancora la pagina).
2. Ferma nginx, avvia `irccs-httpd-dashboard` (flag ancora ON: 503 + pagina)
   e attende fino a 60s. Se non parte, rimette su nginx da solo ed esce con errore.
3. Rialza monitoring, zammad, pwa — solo quelli che erano su prima (se il file
   di stato manca, tutti). Un errore su uno di questi non blocca: exit 2 e
   elenco degli stack falliti.
4. Svuota il flag Livello 1 e cancella il file di stato.

La finestra senza risposta si riduce a pochi secondi (tra stop httpd e avvio
nginx in "on", e tra stop nginx e avvio httpd in "off"): non eliminabile
senza un layer esterno sempre attivo.

Richiede `sudo` senza password per `systemctl start/stop irccs-maintenance`.
Rilevano da soli `docker compose` (v2) o `docker-compose` (v1).

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
