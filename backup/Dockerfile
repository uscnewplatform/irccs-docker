# Immagine per il container one-shot di backup DB (lanciato dal timer systemd
# tramite scripts/run_backup_container.sh). Contiene client postgres (pg_dump/
# pg_restore), Docker CLI (per exec/run/network verso i container sibling via
# /var/run/docker.sock montato), age (cifratura) e rclone (offsite).
#
# Base postgres:17: pg_dump client e' forward/backward compatibile con i
# server 16.x e 17.x usati dalla stack (hapi=16.8, keycloak=17.4) — non serve
# un'immagine per versione, e' lo stesso principio per cui verify_restore.sh
# usa immagini scratch dedicate PER il restore, non per il dump.
FROM postgres:17

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       docker-cli \
       age \
       rclone \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /backup/scripts/
RUN chmod +x /backup/scripts/*.sh

WORKDIR /backup/scripts
ENTRYPOINT ["/backup/scripts/backup_nightly.sh"]
