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
#
# Digest e versioni pacchetto pinnate: senza pin, ogni rebuild puo' tirare
# dentro silenziosamente una versione diversa della base image o di age/
# rclone (drift non tracciato, build non riproducibile). Aggiornare qui
# deliberatamente quando serve una versione piu' recente, non lasciare che
# accada da solo ad ogni build.
FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       age=1.1.1-1+b3 \
       rclone=1.60.1+dfsg-2+b5 \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/ /backup/scripts/
RUN chmod +x /backup/scripts/*.sh

WORKDIR /backup/scripts
ENTRYPOINT ["/backup/scripts/backup_nightly.sh"]
