# Postgres per lo store audit dedicato, con estensione pgaudit per loggare
# anche le LETTURE dirette via SQL (i trigger in audit_db_protection.sql
# bloccano solo scritture/cancellazioni - non impediscono, e non tracciano,
# una SELECT diretta con credenziali DB). Vedi docs/modules/ROOT/pages/audit-trail.adoc.
ARG POSTGRES_HAPI_VERSION=16.8
FROM postgres:${POSTGRES_HAPI_VERSION}

# postgresql-<major>-pgaudit deve combaciare con la major version dell'immagine base.
# PG_MAJOR e' gia' esportato dall'immagine ufficiale postgres - non ricavarlo da PG_VERSION
# (fragile: assume che il primo campo prima del punto sia sempre la major version).
RUN apt-get update \
    && apt-get install -y --no-install-recommends "postgresql-${PG_MAJOR}-pgaudit" \
    && rm -rf /var/lib/apt/lists/*
