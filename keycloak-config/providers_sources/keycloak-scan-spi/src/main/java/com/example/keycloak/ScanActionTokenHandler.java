package com.example.keycloak;

import org.jboss.logging.Logger;
import org.keycloak.authentication.actiontoken.AbstractActionTokenHandler;
import org.keycloak.authentication.actiontoken.ActionTokenContext;
import org.keycloak.authentication.actiontoken.ActionTokenHandlerFactory;
import org.keycloak.events.Errors;
import org.keycloak.events.EventType;
import org.keycloak.models.AuthenticatedClientSessionModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.protocol.LoginProtocol;
import org.keycloak.protocol.oidc.utils.RedirectUtils;
import org.keycloak.services.managers.AuthenticationManager;
import org.keycloak.services.util.DefaultClientSessionContext;
import org.keycloak.sessions.AuthenticationSessionModel;

import jakarta.ws.rs.core.Response;
import java.net.URI;

/**
 * Handles the action token when the third-party viewer hits:
 *
 *   GET /realms/{realm}/login-actions/action-token?key=<signed-jwt>&client_id=scanner-client
 *
 * What this handler does:
 *  1. Keycloak has already verified the JWT signature and expiry before calling us.
 *  2. We look up the scanner service account user.
 *  3. We stamp patientId + studyId as user-session notes so the Protocol Mapper
 *     can later inject them into every bearer JWT issued for this session.
 *  4. We complete the login, producing an auth-code redirect back to the viewer.
 *
 * The viewer exchanges the code for a bearer token via the normal OIDC token endpoint.
 * The resulting bearer token will contain ONLY { patientId, studyId, exp, aud }
 * because the scanner-client scope is stripped of all other standard claims.
 */
public class ScanActionTokenHandler
        extends AbstractActionTokenHandler<ScanActionToken>
        implements ActionTokenHandlerFactory<ScanActionToken> {

    private static final Logger LOG = Logger.getLogger(ScanActionTokenHandler.class);

    /** Must match ScanActionToken.TOKEN_TYPE and the services file entry. */
    public static final String PROVIDER_ID = ScanActionToken.TOKEN_TYPE;

    public ScanActionTokenHandler() {
        super(
            ScanActionToken.TOKEN_TYPE,
            ScanActionToken.class,
            "scanSessionExpired",   // message key shown on expiry page
            EventType.EXECUTE_ACTION_TOKEN,
            Errors.EXPIRED_CODE
        );
    }

    // ── ActionTokenHandlerFactory ──────────────────────────────────────────

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public AbstractActionTokenHandler<ScanActionToken> create(KeycloakSession session) {
        return new ScanActionTokenHandler();
    }

    // ── AbstractActionTokenHandler ────────────────────────────────────────

    @Override
    public Response handleToken(ScanActionToken token,
                                ActionTokenContext<ScanActionToken> ctx) {

        KeycloakSession          session     = ctx.getSession();
        RealmModel               realm       = ctx.getRealm();
        AuthenticationSessionModel authSession = ctx.getAuthenticationSession();

        LOG.infof("Handling scan action token: patientId=%s studyId=%s userId=%s",
                  token.getPatientId(), token.getStudyId(), token.getUserId());
        LOG.infof("Token exp=%d iat=%s", token.getExpiration(), token.getIat());
        LOG.infof("AuthSession ID=%s Client=%s", authSession.getParentSession().getId(), authSession.getClient().getClientId());

        try {
            // ── 1. Resolve the user (scanner service account) ─────────────────
        UserModel user = session.users().getUserById(realm, token.getUserId());
        if (user == null) {
            LOG.warnf("Scan token references unknown userId=%s", token.getUserId());
            return ctx.getSession()
                      .getProvider(org.keycloak.forms.login.LoginFormsProvider.class)
                      .setError("User not found")
                      .createErrorPage(Response.Status.BAD_REQUEST);
        }
        if (!user.isEnabled()) {
            LOG.warnf("Scan token references disabled userId=%s", token.getUserId());
            return ctx.getSession()
                      .getProvider(org.keycloak.forms.login.LoginFormsProvider.class)
                      .setError("User is disabled")
                      .createErrorPage(Response.Status.BAD_REQUEST);
        }

        // ── 2. Stamp scan metadata onto the auth/user session ─────────────
        //    The Protocol Mapper (ScanClaimsMapper) reads these notes when
        //    Keycloak mints the bearer JWT for the viewer app.
        authSession.setUserSessionNote(ScanClaimsMapper.NOTE_PATIENT_ID, token.getPatientId());
        authSession.setUserSessionNote(ScanClaimsMapper.NOTE_STUDY_ID,   token.getStudyId());

        // ── 3. Set the authenticated user on the session ───────────────────
        authSession.setAuthenticatedUser(user);

        // ── 4. Handle Redirect URI and State ──────────────────────────────
        String redirectUri = token.getRedirectUri();
        String state = token.getState();

        if (redirectUri != null) {
            LOG.infof("Verifying redirectUri: %s for client: %s", redirectUri, authSession.getClient().getClientId());
            redirectUri = RedirectUtils.verifyRedirectUri(session, redirectUri, authSession.getClient());
            LOG.infof("Verified redirectUri: %s", redirectUri);
        }

        if (redirectUri == null) {
            // Fallback to the first valid redirect URI of the client
            java.util.Set<String> redirects = authSession.getClient().getRedirectUris();
            if (redirects != null && !redirects.isEmpty()) {
                redirectUri = redirects.iterator().next();
            }
        }

        if (redirectUri != null) {
            authSession.setRedirectUri(redirectUri);
        }

        if (state == null) {
            state = java.util.UUID.randomUUID().toString();
        }
        authSession.setAuthNote(org.keycloak.protocol.oidc.OIDCLoginProtocol.STATE_PARAM, state);

        // ── 5. Complete authentication and redirect to the client ──────────
        // Ensure the authSession is correctly configured for OIDC code flow
        authSession.setProtocol(org.keycloak.protocol.oidc.OIDCLoginProtocol.LOGIN_PROTOCOL);
        authSession.setClientNote(org.keycloak.protocol.oidc.OIDCLoginProtocol.RESPONSE_TYPE_PARAM, "code");
        authSession.setClientNote(org.keycloak.protocol.oidc.OIDCLoginProtocol.REDIRECT_URI_PARAM, redirectUri);
        authSession.setClientNote(org.keycloak.protocol.oidc.OIDCLoginProtocol.SCOPE_PARAM, "openid");
        authSession.setClientNote(org.keycloak.protocol.oidc.OIDCLoginProtocol.STATE_PARAM, state);

        // Create the official Keycloak UserSession
        UserSessionModel userSession = session.sessions().createUserSession(realm, user, user.getUsername(), 
                ctx.getClientConnection().getRemoteAddr(), "form", false, null, null);
        
        // Propagate metadata to the permanent session
        userSession.setNote(ScanClaimsMapper.NOTE_PATIENT_ID, token.getPatientId());
        userSession.setNote(ScanClaimsMapper.NOTE_STUDY_ID,   token.getStudyId());

        // Attach the client session to the user session
        AuthenticatedClientSessionModel clientSession = session.sessions().createClientSession(realm, authSession.getClient(), userSession);
        
        // Set the 'iss' note — OIDCLoginProtocol.authenticated() reads this
        // from the clientSession and adds it as a query param in the redirect.
        // If null, it crashes with "A passed in value was null".
        String publicBaseUrl = System.getenv("KC_HOSTNAME_URL");
        if (publicBaseUrl == null || publicBaseUrl.isBlank()) {
            publicBaseUrl = ctx.getUriInfo().getBaseUri().toString();
        }
        if (publicBaseUrl.endsWith("/")) {
            publicBaseUrl = publicBaseUrl.substring(0, publicBaseUrl.length() - 1);
        }
        clientSession.setNote("iss", publicBaseUrl + "/realms/" + realm.getName());
        
        ClientSessionContext clientSessionCtx = DefaultClientSessionContext.fromClientSessionScopeParameter(clientSession, session);

        // Tell the protocol handler where we are going
        LoginProtocol loginProtocol = session.getProvider(LoginProtocol.class, org.keycloak.protocol.oidc.OIDCLoginProtocol.LOGIN_PROTOCOL);
        loginProtocol.setSession(session)
                     .setRealm(realm)
                     .setUriInfo(ctx.getUriInfo())
                     .setHttpHeaders(ctx.getRequest().getHttpHeaders())
                     .setEventBuilder(ctx.getEvent());

        // Create the Login Cookie (VERY important for session persistence)
        AuthenticationManager.createLoginCookie(session, realm, user, userSession, ctx.getUriInfo(), ctx.getClientConnection());

        return AuthenticationManager.redirectAfterSuccessfulFlow(
                session, realm, userSession, clientSessionCtx,
                ctx.getRequest(), ctx.getUriInfo(),
                ctx.getClientConnection(), ctx.getEvent(),
                authSession
        );
        } catch (Exception e) {
            LOG.error("Error during scan action token handling", e);
            throw e;
        }
    }

    /**
     * Tell Keycloak which token class to deserialise into.
     */
    @Override
    public Class<ScanActionToken> getTokenClass() {
        return ScanActionToken.class;
    }
}
