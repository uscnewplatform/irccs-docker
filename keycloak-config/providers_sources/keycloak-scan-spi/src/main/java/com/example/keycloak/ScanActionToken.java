package com.example.keycloak;

import com.fasterxml.jackson.annotation.JsonProperty;
import org.keycloak.authentication.actiontoken.DefaultActionToken;

/**
 * A short-lived, signed JWT that encodes a single scan session.
 */
public class ScanActionToken extends DefaultActionToken {

    public static final String TOKEN_TYPE = "scan-session";

    @JsonProperty("patientId")
    private String patientId;

    @JsonProperty("studyId")
    private String studyId;

    @JsonProperty("redirectUri")
    private String redirectUri;

    @JsonProperty("state")
    private String state;

    @SuppressWarnings("unused")
    private ScanActionToken() {
        super();
    }

    public ScanActionToken(String userId,
                           int    absoluteExpirationSecs,
                           String patientId,
                           String studyId,
                           String redirectUri,
                           String state) {
        super(userId, TOKEN_TYPE, absoluteExpirationSecs, null);
        this.patientId = patientId;
        this.studyId   = studyId;
        this.redirectUri = redirectUri;
        this.state = state;
    }

    @Override
    public org.keycloak.TokenCategory getCategory() {
        return org.keycloak.TokenCategory.ACCESS;
    }

    @Override
    public String serialize(org.keycloak.models.KeycloakSession session, org.keycloak.models.RealmModel realm, jakarta.ws.rs.core.UriInfo uriInfo) {
        // Find public hostname from environment or UriInfo
        String publicBaseUrl = System.getenv("KC_HOSTNAME_URL");
        if (publicBaseUrl == null || publicBaseUrl.isBlank()) {
            publicBaseUrl = uriInfo.getBaseUri().toString();
        }
        if (publicBaseUrl.endsWith("/")) {
            publicBaseUrl = publicBaseUrl.substring(0, publicBaseUrl.length() - 1);
        }

        // Set the issuer to the logical public name
        this.issuer = publicBaseUrl + "/realms/" + realm.getName();
        
        // Let Keycloak handle issuedFor (client_id) correctly
        return session.tokens().encode(this);
    }

    public String getPatientId() { return patientId; }
    public void   setPatientId(String patientId) { this.patientId = patientId; }

    public String getStudyId()   { return studyId; }
    public void   setStudyId(String studyId)     { this.studyId = studyId; }

    public String getRedirectUri() { return redirectUri; }
    public void   setRedirectUri(String redirectUri) { this.redirectUri = redirectUri; }

    public String getState() { return state; }
    public void   setState(String state) { this.state = state; }
}
