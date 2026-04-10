package com.example.keycloak;

import org.jboss.logging.Logger;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;

import java.util.ArrayList;
import java.util.List;

/**
 * OIDC Protocol Mapper: injects {@code patientId} and {@code studyId}
 * into every access token issued for the scanner-client.
 *
 * The values come from the UserSessionModel notes that were written by
 * {@link ScanActionTokenHandler} when the action token was consumed.
 */
public class ScanClaimsMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCIDTokenMapper, UserInfoTokenMapper {

    private static final Logger LOG = Logger.getLogger(ScanClaimsMapper.class);

    public static final String PROVIDER_ID      = "scan-claims-mapper";
    public static final String NOTE_PATIENT_ID  = "scan_patientId";
    public static final String NOTE_STUDY_ID    = "scan_studyId";

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES = new ArrayList<>();

    @Override
    public String getId()              { return PROVIDER_ID; }

    @Override
    public String getDisplayType()     { return "Scan Claims (patientId / studyId)"; }

    @Override
    public String getDisplayCategory() { return TOKEN_MAPPER_CATEGORY; }

    @Override
    public String getHelpText() {
        return "Copies patientId and studyId from the scan session into the tokens.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    public AccessToken transformAccessToken(AccessToken token,
                                            ProtocolMapperModel mappingModel,
                                            KeycloakSession session,
                                            UserSessionModel userSession,
                                            ClientSessionContext clientSessionCtx) {
        return (AccessToken) transformToken(token, mappingModel, userSession);
    }

    @Override
    public IDToken transformIDToken(IDToken token,
                                    ProtocolMapperModel mappingModel,
                                    KeycloakSession session,
                                    UserSessionModel userSession,
                                    ClientSessionContext clientSessionCtx) {
        return transformToken(token, mappingModel, userSession);
    }

    @Override
    public AccessToken transformUserInfoToken(AccessToken token,
                                              ProtocolMapperModel mappingModel,
                                              KeycloakSession session,
                                              UserSessionModel userSession,
                                              ClientSessionContext clientSessionCtx) {
        return (AccessToken) transformToken(token, mappingModel, userSession);
    }

    private IDToken transformToken(IDToken token,
                                   ProtocolMapperModel mappingModel,
                                   UserSessionModel userSession) {
        
        String patientId = userSession.getNote(NOTE_PATIENT_ID);
        String studyId   = userSession.getNote(NOTE_STUDY_ID);

        if (patientId == null || studyId == null) {
            LOG.infof("ScanClaimsMapper: no scan notes on session %s — skipping", userSession.getId());
            return token;
        }

        LOG.infof("ScanClaimsMapper: injecting patientId=%s studyId=%s into token %s",
                   patientId, studyId, token.getClass().getSimpleName());

        token.getOtherClaims().put("patientId", patientId);
        token.getOtherClaims().put("studyId",   studyId);

        return token;
    }
}
