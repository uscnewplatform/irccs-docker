# sync_env.sh — backup + restore HAPI FHIR / Keycloak tra ambienti

Copia i dati di un ambiente (SOURCE, es. prod) su un altro (TARGET, es. lab/preprod),
lanciato dalla tua macchina via SSH. Non serve accesso diretto agli host, solo SSH.

## Cosa fa, in ordine

1. **Chiede i dati** di SOURCE e TARGET: IP, porta SSH, utente, path di `irccs-docker`.
   (o li passi come flag, vedi sotto — utile per automazione)
2. **Blocca** se SOURCE e TARGET sono la stessa macchina (evita di sovrascrivere
   un DB con il dump appena fatto da se stesso).
3. **Check preliminare**: verifica che i container `postgres-hapi-fhir` e
   `postgres-keycloak` siano attivi su entrambi gli host.
4. **Legge i conteggi di riferimento** su SOURCE (`hfj_resource`, `user_entity`)
   per confrontarli a fine run.
5. **Dump su SOURCE** (`pg_dump`, sola lettura, nessun downtime, nessuna
   modifica) + verifica integrità del file subito dopo.
6. **Scarica i dump** da SOURCE alla tua macchina, poi li **carica su TARGET**.
7. **Riverifica l'integrità** dei dump su TARGET, prima di toccare qualsiasi DB.
   Se un file risulta corrotto, si ferma qui: nessuna modifica fatta.
8. **Salva i secret/redirect URI** dei client Keycloak di TARGET (via
   `kcadm.sh`) — servono per non rompere l'autenticazione dopo il restore,
   dato che il restore porta i secret di SOURCE. Se `irccs-keycloak` risulta
   già fermo su TARGET (es. recovery da un run precedente), lo script prova
   a riavviarlo da solo prima di rinunciare.
9. **Chiede conferma esplicita** (`RESTORE` da digitare) prima di qualunque
   modifica distruttiva. Fino a qui TARGET non è mai stato toccato.
10. **Restore su TARGET**: ferma le app (`irccs-hapi-fhir`, `irccs-keycloak`;
    i DB restano su), poi per ciascun DB (hapi, keycloak):
    - **wipe completo** dello schema (`DROP SCHEMA public CASCADE` +
      `CREATE SCHEMA`) e, per hapi, unlink di tutti i large object residui
      (i BLOB usati per `res_text` vivono in un catalogo globale, non nello
      schema — `DROP SCHEMA` non li tocca). Sostituisce `pg_restore --clean`:
      `--clean` genera i DROP solo per gli oggetti presenti nel dump di
      SOURCE, quindi si blocca se TARGET ha oggetti extra (viste custom,
      BLOB vecchi), lasciando un DB in stato misto con errori solo
      "ignorati" — un restore che sembra riuscito ma non lo è. Il wipe
      totale è sicuro perché il restore è sempre pensato come sovrascrittura
      integrale di TARGET.
    - `pg_restore --exit-on-error`: un errore reale ferma subito lo script,
      niente più errori "ignorati" silenziosamente.
    - riavvia le app.
11. **Ripristina i secret/redirect URI** originali di TARGET sui client
    (letti al punto 8), così le app che usano quei client secret continuano
    a funzionare senza toccare `.env`/`application.properties`.
12. **Reindex HAPI su TARGET** (`$reindex`, **chiede conferma esplicita**,
    skippabile con `--yes`): dopo un restore, il DB ha le risorse ma i
    SearchParameter custom (es. `activity-outcomeReference`) possono non
    essere ancora indicizzati — senza reindex alcune query REST falliscono
    con "Unknown search parameter" e la dashboard sembra vuota pur avendo
    i dati nel DB. Lo script lancia il job e fa **poll** dello stato
    (`bt2_job_instance`) ogni 10s, fino a `COMPLETED` o timeout 30 min (job
    continua comunque in background su TARGET se il timeout scade).
13. **Confronto finale automatico**: legge i conteggi su TARGET e li confronta
    con quelli di SOURCE (punto 4), stampa una tabella OK/MISMATCH.
14. **Smoke test REST reale** (non solo `count(*)` sul DB): legge via
    `GET /fhir/Patient/<id>` una risorsa Patient effettivamente presente su
    TARGET. Se fallisce con `HAPI-1996 resource not known` pur essendo la
    riga nel DB — firma nota di `partition_id` non risolto dalla partizione
    di default di quella specifica istanza HAPI — lo script **riconcilia da
    solo** (`UPDATE ... SET partition_id = 0 WHERE partition_id IS NULL` su
    tutte le tabelle con quella colonna), rilancia il reindex e ritenta una
    volta. Se fallisce ancora, si ferma con errore invece di dichiarare un
    falso successo.

## Cosa NON tocca mai

- SOURCE: solo letto (`pg_dump`), mai fermato, mai scritto.
- TARGET: toccato solo dopo la verifica integrità doppia (su source e su
  target) e la conferma esplicita `RESTORE`.
- Se un check fallisce in un punto qualsiasi, lo script si ferma
  (`set -euo pipefail`): niente restore parziale.

## Uso interattivo (consigliato)

```bash
./sync_env.sh
```
Risponde alle domande passo passo. Alla fine chiede conferma prima di
partire e di nuovo prima del restore vero e proprio.

## Uso non interattivo (automazione)

```bash
./sync_env.sh \
  --src-host prod.ip --src-port 22 --src-user infocube --src-dir /home/infocube/irccs-docker \
  --dst-host lab.ip  --dst-port 22 --dst-user infocube --dst-dir /home/infocube/irccs-docker \
  --yes            # salta le conferme interattive (restore resta comunque distruttivo su TARGET)
  --keep-local     # non cancella i dump scaricati in locale a fine run
```

## Requisiti

- SSH configurato verso entrambi gli host (accetta password interattiva,
  ma se vuoi evitarla: chiave SSH + `ssh-copy-id` — consigliato — oppure
  `sudo apt install sshpass` + `export SYNC_SRC_SSH_PASS=... SYNC_DST_SSH_PASS=...`
  prima di lanciare lo script; senza `sshpass` o le env var chiede la
  password normalmente, nessuna rottura. Non salvare quelle password in
  file committati o in chiaro su disco).
- `jq` installato sulla tua macchina (serve per il salvataggio/ripristino
  secret Keycloak — se manca, quello step viene saltato con un warning).
- `docker compose` o `docker-compose` su TARGET (auto-rilevato).
- `kcadm.sh` nel path standard `/opt/keycloak/bin/kcadm.sh` dentro il
  container `irccs-keycloak`.

## Limiti noti

- Copre solo il realm indicato in `KEYCLOAK_REALM` (`.env`), non `master`.
- Assume che i client secret non contengano l'apice singolo `'`.
- Se il ripristino dei secret fallisce per qualche client, lo script lo
  segnala a fine run e lascia il file di backup JSON in `/tmp/sync_env_*`
  (usa `--keep-local` per non farlo cancellare) per un fix manuale via
  `kcadm.sh`.
