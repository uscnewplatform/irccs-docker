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

> **Per-environment.** This UUID is **not portable across realms/environments** (dev,
> preprod, prod each have a different one). The dashboard sends it as `scannerUserId`,
> read from `VITE_SCAN_SESSION_SCANNER_USER_ID` (see [Frontend integration](#frontend-integration)).
> If the value doesn't match a user in the target realm the endpoint returns
> `{"error":"scannerUserId not found in realm"}` (see [Troubleshooting](#troubleshooting)).

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

## Frontend integration

The React dashboard (`irccs-react-dashboard`) calls `POST {ms-host}/scan-session/generate`
when opening a patient page. The request body is built from runtime config
(`window.APP_CONFIG` in `httpd-config/config.js`, fallback `import.meta.env`,
fallback hardcoded dev defaults in `src/fhir/config.ts`):

| Body field      | Config key                          | Note |
|-----------------|-------------------------------------|------|
| `scannerUserId` | `VITE_SCAN_SESSION_SCANNER_USER_ID` | **Must** be the scanner user UUID of *this* environment's realm (step 1). |
| `clientId`      | `VITE_SCAN_SESSION_CLIENT_ID`       | OIDC client (default `irccs`). |
| `redirectUri`   | `VITE_SCAN_SESSION_REDIRECT_URI`    | Viewer callback URL. |
| `expiresIn`     | `VITE_SCAN_SESSION_EXPIRES_IN`      | Token TTL seconds (default 3600). |
| `state`         | `VITE_SCAN_SESSION_STATE`           | Default `scan-session`. |

**Per environment** set these in the deployed `config.js`:
- prod: `irccs-docker/httpd-config/config-prod.js`
- local: `pascale-local/httpd-config/config-local.js`

An empty `VITE_SCAN_SESSION_SCANNER_USER_ID` falls back to the dev default UUID,
which will not exist in a prod realm.

---

## Troubleshooting

**`{"error":"scannerUserId not found in realm"}`** when opening a patient page.

The `scannerUserId` sent by the dashboard has no matching user in the target realm.
Cause: `VITE_SCAN_SESSION_SCANNER_USER_ID` is unset (→ dev default UUID) or stale.

Fix:
1. In the target realm, find the scanner service-account user (step 1) and copy its UUID.
2. Set `VITE_SCAN_SESSION_SCANNER_USER_ID` to that UUID in the environment's `config.js`.
3. Reload the dashboard (no rebuild needed — runtime config).

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
