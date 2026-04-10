# keycloak-scan-spi

Keycloak SPI that enables **scan-session authentication** for third-party viewer apps.

A coordinator backend generates a signed, short-lived **action token** containing
`patientId` and `studyId`. A viewer app presents that token to Keycloak, which
authenticates it and issues a bearer JWT scoped to those two claims only.
Each scan is its own isolated Keycloak session.

---

## Components

| Class | Role |
|---|---|
| `ScanActionToken` | JWT data model (signed by Keycloak's realm key) |
| `ScanActionTokenHandler` | Validates the action token, stamps session notes, completes login |
| `ScanClaimsMapper` | Injects `patientId` / `studyId` into the bearer JWT |
| `ScanSessionResourceProvider` | REST endpoint — `POST /realms/{realm}/scan-session/generate` |
| `ScanSessionResourceProviderFactory` | Registers the REST resource with Keycloak |

---

## Build

Requires Java 17+ and Maven 3.8+. Match `keycloak.version` in `pom.xml` to your server.

```bash
mvn clean package -DskipTests
# → target/keycloak-scan-spi-1.0.0.jar
```

---

## Deploy

### Docker (recommended)

```bash
docker build -t my-keycloak-with-scan-spi .
```

### Existing Keycloak instance

```bash
cp target/keycloak-scan-spi-1.0.0.jar /opt/keycloak/providers/
/opt/keycloak/bin/kc.sh build   # re-augment; then restart
```

---

## Keycloak configuration (one-time setup)

### 1. Create the scanner service account user

In the target realm, create a user (e.g. `scanner-service`) that will own all scan sessions.
Copy its Keycloak user-id (UUID) — you'll need it when generating tokens.

### 2. Create the `scanner-client` OIDC client

- Client ID: `scanner-client`
- Client authentication: **OFF** (public client — the viewer app is a browser/native app)
- Valid redirect URIs: the viewer app's callback URL
- **Standard Flow**: enabled
- **Direct Access Grants**: disabled (not needed)

### 3. Create the `scan` client scope

Clients → Client Scopes → Create client scope
- Name: `scan`
- Type: Optional
- In **Mappers** tab → Add mapper → From mapper list → **Scan Claims (patientId / studyId)**

Assign this scope to `scanner-client`:
Clients → scanner-client → Client Scopes → Add client scope → `scan` (set as Default)

### 4. Remove unwanted standard scopes from scanner-client

Clients → scanner-client → Client Scopes:
- Remove `profile`, `email`, `address`, `phone`, `roles` from *Assigned Default Scopes*
- Keep only `openid` and `scan`

This ensures the bearer JWT contains **only** `{ patientId, studyId, sub, iss, exp, aud }`.

---

## Usage

### Step 1 — Generate a scan action token (from your coordinator service)

```bash
# First, get a service-account token for the coordinator
COORDINATOR_TOKEN=$(curl -s -X POST \
  "https://keycloak/realms/myrealm/protocol/openid-connect/token" \
  -d "client_id=coordinator-client" \
  -d "client_secret=YOUR_SECRET" \
  -d "grant_type=client_credentials" \
  | jq -r .access_token)

# Generate the scan action token
curl -s -X POST \
  "https://keycloak/realms/myrealm/scan-session/generate" \
  -H "Authorization: Bearer $COORDINATOR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "patientId":     "PAT-001",
    "studyId":       "1.2.840.10008.5.1.4.1.1.4.20240101",
    "scannerUserId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "expiresIn":     3600,
    "clientId":      "scanner-client"
  }'
```

Response:
```json
{
  "actionTokenUrl": "https://keycloak/realms/myrealm/login-actions/action-token?key=eyJ...&client_id=scanner-client",
  "expiresIn": 3600
}
```

### Step 2 — Viewer app opens the actionTokenUrl

The viewer opens the URL in a browser / webview. Keycloak:
1. Verifies the JWT signature and expiry
2. Calls `ScanActionTokenHandler` — stamps session notes, completes login
3. Redirects back to the viewer's `redirect_uri` with an auth `code`

### Step 3 — Viewer exchanges code for bearer JWT

```bash
curl -s -X POST \
  "https://keycloak/realms/myrealm/protocol/openid-connect/token" \
  -d "grant_type=authorization_code" \
  -d "client_id=scanner-client" \
  -d "code=AUTH_CODE_FROM_REDIRECT" \
  -d "redirect_uri=https://viewer.example.com/callback"
```

The resulting JWT payload:
```json
{
  "iss":       "https://keycloak/realms/myrealm",
  "sub":       "scanner-service-user-id",
  "aud":       "scanner-client",
  "exp":       1712345678,
  "patientId": "PAT-001",
  "studyId":   "1.2.840.10008.5.1.4.1.1.4.20240101"
}
```

### Step 4 — Viewer uses the bearer token for API calls

```bash
curl -H "Authorization: Bearer <access_token>" \
     "https://scan-api.example.com/dicom/study/PAT-001"
```

Your resource server validates the JWT and reads `patientId` / `studyId` from claims.

---

## Multiple concurrent scans

Each call to `/scan-session/generate` produces a **separate** signed action token.
Each token bootstraps its own independent Keycloak `UserSession`.
Sessions are isolated — different bearer tokens, different `session_state` values.
Concurrent scans for the same patient on different workstations work without interference.

---

## Security notes

- The action token URL is single-use (Keycloak invalidates it after first redemption).
- Set `expiresIn` to the minimum useful window (e.g. 300s if the viewer opens immediately).
- The scanner-client should have no roles, no profile/email scopes — bearer tokens are claim-minimal by design.
- The generate endpoint should be protected: only your coordinator service (authenticated via client credentials) should call it. Add a realm role `scan-generator` and enforce it in the handler if needed.
- All tokens are RS256-signed by Keycloak's realm key. Rotation is handled by Keycloak automatically.
