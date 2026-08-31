# Postgres per lo store audit dedicato, con estensione pgaudit per loggare
# anche le LETTURE dirette via SQL (i trigger in audit_db_protection.sql
# bloccano solo scritture/cancellazioni - non impediscono, e non tracciano,
# una SELECT diretta con credenziali DB). Vedi docs/modules/ROOT/pages/audit-trail.adoc.
ARG POSTGRES_HAPI_VERSION=16.8
FROM postgres:${POSTGRES_HAPI_VERSION}

# postgresql-<major>-pgaudit deve combaciare con la major version dell'immagine base.
RUN PG_MAJOR="$(echo "$PG_VERSION" | cut -d. -f1)" \
    && apt-get update \
    && apt-get install -y --no-install-recommends "postgresql-${PG_MAJOR}-pgaudit" \
    && rm -rf /var/lib/apt/lists/*
