# Restore Playbook — HAPI FHIR / Keycloak

Procedura manuale per disaster recovery. Da eseguire con calma, seguendo l'ordine.
Testare per intero su un ambiente pulito (pascale-local o VM scratch) prima di
fidarsene in produzione — vedi sezione "Test periodico" in fondo.

## 0. Prerequisiti

- Accesso host prod, docker CLI, stack irccs-docker checked out.
- Chiave privata `age` per decifrare l'archivio (**non** risiede sull'host di backup — recuperarla dalla sua sede separata).
- Dump da ripristinare: locale (`backup/<hapi|keycloak|hapi-audit>/archive/*.dump.age`) o dalla copia offsite se il disco locale è perso.

**Disabilitare i timer di backup PRIMA di iniziare**, sempre, anche per un
test su ambiente scratch:

```bash
sudo systemctl stop irccs-backup.timer irccs-backup-verify.timer
```

Motivo: il timer notturno (03:15) o quello di verifica settimanale possono
scattare mentre il restore è a metà (DROP DATABASE → CREATE → pg_restore).
Un `pg_dump` lanciato su un DB a metà ricostruzione produce un dump
incoerente o fallisce a causa delle connessioni chiuse dal DROP — inquina
silenziosamente la catena di backup proprio nel momento più delicato. Il
lock in `run_backup_container.sh` impedisce due backup concorrenti tra
loro, ma non protegge da un backup che parte mentre un **restore manuale**
è in corso: quello è responsabilità dell'operatore, da qui.

Riattivare a restore concluso e verificato (§8):

```bash
sudo systemctl start irccs-backup.timer irccs-backup-verify.timer
```

## 1. Decidere il punto di restore

- RPO = 24h: si perdono al massimo le modifiche dall'ultimo backup notturno riuscito alle 03:15.
- Elenco backup disponibili: `ls -la backup/hapi/archive/ backup/keycloak/archive/ backup/hapi-audit/archive/` (locale) o dal target offsite.
- Se il disco locale è perso, recuperare prima da offsite (`rclone copy <target>/hapi/ ./restore-staging/` ecc.).

**Sospetto ransomware/tampering**: NON restorare ciecamente dall'ultimo
backup disponibile. Se l'incidente sembra un attacco (non un guasto hardware
semplice), stimare prima il momento di compromissione e scegliere un dump
precedente a quel momento, anche se più vecchio del RPO nominale di 24h — un
backup "fresco" generato dopo la compromissione può già contenere dati
manomessi o essere stato lui stesso il bersaglio. In caso di dubbio,
verificare più generazioni (`backup/<db>/archive/` tiene 14 giornalieri)
prima di scegliere quale restorare, e coinvolgere subito il referente
sicurezza/DPO prima di procedere.

## 2. Fermare i servizi applicativi (non i DB)

```bash
docker compose stop irccs-auth irccs-anagrafica-pazienti irccs-studio-clinico \
  irccs-centro-ricerca irccs-practitioner irccs-clinical-reasoning \
  irccs-notification irccs-tac irccs-zammad irccs-httpd-dashboard \
  irccs-hapi-audit irccs-audit-integrity
```

Evita scritture concorrenti durante il restore. I due container postgres restano su.

## 3. Decifrare il dump

```bash
age -d -i /path/alla/chiave-privata.txt \
  backup/hapi/archive/hapi_2026-09-14.dump.age > /tmp/hapi_restore.dump

age -d -i /path/alla/chiave-privata.txt \
  backup/keycloak/archive/keycloak_2026-09-14.dump.age > /tmp/keycloak_restore.dump

age -d -i /path/alla/chiave-privata.txt \
  backup/hapi-audit/archive/hapi-audit_2026-09-14.dump.age > /tmp/hapi_audit_restore.dump
```

## 4. Ricreare i DB e restorare (drop + create + pg_restore)

**Attenzione: operazione distruttiva, cancella i dati correnti nel DB target.**
Confermare di avere il dump giusto prima di procedere.

Questi due step sono ora gestiti da `backup/scripts/restore_db.sh`, che
sostituisce i comandi `psql`/`pg_restore` copia-incolla con uno script
protetto da conferma esplicita: prima di droppare qualunque cosa, mostra
hostname corrente, container target, DB target e dump da usare, e richiede
di **digitare per intero l'hostname della macchina corrente** per procedere
(oppure `--yes-i-am-sure=<hostname>` per uso scriptato/non interattivo — si
rifiuta se il valore non corrisponde esattamente all'hostname reale). Riduce
il rischio di eseguirlo per sbaglio contro l'host o il container sbagliato
(es. shell SSH aperta su prod invece che sullo scratch di test).

```bash
cd backup/scripts

# HAPI
./restore_db.sh hapi /tmp/hapi_restore.dump

# Keycloak
./restore_db.sh keycloak /tmp/keycloak_restore.dump

# Audit trail (hapiaudit) — attenzione: dopo restore la hash-chain riparte dal
# tail contenuto nel dump. Se l'incidente ha causato un fork della catena, va
# rivalutato con verify_audit_hash_chain.py prima di considerare l'audit trail
# integro (vedi memoria progetto hapi-identifier-modifier-broken).
./restore_db.sh hapi-audit /tmp/hapi_audit_restore.dump
```

Ogni invocazione chiede la conferma hostname separatamente (drop+create+
restore avvengono insieme per ciascun DB, non più in due fasi separate). Per
un restore scriptato/non presidiato, aggiungere `--yes-i-am-sure="$(hostname)"`
a ciascun comando — SOLO se si è certi di essere sull'host giusto, il flag
non aggiunge un livello di sicurezza in più rispetto al prompt interattivo,
lo sostituisce.

## 5. Restore

*(vedi sopra — drop+create+restore sono ora un'unica operazione per DB via `restore_db.sh`, non più due sezioni separate)*

## 6. Pulizia file decifrati in chiaro

```bash
shred -u /tmp/hapi_restore.dump /tmp/keycloak_restore.dump /tmp/hapi_audit_restore.dump
```

## 7. Riavvio ordinato

```bash
docker compose up -d irccs-keycloak
# attendere healthcheck keycloak OK, poi:
docker compose up -d irccs-hapi-fhir
# attendere che HAPI risponda su /fhir/metadata, poi:
docker compose up -d irccs-hapi-audit
# attendere che risponda su /fhir/metadata, poi il resto (irccs-audit-integrity
# incluso, riaggancia il tail della hash-chain al riavvio):
docker compose up -d
```

## 8. Verifica funzionale post-restore

- [ ] Login Keycloak (backoffice) con utente noto funziona
- [ ] `curl http://localhost:8080/fhir/metadata` risponde 200
- [ ] Query FHIR di prova (es. `GET /fhir/Patient?_count=1`) restituisce dati coerenti con la data del dump
- [ ] Dashboard React carica e mostra dati
- [ ] Controllo log per errori inattesi (Grafana/Loki)
- [ ] `irccs-hapi-audit` risponde su `/fhir/metadata`, hash-chain integra (`verify_audit_hash_chain.py`, nessun `AUDIT-INTEGRITY-STALE-CHECKPOINT`)

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
| 2026-09-16 | test (parziale) | hapi/keycloak dump del giorno, pascale-local | 20s (decifra+pg_restore+sanity; dump già pronto, non conta il dump) | OK | Dump generati con pipeline reale (`backup_nightly.sh` contro container pascale-local, offsite=none per assenza rclone in locale). Restore su 2 container postgres scratch isolati (non sulla stack pascale-local viva). Sanity: hapi `hfj_resource`=1338 righe (match dump), keycloak realm=2 (`master`,`pascale`). **Non coperto da questo test**: stop/riavvio ordinato della stack applicativa (playbook §2,7), verifica login/dashboard reali (§8) — da fare al prossimo test completo su VM scratch o pascale-local dedicato. |
