#!/usr/bin/env bash
#
# Crea/allinea i realm role della farmacovigilanza su un Keycloak GIA' AVVIATO
# (senza re-import del realm). Idempotente.
#
# Crea:
#   - internal:read:study-associated  (flag) -> abilita in Flow.java la visibilita'
#     per-associazione: l'utente vede pazienti/CRF di TUTTI i centri degli studi a
#     cui i suoi gruppi sono associati (group_ids sullo studio), non solo del proprio.
#   - opened_sae_email                (composite) -> profilo farmacovigilanza:
#       * internal:ui:patients (menu Pazienti)
#       * lettura (read/search) su patient, questionnaire, questionnaireresponse,
#         researchstudy, researchsubject, adverseevent, practitioner, group, organization
#       * lettura (read/search) strutture CRF/diario: careplan, activitydefinition,
#         plandefinition, observation, consent (per visualizzare i questionari)
#       * internal:read:study-associated + internal:read:group (visibilita')
#       * internal:create:group + task:create/read/search (apertura query/ticket)
#       * NESSUN create/update sulle CRF (questionnaireresponse), NESSUN
#         internal:read:organization (niente visibilita' dell'intero centro)
#
# NB: i sotto-ruoli elencati devono gia' esistere nel realm (lo sono nel realm pascale).
# I gruppi per-centro "<Org> Farmaco vigilanza" sono creati a runtime da OrganizationFlow
# alla creazione del centro; per i centri esistenti usare setup/backfill_farmacovigilanza.py.
#
# Uso:
#   KC_URL=http://localhost:9445 REALM=pascale \
#   ADMIN_USER=admin ADMIN_PASS=*** \
#   ./add-farmacovigilanza-role.sh
#
# Richiede: curl, jq.

set -euo pipefail

KC_URL="${KC_URL:-http://localhost:9445}"
REALM="${REALM:-pascale}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
ADMIN_REALM="${ADMIN_REALM:-master}"
NEW_ROLE="${NEW_ROLE:-opened_sae_email}"
FLAG_ROLE="internal:read:study-associated"

# Compositi curati del ruolo farmacovigilanza.
COMPOSITE_ROLES=(
  "internal:ui:patients"
  "internal:read:study-associated"
  "internal:read:group"
  "internal:create:group"
  "patient:read" "patient:search"
  "questionnaire:read" "questionnaire:search"
  "questionnaireresponse:read" "questionnaireresponse:search"
  "researchstudy:read" "researchstudy:search"
  "researchsubject:read" "researchsubject:search"
  "adverseevent:read" "adverseevent:search"
  "practitioner:read" "practitioner:search"
  "group:read" "group:search"
  "organization:read" "organization:search"
  # Lettura strutture CRF/diario per visualizzare i questionari del paziente
  # (CarePlan + ActivityDefinition + PlanDefinition), le linee terapeutiche
  # (Observation) e il consenso (Consent). Solo read/search: nessuna modifica CRF.
  "careplan:read" "careplan:search"
  "activitydefinition:read" "activitydefinition:search"
  "plandefinition:read" "plandefinition:search"
  "observation:read" "observation:search"
  "consent:read" "consent:search"
  "task:create" "task:read" "task:search"
)

command -v jq >/dev/null || { echo "ERRORE: jq non installato"; exit 1; }

echo "Keycloak : $KC_URL"
echo "Realm    : $REALM"
echo "Ruolo    : $NEW_ROLE"
echo

# ── 1. Token admin ──────────────────────────────────────────────────────────
TOKEN=$(curl -fsS -X POST \
  "$KC_URL/realms/$ADMIN_REALM/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASS" \
  -d "grant_type=password" | jq -r .access_token)

[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "ERRORE: login admin fallito"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

api() { curl -fsS "${AUTH[@]}" -H "Content-Type: application/json" "$@"; }

# urlencode minimale per i nomi ruolo con ':'
enc() { jq -rn --arg s "$1" '$s|@uri'; }

# ── 2. Crea il flag internal:read:study-associated (idempotente) ─────────────
if api "$KC_URL/admin/realms/$REALM/roles/$(enc "$FLAG_ROLE")" >/dev/null 2>&1; then
  echo "Flag '$FLAG_ROLE' gia' presente."
else
  echo "Creo flag '$FLAG_ROLE'."
  api -X POST "$KC_URL/admin/realms/$REALM/roles" \
    -d "{\"name\":\"$FLAG_ROLE\",\"description\":\"Abilita la visibilita' read/search sulle risorse di tutti i centri degli studi a cui i gruppi dell'utente sono associati\",\"composite\":false}" >/dev/null
fi

# ── 3. Crea il ruolo composito opened_sae_email (idempotente) ────────────────
if api "$KC_URL/admin/realms/$REALM/roles/$(enc "$NEW_ROLE")" >/dev/null 2>&1; then
  echo "Ruolo '$NEW_ROLE' gia' presente, allineo i compositi."
else
  echo "Creo ruolo '$NEW_ROLE'."
  api -X POST "$KC_URL/admin/realms/$REALM/roles" \
    -d "{\"name\":\"$NEW_ROLE\",\"description\":\"Farmacovigilanza: lettura pazienti/CRF di tutti i centri degli studi associati + apertura query/ticket\",\"composite\":true}" >/dev/null
fi

# ── 4. Costruisci la lista di RoleRepresentation dei compositi ───────────────
COMPOSITES_JSON="[]"
for role in "${COMPOSITE_ROLES[@]}"; do
  rep=$(api "$KC_URL/admin/realms/$REALM/roles/$(enc "$role")" 2>/dev/null || true)
  if [ -z "$rep" ] || [ "$(echo "$rep" | jq -r '.name // empty')" = "" ]; then
    echo "  ATTENZIONE: sotto-ruolo '$role' non trovato nel realm, lo salto."
    continue
  fi
  COMPOSITES_JSON=$(jq -c --argjson r "$rep" '. + [$r]' <<<"$COMPOSITES_JSON")
done

N=$(echo "$COMPOSITES_JSON" | jq 'length')
echo "Compositi risolti: $N"

# ── 5. Assegna i compositi (POST e' additivo/idempotente) ────────────────────
api -X POST "$KC_URL/admin/realms/$REALM/roles/$(enc "$NEW_ROLE")/composites" \
  -d "$COMPOSITES_JSON" >/dev/null

echo
echo "FATTO. Ruolo '$NEW_ROLE' allineato con $N compositi + flag '$FLAG_ROLE'."
echo "Assegna il ruolo agli utenti via gruppo '<Org> Farmaco vigilanza' (creato da OrganizationFlow / backfill)."
