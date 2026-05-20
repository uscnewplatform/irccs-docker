#!/bin/bash
# Eseguito solo al PRIMO avvio del container (data dir vuota).
# Per installazioni esistenti usare il comando manuale nel README.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER webpush WITH PASSWORD '$WEBPUSH_DB_PASSWORD';
    CREATE DATABASE webpush OWNER webpush;
    GRANT ALL PRIVILEGES ON DATABASE webpush TO webpush;
EOSQL
