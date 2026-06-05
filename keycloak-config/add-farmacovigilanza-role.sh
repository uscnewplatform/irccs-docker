#!/usr/bin/env bash
#
# Crea il realm role 'farmacovigilanza' clonando i compositi di 'radiologo'.
#
# Il ruolo farmacovigilanza eredita gli stessi permessi del radiologo:
#   - read/search su tutte le risorse cliniche (Patient, QuestionnaireResponse,
#     Questionnaire, CarePlan, Observation, ...)
#   - internal:ui:patients (vede solo il menu Pazienti)
#   - internal:read:group + internal:read:organization (vede i pazienti di
#     tutti i centri dello studio)
#   - nessun create/update/delete su risorse cliniche
#   - apertura ticket (come radiologo)
#
# I ruoli Keycloak sono additivi: un utente con anche altri ruoli ottiene
# l'unione dei permessi.
#
# Uso:
#   KC_URL=http://localhost:9445 REALM=pascale \
#   ADMIN_USER=admin ADMIN_PASS=*** \
#   ./add-farmacovigilanza-role.sh
#   
# Opzionale: CREATE_GROUP=true crea anche il gruppo /Farmacovigilanza col ruolo.
#
# Richiede: curl, jq.

set -euo pipefail

KC_URL="${KC_URL:-http://localhost:9445}"
REALM="${REALM:-pascale}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"
ADMIN_REALM="${ADMIN_REALM:-master}"
SRC_ROLE="${SRC_ROLE:-radiologo}"
NEW_ROLE="${NEW_ROLE:-farmacovigilanza}"
CREATE_GROUP="${CREATE_GROUP:-false}"

command -v jq >/dev/null || { echo "ERRORE: jq non installato"; exit 1; }

echo "Keycloak : $KC_URL"
echo "Realm    : $REALM"
echo "Clono    : $SRC_ROLE -> $NEW_ROLE"
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

# ── 2. Verifica ruolo sorgente ───────────────────────────────────────────────
if ! api "$KC_URL/admin/realms/$REALM/roles/$SRC_ROLE" >/dev/null 2>&1; then
  echo "ERRORE: ruolo sorgente '$SRC_ROLE' non trovato nel realm $REALM"
  exit 1
fi

# ── 3. Crea il nuovo ruolo (idempotente) ─────────────────────────────────────
if api "$KC_URL/admin/realms/$REALM/roles/$NEW_ROLE" >/dev/null 2>&1; then
  echo "Ruolo '$NEW_ROLE' gia' presente, procedo ad allineare i compositi."
else
  echo "Creo ruolo '$NEW_ROLE'."
  api -X POST "$KC_URL/admin/realms/$REALM/roles" \
    -d "{\"name\":\"$NEW_ROLE\",\"description\":\"Farmacovigilanza: read-only clinico come radiologo + apertura ticket\",\"composite\":true}" >/dev/null
fi

# ── 4. Copia i compositi di radiologo nel nuovo ruolo ─────────────────────────
COMPOSITES=$(api "$KC_URL/admin/realms/$REALM/roles/$SRC_ROLE/composites")
N=$(echo "$COMPOSITES" | jq 'length')
echo "Compositi di '$SRC_ROLE': $N"

# POST accetta la lista di RoleRepresentation cosi' com'e' (id+name bastano)
api -X POST "$KC_URL/admin/realms/$REALM/roles/$NEW_ROLE/composites" \
  -d "$COMPOSITES" >/dev/null

echo "Compositi assegnati a '$NEW_ROLE'."

# ── 5. (opzionale) Gruppo Farmacovigilanza col ruolo ─────────────────────────
if [ "$CREATE_GROUP" = "true" ]; then
  echo "Creo gruppo '/$NEW_ROLE' (se assente) e assegno il ruolo."
  api -X POST "$KC_URL/admin/realms/$REALM/groups" \
    -d "{\"name\":\"$NEW_ROLE\"}" >/dev/null 2>&1 || true
  GID=$(api "$KC_URL/admin/realms/$REALM/groups?search=$NEW_ROLE" | jq -r ".[] | select(.name==\"$NEW_ROLE\") | .id" | head -1)
  ROLE_JSON=$(api "$KC_URL/admin/realms/$REALM/roles/$NEW_ROLE")
  api -X POST "$KC_URL/admin/realms/$REALM/groups/$GID/role-mappings/realm" \
    -d "[$ROLE_JSON]" >/dev/null
  echo "Gruppo '/$NEW_ROLE' -> ruolo '$NEW_ROLE' assegnato (group id: $GID)."
fi

echo
echo "FATTO. Ruolo '$NEW_ROLE' creato clonando '$SRC_ROLE' ($N compositi)."
echo "Assegna il ruolo (o il gruppo) agli utenti di farmacovigilanza dalla console Keycloak."
