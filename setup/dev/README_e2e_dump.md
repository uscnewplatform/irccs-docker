# Dump di test per il gate E2E

Cartella sull'host Jenkins: `/opt/jenkins/home/e2e-dump/` (nel container: `/var/jenkins_home/e2e-dump`, variabile `DUMP_DIR`).

## Contenuto
- `keycloak.dump`, `hapi.dump` (obbligatori) e `hapi-audit.dump` (opzionale: se manca l'audit store parte vuoto): formato `pg_dump -Fc`. Solo dati sintetici.
- `.env.ci`: copia di `.env_example` con:
  - versioni develop di tutti i servizi;
  - `KC_HOSTNAME` = host senza schema e `KC_HOSTNAME_URL` = `http://<host>` (solo HTTP);
  - client secret Keycloak coerente con il dump;
  - `quarkus.mailer.host=mailpit`, `quarkus.mailer.port=1025`, `quarkus.mailer.mock=false`;
  - nessuna password reale nel repository.

## Requisiti del dump
I client Keycloak devono avere redirect URI e web origins validi per `http://<host>/*`.

## Aggiornamento
Sostituire i file in `/opt/jenkins/home/e2e-dump/` (i sha256 vengono stampati a ogni restore).
