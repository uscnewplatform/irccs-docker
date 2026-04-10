package com.example.keycloak;

import org.jboss.logging.Logger;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.services.resource.RealmResourceProvider;

import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.core.UriInfo;
import jakarta.ws.rs.core.Context;

import java.time.Instant;
import java.util.Map;

/**
 * Custom REST endpoint exposed at:
 *
 *   POST /realms/{realm}/scan-session/generate
 *
 * Called by your coordinator microservice (authenticated as a service account
 * with the realm-admin or a dedicated "scan-generator" role).
 *
 * Request body (JSON):
 * {
 *   "patientId"    : "PAT-001",
 *   "studyId"      : "1.2.840.10008.5.1.4.1.1.4",
 *   "scannerUserId": "<keycloak-user-id of the scanner service account>",
 *   "expiresIn"    : 3600        // optional, seconds, default 3600
 * }
 *
 * Response (JSON):
 * {
 *   "actionTokenUrl": "https://keycloak/realms/.../login-actions/action-token?key=..."
 * }
 *
 * The viewer app opens that URL in a browser / webview. Keycloak validates
 * the signed JWT and hands off to ScanActionTokenHandler.
 */
public class ScanSessionResourceProvider implements RealmResourceProvider {

    private static final Logger LOG = Logger.getLogger(ScanSessionResourceProvider.class);

    private static final int DEFAULT_EXPIRY_SECS = 3600;

    private final KeycloakSession session;

    public ScanSessionResourceProvider(KeycloakSession session) {
        this.session = session;
    }

    @Override
    public Object getResource() {
        return this; // "this" is the JAX-RS resource
    }

    @Override
    public void close() { /* nothing to close */ }

    // ── REST endpoint ──────────────────────────────────────────────────────

    @POST
    @Path("generate")
    @Consumes(MediaType.APPLICATION_JSON)
    @Produces(MediaType.APPLICATION_JSON)
    public Response generate(@Context UriInfo uriInfo, GenerateRequest req) {

        RealmModel realm = session.getContext().getRealm();

        // ── 1. Validate input ──────────────────────────────────────────────
        if (req == null) {
            return badRequest("Request body is required");
        }
        if (req.patientId == null || req.patientId.isBlank()) {
            return badRequest("patientId is required");
        }
        if (req.studyId == null || req.studyId.isBlank()) {
            return badRequest("studyId is required");
        }
        if (req.scannerUserId == null || req.scannerUserId.isBlank()) {
            return badRequest("scannerUserId is required");
        }

        // ── 2. Look up the scanner service account ─────────────────────────
        UserModel scannerUser = session.users().getUserById(realm, req.scannerUserId);
        if (scannerUser == null) {
            return badRequest("scannerUserId not found in realm");
        }
        if (!scannerUser.isEnabled()) {
            return badRequest("scannerUserId is disabled");
        }

        // ── 3. Check for existing stable token ────────────────────────────
        String attrKey = "scan_token_" + req.patientId + "_" + req.studyId;
        if (req.force == null || !req.force) {
            String existingAttr = scannerUser.getFirstAttribute(attrKey);
            if (existingAttr != null && existingAttr.contains("::")) {
                String[] parts = existingAttr.split("::");
                if (parts.length == 2) {
                    try {
                        String url = parts[0];
                        long expiry = Long.parseLong(parts[1]);
                        long now = Instant.now().getEpochSecond();
                        
                        // If it's still valid with at least 60s grace, return the cached one
                        if (expiry > (now + 60)) {
                            LOG.infof("Returning existing stable token for patientId=%s studyId=%s", req.patientId, req.studyId);
                            return Response.ok(Map.of(
                                    "actionTokenUrl", url,
                                    "expiresIn",      (int)(expiry - now)
                            ))
                            .header("Access-Control-Allow-Origin", "*")
                            .header("Access-Control-Allow-Methods", "POST, OPTIONS")
                            .header("Access-Control-Allow-Headers", "Content-Type, Authorization")
                            .build();
                        }
                    } catch (NumberFormatException e) {
                        LOG.warnf("Malformed stable token attribute for patientId=%s: %s", req.patientId, existingAttr);
                    }
                }
            }
        }

        // ── 4. Build and sign the action token ────────────────────────────
        int expiresIn = (req.expiresIn != null && req.expiresIn > 0)
                        ? req.expiresIn
                        : DEFAULT_EXPIRY_SECS;

        int absoluteExpiry = (int) Instant.now().getEpochSecond() + expiresIn;

        ScanActionToken actionToken = new ScanActionToken(
                req.scannerUserId,
                absoluteExpiry,
                req.patientId,
                req.studyId,
                req.redirectUri,
                req.state
        );

        // Logic to find the public hostname
        String publicBaseUrl = System.getenv("KC_HOSTNAME_URL");
        if (publicBaseUrl == null || publicBaseUrl.isBlank()) {
            publicBaseUrl = session.getContext().getUri().getBaseUri().toString();
        }
        if (publicBaseUrl.endsWith("/")) {
            publicBaseUrl = publicBaseUrl.substring(0, publicBaseUrl.length() - 1);
        }

        String realmBaseUrl = publicBaseUrl + "/realms/" + realm.getName();
        
        // MANUALLY set issuer and audience to match Keycloak's logical name
        actionToken.issuer(realmBaseUrl);
        actionToken.audience(realmBaseUrl);

        // ── 5. Build the action-token URL ─────────────────────────────────
        String clientId = (req.clientId != null && !req.clientId.isBlank())
                          ? req.clientId
                          : "scanner-client";

        // Set the client ID so the token is redeemable by this client
        actionToken.issuedFor(clientId);

        // serialize() signs the JWT with the realm's active key pair.
        String tokenString = actionToken.serialize(session, realm, uriInfo);

        String actionTokenUrl = realmBaseUrl + "/login-actions/action-token"
                + "?key=" + tokenString
                + "&client_id=" + clientId;

        // ── 6. Save stable token to user attributes ───────────────────────
        scannerUser.setAttribute(attrKey, java.util.List.of(actionTokenUrl + "::" + absoluteExpiry));

        LOG.infof("Generated new stable scan action token: patientId=%s studyId=%s expiresIn=%ds force=%b",
                  req.patientId, req.studyId, expiresIn, req.force);

        return Response.ok(Map.of(
                "actionTokenUrl", actionTokenUrl,
                "expiresIn",      expiresIn
        ))
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "POST, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        .build();
    }

    @OPTIONS
    @Path("{any:.*}")
    public Response preflight() {
        return Response.ok()
                .header("Access-Control-Allow-Origin", "*")
                .header("Access-Control-Allow-Methods", "POST, OPTIONS")
                .header("Access-Control-Allow-Headers", "Content-Type, Authorization")
                .header("Access-Control-Max-Age", "86400")
                .build();
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private Response badRequest(String message) {
        return Response.status(Response.Status.BAD_REQUEST)
                       .entity(Map.of("error", message))
                       .build();
    }

    // ── Request DTO ────────────────────────────────────────────────────────

    /**
     * JSON body for POST /scan-session/generate.
     * Public fields are fine here; Jackson maps them automatically.
     */
    public static class GenerateRequest {
        public String  patientId;
        public String  studyId;
        public String  scannerUserId;
        public Integer expiresIn;   // seconds, optional
        public String  clientId;    // optional, defaults to "scanner-client"
        public String  redirectUri; // optional
        public String  state;       // optional
        public Boolean force;       // optional
    }
}
