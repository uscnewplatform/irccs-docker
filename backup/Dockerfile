# Immagine per il container one-shot che fa SOLO cifratura (age) + push
# offsite (rclone) + retention sui dump gia' verificati (dump e verify girano
# PRIMA, sull'host, via run_backup_container.sh — vedi quel file per il
# perche': questo container non deve avere ne' Docker CLI ne' accesso alla
# Docker API, per chiudere un vettore di escape verificato empiricamente in
# un'architettura precedente che instradava dump+verify qui dentro tramite
# un docker-socket-proxy).
#
# Niente postgres, niente docker-cli: pg_dump/pg_restore girano tutti dentro
# ai rispettivi container postgres (target o scratch) via `docker exec`
# dall'host, mai localmente qui. Serve solo age + rclone + un runtime bash
# minimale — base debian-slim invece di postgres:17, immagine piu' piccola e
# superficie ridotta.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       age \
       rclone \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /backup/scripts/
RUN chmod +x /backup/scripts/*.sh

WORKDIR /backup/scripts
ENTRYPOINT ["/backup/scripts/backup_nightly.sh"]
