#!/usr/bin/env bash
# ============================================================
# generate-versions-env.sh — Genera versions.json dalle variabili
# IRCCS_*_VERSION di un .env (staging/prod: versioni pinnate delle
# immagini, source of truth per il deploy). Letto dalla pagina
# pubblica /versions di irccs-react-dashboard.
#
# Uso: generate-versions-env.sh <path/.env> <path/versions.json>
# Chiamato automaticamente da Deploy-Stack-Jenkinsfile,
# Deploy-Service-Jenkinsfile e Deploy-Preprod-Jenkinsfile (irccs-jenkinsfile)
# ad ogni deploy — non richiede intervento manuale.
# ============================================================
set -euo pipefail

ENV_FILE="${1:?uso: generate-versions-env.sh <env-file> <out-file>}"
OUT_FILE="${2:?uso: generate-versions-env.sh <env-file> <out-file>}"

if [ ! -f "$ENV_FILE" ]; then
  echo "generate-versions-env.sh: env file non trovato: $ENV_FILE" >&2
  exit 1
fi

declare -A LABELS=(
  [IRCCS_AUTH_VERSION]="irccs-microservice-auth"
  [IRCCS_ANAGRAFICA_VERSION]="irccs-microservice-anagrafica-pazienti"
  [IRCCS_CLINICAL_REASONING_VERSION]="irccs-microservice-clinical-reasoning"
  [IRCCS_CENTRO_RICERCA_VERSION]="irccs-microservice-centro-ricerca"
  [IRCCS_NOTIFICATION_VERSION]="irccs-microservice-notification"
  [IRCCS_PATIENT_INTERVIEW_VERSION]="irccs-microservice-patient-interview"
  [IRCCS_PRACTITIONER_VERSION]="irccs-microservice-practitioner"
  [IRCCS_STUDIO_CLINICO_VERSION]="irccs-microservice-studio-clinico"
  [IRCCS_TAC_VERSION]="irccs-microservice-tac"
  [IRCCS_ZAMMAD_VERSION]="irccs-microservice-zammad"
  [IRCCS_WEBPUSH_VERSION]="irccs-microservice-webpush"
  [IRCCS_HTTPD_VERSION]="irccs-react-dashboard"
  [IRCCS_ANTORA_DOCS_VERSION]="irccs-antora-docs"
  [IRCCS_PWA_VERSION]="irccs-pwa"
  [HAPI_IMAGE_VERSION]="hapi-fhir"
  [KEYCLOAK_IMAGE_VERSION]="keycloak"
)

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

first=true
{
  echo "{"
  echo "  \"generatedAt\": \"$(date -u +%Y-%m-%d)\","
  echo "  \"modules\": ["
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^(IRCCS_[A-Z0-9_]*_VERSION|HAPI_IMAGE_VERSION|KEYCLOAK_IMAGE_VERSION)$ ]] || continue
    name="${LABELS[$key]:-$key}"
    if [ "$first" = false ]; then
      echo ","
    fi
    first=false
    printf '    {"name": "%s", "version": "%s"}' "$name" "$value"
  done < <(grep -E '^(IRCCS_[A-Z0-9_]*_VERSION|HAPI_IMAGE_VERSION|KEYCLOAK_IMAGE_VERSION)=' "$ENV_FILE")
  echo ""
  echo "  ]"
  echo "}"
} > "$TMP_FILE"

chmod 644 "$TMP_FILE"
mv "$TMP_FILE" "$OUT_FILE"
echo "versions.json generato -> $OUT_FILE"
