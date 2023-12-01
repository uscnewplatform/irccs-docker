FROM postgres:alpine3.18
ENV POSTGRES_DB fhir
COPY scripts/psql_setup.sql /docker-entrypoint-initdb.d/