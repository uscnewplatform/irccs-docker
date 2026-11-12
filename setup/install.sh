#!/usr/bin/env bash
# Installazione di un cliente nuovo: lancia in ordine tutte le fasi automatizzabili DOPO che lo stack è avviato
# (docker compose up -d) e Keycloak/HAPI rispondono. Ogni fase vive in una cartella numerata di setup/ e ogni script
# è idempotente: si può rilanciare l'intero installer o ripartire da una fase (--from N).
#
#   10  Keycloak      ruoli e autorizzazioni mancanti dal realm-export (audit, DocumentReference, farmacovigilanza,
#                     blocco ticket CRF, Zammad, tipi FHIR instradati)
#   20  FHIR          SearchParameter custom, Patient Journey J-LI, tipi di consenso
#   30  Terminologie  librerie CRF (CTCAE, EORTC, EuroQol, PRO-CTCAE, PROFFIT) e farmaci AIFA
#   40  Zammad        attributi dei ticket, webhook e trigger delle email, spegnimento email native   (solo con --zammad-url)
#   50  Audit trail   partizione AUDIT, SearchParameter, trigger di immodificabilità, pgaudit          (solo con --with-audit)
#   60  Monitoraggio  cron di archiviazione Loki e sistema di backup DB (richiede sudo)                (solo con --with-ops)
#
# Uso:
#   ADMIN_PASS=<password admin Keycloak> ./setup/install.sh [opzioni]
#
# Opzioni (tra parentesi il default):
#   --hapi-url URL        HAPI FHIR clinico (http://localhost:8080/fhir)
#   --audit-hapi-url URL  HAPI FHIR dell'audit, per la fase 50 (http://localhost:8081/fhir)
#   --kc-url URL          Keycloak (http://localhost:9445)         --realm NOME (pascale)       --admin-user NOME (admin)
#   --zammad-url URL      abilita la fase 40 (richiede ZAMMAD_TOKEN e WEBHOOK_SECRET nell'ambiente)
#   --with-audit          abilita la fase 50          --with-ops   abilita la fase 60
#   --from N | --only N | --skip N[,N]   scelta delle fasi (10..60)
#   --yes                 non chiede conferma prima di ogni fase
#   --dry-run             stampa cosa lancerebbe, senza eseguire nulla
#
# Segreti SOLO dall'ambiente, mai da argomento (finirebbero in history e ps): ADMIN_PASS, ZAMMAD_TOKEN, WEBHOOK_SECRET.
# NON fa, resta manuale (vedi setup/README.md): SMTP/lingua/tema/client-secret in Keycloak, SSL, LOINC, utenti e centri.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

HAPI_URL="http://localhost:8080/fhir"; AUDIT_HAPI_URL="http://localhost:8081/fhir"
KC_URL="${KC_URL:-http://localhost:9445}"; REALM="${REALM:-pascale}"; ADMIN_USER="${ADMIN_USER:-admin}"
ZAMMAD_URL=""; WITH_AUDIT=0; WITH_OPS=0; ASSUME_YES=0; DRY=0; FROM=10; ONLY=""; SKIP=","
while [ $# -gt 0 ]; do
  case "$1" in
    --hapi-url) HAPI_URL="${2:?manca il valore}"; shift ;;
    --audit-hapi-url) AUDIT_HAPI_URL="${2:?manca il valore}"; shift ;;
    --kc-url) KC_URL="${2:?manca il valore}"; shift ;;
    --realm) REALM="${2:?manca il valore}"; shift ;;
    --admin-user) ADMIN_USER="${2:?manca il valore}"; shift ;;
    --zammad-url) ZAMMAD_URL="${2:?manca il valore}"; shift ;;
    --with-audit) WITH_AUDIT=1 ;;
    --with-ops) WITH_OPS=1 ;;
    --from) FROM="${2:?manca il valore}"; shift ;;
    --only) ONLY="${2:?manca il valore}"; shift ;;
    --skip) SKIP=",${2:?manca il valore},"; shift ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opzione sconosciuta: $1 (usa --help)" >&2; exit 2 ;;
  esac
  shift
done
HAPI_URL="${HAPI_URL%/}"; AUDIT_HAPI_URL="${AUDIT_HAPI_URL%/}"; KC_URL="${KC_URL%/}"
hostport() { local h="${1#http://}"; h="${h#https://}"; echo "${h%/fhir}"; }   # gli script vecchi vogliono "host:porta"
export KC_URL REALM ADMIN_USER

say()  { printf '\n\033[1m== Fase %s: %s\033[0m\n' "$1" "$2"; }
note() { printf '   %s\n' "$*"; }
run()  { printf '   \033[36m$\033[0m %s\n' "$*"; [ "$DRY" -eq 1 ] || "$@"; }
confirm() {
  [ "$ASSUME_YES" -eq 1 ] || [ "$DRY" -eq 1 ] && return 0
  read -r -p "   Procedo? [s/N] " a; [ "$a" = "s" ] || [ "$a" = "S" ]
}
selected() {  # $1 = numero fase
  case "$SKIP" in *",$1,"*) return 1 ;; esac
  if [ -n "$ONLY" ]; then [ "$ONLY" = "$1" ]; else [ "$1" -ge "$FROM" ]; fi
}
need() { [ -n "${!1:-}" ] || { echo "ERRORE: variabile $1 non impostata (da ambiente, non da argomento)" >&2; exit 1; }; }

# ---------------------------------------------------------------- controlli preliminari
for t in curl python3; do command -v "$t" >/dev/null || { echo "ERRORE: manca $t" >&2; exit 1; }; done
if [ "$DRY" -eq 0 ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "$HAPI_URL/metadata" || true)"
  [ "$code" = "200" ] || { echo "ERRORE: HAPI non raggiungibile su $HAPI_URL (risposta $code): lo stack è avviato?" >&2; exit 1; }
  code="$(curl -s -o /dev/null -w '%{http_code}' "$KC_URL/realms/$REALM/.well-known/openid-configuration" || true)"
  [ "$code" = "200" ] || { echo "ERRORE: realm $REALM non raggiungibile su $KC_URL (risposta $code): usa --kc-url/--realm" >&2; exit 1; }
fi
[ "$DRY" -eq 1 ] && note "DRY-RUN: nulla viene eseguito"

# ---------------------------------------------------------------- 10 Keycloak
if selected 10; then
  say 10 "Keycloak: ruoli e autorizzazioni mancanti dal realm-export"
  need ADMIN_PASS
  note "Gli script sono idempotenti: creano solo ciò che manca. Dopo l'installazione assegna i ruoli ai gruppi (UI) e rifai il login."
  if confirm; then
    for s in add-audit-trail-role.py add-documentreference-authz.py add-ticket-gate-roles.py add-zammad-authz.py; do run python3 "setup/10-keycloak/$s"; done
    run bash setup/10-keycloak/add-farmacovigilanza-role.sh
    run python3 setup/10-keycloak/sync-fhir-authz.py     # ultimo: copre i tipi FHIR instradati dal proxy e ancora senza autorizzazione
  fi
fi

# ---------------------------------------------------------------- 20 FHIR
if selected 20; then
  say 20 "FHIR: SearchParameter, Patient Journey J-LI, tipi di consenso"
  note "I SearchParameter vanno per primi: senza, alcune ricerche dei microservizi tornano vuote senza errori."
  if confirm; then
    run bash setup/20-fhir/install_searchparameters.sh "$(hostport "$HAPI_URL")"
    run bash setup/20-fhir/install_jli.sh "$HAPI_URL"
    run bash setup/20-fhir/install_consent_types.sh "$(hostport "$HAPI_URL")"
  fi
fi

# ---------------------------------------------------------------- 30 Terminologie
if selected 30; then
  say 30 "Terminologie: librerie CRF e farmaci AIFA"
  note "Bundle e CSV sono già nel repo (data-import/); le classi AIFA scaricano da aifa.gov.it solo se manca il CSV del mese."
  note "Ci vogliono alcuni minuti (159k concept di confezioni). Serve Python con 'requests' (PYTHON_BIN=.venv/bin/python)."
  if confirm; then run bash setup/30-terminologie/install_terminologie.sh "$HAPI_URL" tutto; fi
fi

# ---------------------------------------------------------------- 40 Zammad
if selected 40; then
  if [ -z "$ZAMMAD_URL" ]; then
    say 40 "Zammad: saltata (manca --zammad-url)"
  else
    say 40 "Zammad: attributi, webhook e trigger delle email, spegnimento email native"
    need ZAMMAD_TOKEN; need WEBHOOK_SECRET
    note "Prima crea l'attributo studyid e gli altri; Zammad può riavviare rails per qualche decina di secondi dopo la creazione."
    note "WEBHOOK_SECRET deve essere lo stesso di ZAMMAD_NOTIFICATIONS_WEBHOOK_SECRET del microservizio."
    if confirm; then
      run bash setup/40-zammad/install_zammad_attributes.sh "$ZAMMAD_URL"
      run bash setup/40-zammad/install_zammad_email_webhook.sh "$ZAMMAD_URL" --apply
      run bash setup/40-zammad/disable_zammad_native_emails.sh "$ZAMMAD_URL" --apply
      run bash setup/40-zammad/verify_zammad.sh "$ZAMMAD_URL"
    fi
  fi
fi

# ---------------------------------------------------------------- 50 Audit
if selected 50; then
  if [ "$WITH_AUDIT" -eq 0 ]; then
    say 50 "Audit trail: saltata (aggiungi --with-audit se l'audit è acceso: vedi docs audit-trail.adoc)"
  else
    say 50 "Audit trail: partizione AUDIT, SearchParameter, trigger di immodificabilità, pgaudit"
    note "Richiede lo store audit dedicato avviato (postgres-hapi-audit con l'immagine di postgres-audit-image/)."
    if confirm; then
      run bash setup/50-audit/setup_audit_partition.sh "$(hostport "$HAPI_URL")"
      run bash setup/50-audit/install_audit_searchparameter.sh "$(hostport "$AUDIT_HAPI_URL")"
      run bash setup/50-audit/install_audit_db_protection.sh
      run bash setup/50-audit/install_audit_pgaudit.sh
    fi
  fi
fi

# ---------------------------------------------------------------- 60 Monitoraggio e backup
if selected 60; then
  if [ "$WITH_OPS" -eq 0 ]; then
    say 60 "Monitoraggio e backup: saltata (aggiungi --with-ops; richiede sudo sull'host)"
  else
    say 60 "Monitoraggio e backup: cron Loki e backup DB"
    note "Il backup installa unit systemd e cifratura (age): leggi docs backup.adoc prima di confermare."
    if confirm; then
      run bash setup/60-monitoraggio/install_loki_archive_cron.sh
      run sudo bash backup/scripts/install.sh
    fi
  fi
fi

cat <<'EOT'

════════════════════════════════════════════════════════════
  Fasi automatiche terminate. Restano da fare A MANO:
════════════════════════════════════════════════════════════
  - Keycloak (UI): SMTP, lingua e tema, client-secret dell'applicazione, eventuale SSL
  - Assegnare ai gruppi i ruoli creati (Dashboard -> Gruppi utenti): internal:confirm:crf, internal:close:ticket, ...
  - Creare organizzazioni/centri e il primo superadmin
  - Zammad: segnare il token di servizio nell'.env del microservizio e riavviarlo
  - LOINC (opzionale): richiede account loinc.org, vedi docs/modules/ROOT/pages/installazione.adoc
  Indice completo e ordine: setup/README.md
EOT
