# Restore Playbook — HAPI FHIR / Keycloak

Procedura manuale per disaster recovery. Da eseguire con calma, seguendo l'ordine.
Testare per intero su un ambiente pulito (pascale-local o VM scratch) prima di
fidarsene in produzione — vedi sezione "Test periodico" in fondo.

## 0. Prerequisiti

- Accesso host prod, docker CLI, stack irccs-docker checked out.
- Chiave privata `age` per decifrare l'archivio (**non** risiede sull'host di backup — recuperarla dalla sua sede separata).
- Dump da ripristinare: locale (`backup/<hapi|keycloak>/archive/*.dump.age`) o dalla copia offsite se il disco locale è perso.

## 1. Decidere il punto di restore

- RPO = 24h: si perdono al massimo le modifiche dall'ultimo backup notturno riuscito alle 03:15.
- Elenco backup disponibili: `ls -la backup/hapi/archive/ backup/keycloak/archive/` (locale) o dal target offsite.
- Se il disco locale è perso, recuperare prima da offsite (`rclone copy <target>/hapi/ ./restore-staging/` ecc.).

## 2. Fermare i servizi applicativi (non i DB)

```bash
docker compose stop irccs-auth irccs-anagrafica-pazienti irccs-studio-clinico \
  irccs-centro-ricerca irccs-practitioner irccs-clinical-reasoning \
  irccs-notification irccs-tac irccs-zammad irccs-httpd-dashboard
```

Evita scritture concorrenti durante il restore. I due container postgres restano su.

## 3. Decifrare il dump

```bash
age -d -i /path/alla/chiave-privata.txt \
  backup/hapi/archive/hapi_2026-09-14.dump.age > /tmp/hapi_restore.dump

age -d -i /path/alla/chiave-privata.txt \
  backup/keycloak/archive/keycloak_2026-09-14.dump.age > /tmp/keycloak_restore.dump
```

## 4. Ricreare i DB (drop + create pulito)

**Attenzione: operazione distruttiva, cancella i dati correnti nel DB target.**
Confermare di avere il dump giusto prima di procedere.

```bash
# HAPI
docker exec -i postgres-hapi-fhir psql -U "$HAPI_DB_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$HAPI_DB_NAME\";" \
  -c "CREATE DATABASE \"$HAPI_DB_NAME\" OWNER \"$HAPI_DB_USER\";"

# Keycloak
docker exec -i postgres-keycloak psql -U "$POSTGRES_KEYCLOAK_USER" -d postgres \
  -c "DROP DATABASE IF EXISTS \"$POSTGRES_KEYCLOAK_DB\";" \
  -c "CREATE DATABASE \"$POSTGRES_KEYCLOAK_DB\" OWNER \"$POSTGRES_KEYCLOAK_USER\";"
```

## 5. Restore

```bash
docker exec -i postgres-hapi-fhir pg_restore -U "$HAPI_DB_USER" \
  -d "$HAPI_DB_NAME" --no-owner --no-privileges < /tmp/hapi_restore.dump

docker exec -i postgres-keycloak pg_restore -U "$POSTGRES_KEYCLOAK_USER" \
  -d "$POSTGRES_KEYCLOAK_DB" --no-owner --no-privileges < /tmp/keycloak_restore.dump
```

## 6. Pulizia file decifrati in chiaro

```bash
shred -u /tmp/hapi_restore.dump /tmp/keycloak_restore.dump
```

## 7. Riavvio ordinato

```bash
docker compose up -d irccs-keycloak
# attendere healthcheck keycloak OK, poi:
docker compose up -d irccs-hapi-fhir
# attendere che HAPI risponda su /fhir/metadata, poi il resto:
docker compose up -d
```

## 8. Verifica funzionale post-restore

- [ ] Login Keycloak (backoffice) con utente noto funziona
- [ ] `curl http://localhost:8080/fhir/metadata` risponde 200
- [ ] Query FHIR di prova (es. `GET /fhir/Patient?_count=1`) restituisce dati coerenti con la data del dump
- [ ] Dashboard React carica e mostra dati
- [ ] Controllo log per errori inattesi (Grafana/Loki)

## 9. Comunicazione

- Annotare in questo file (sezione "Storico test/incidenti" sotto) data, motivo, dump usato, RTO effettivo misurato.
- Se restore reale (non test): notificare DPO/referente compliance (vedi processo audit trail esistente, [[audit-trail-compliance-gaps]] in memoria progetto).

---

## Test periodico (obbligatorio)

Eseguire questa procedura per intero su ambiente scratch (pascale-local o VM
dedicata) **almeno trimestralmente**. Misurare e annotare l'RTO reale: è il
numero che conta in caso di incidente, non una stima.

## Storico test/incidenti

| Data | Tipo (test/reale) | Dump usato | RTO misurato | Esito | Note |
|---|---|---|---|---|---|
| _(compilare al primo test)_ | | | | | |
