/*
 * Decompiled with CFR 0.152.
 * 
 * Could not load the following classes:
 *  org.keycloak.models.ClientSessionContext
 *  org.keycloak.models.GroupModel
 *  org.keycloak.models.KeycloakSession
 *  org.keycloak.models.ProtocolMapperModel
 *  org.keycloak.models.RoleModel
 *  org.keycloak.models.UserModel
 *  org.keycloak.models.UserSessionModel
 *  org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper
 *  org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper
 *  org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper
 *  org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper
 *  org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper
 *  org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper
 *  org.keycloak.provider.ProviderConfigProperty
 *  org.keycloak.representations.IDToken
 */
package org.i3.provider.mapper;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.stream.Stream;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAttributeMapperHelper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.protocol.oidc.mappers.TokenIntrospectionTokenMapper;
import org.keycloak.protocol.oidc.mappers.UserInfoTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.IDToken;

public class CustomProtocolMapper
extends AbstractOIDCProtocolMapper
implements OIDCAccessTokenMapper,
OIDCIDTokenMapper,
UserInfoTokenMapper,
TokenIntrospectionTokenMapper {
    public static final String PROVIDER_ID = "groups-id-mapper";
    private static final List<ProviderConfigProperty> configProperties = new ArrayList<ProviderConfigProperty>();

    public String getDisplayCategory() {
        return "Groups Id Mapper";
    }

    public String getDisplayType() {
        return "Groups Id Mapper";
    }

    public String getHelpText() {
        return "Adds Group IDS & Group Roles to claims";
    }

    public List<ProviderConfigProperty> getConfigProperties() {
        return configProperties;
    }

    public String getId() {
        return PROVIDER_ID;
    }

    protected void setClaim(IDToken token, ProtocolMapperModel mappingModel, UserSessionModel userSession, KeycloakSession keycloakSession, ClientSessionContext clientSessionCtx) {
        HashMap<String, HashMap<String, List<String>>> groupIds = new HashMap<String, HashMap<String, List<String>>>();
        UserModel user = userSession.getUser();
        for (GroupModel group : user.getGroupsStream().toList()) {
            groupIds.put(group.getId(), CustomProtocolMapper.computeRoles(group.getRoleMappingsStream()));
        }
        OIDCAttributeMapperHelper.mapClaim((IDToken)token, (ProtocolMapperModel)mappingModel, groupIds);
        ArrayList<String> organizationIds = new ArrayList<String>();
        for (GroupModel group : user.getGroupsStream().toList()) {
            this.collectParentOrganizationIds(group, organizationIds);
        }
        if (!organizationIds.isEmpty()) {
            token.getOtherClaims().put("organizations-id", organizationIds);
        }
    }

    private static HashMap<String, List<String>> computeRoles(Stream<RoleModel> stream) {
        HashMap<String, List<String>> resourceRoles = new HashMap<String, List<String>>();
        stream.forEach(role -> {
            String roleName = role.getName();
            if (role.isComposite()) {
                HashMap<String, List<String>> computedRoles = CustomProtocolMapper.computeRoles(role.getCompositesStream());
                computedRoles.forEach((resourceName, operations) -> resourceRoles.merge((String)resourceName, (List<String>)operations, (existingOps, newOps) -> {
                    existingOps.addAll(newOps);
                    return existingOps;
                }));
            } else {
                long colonCount = roleName.chars().filter(ch -> ch == 58).count();
                if (colonCount == 1L) {
                    String[] parts = roleName.split(":");
                    String resource = parts[0];
                    String operation = parts[1];
                    resourceRoles.computeIfAbsent(resource, k -> new ArrayList()).add(operation);
                } else {
                    resourceRoles.computeIfAbsent("__roles__", k -> new ArrayList()).add(roleName);
                }
            }
        });
        return resourceRoles;
    }

    private void collectParentOrganizationIds(final GroupModel group, List<String> organizationIds) {
        if (group != null) {
            final String organizationId = group.getFirstAttribute("organizationId");
            if (organizationId != null && !organizationIds.contains(organizationId)) {
                HashMap<String, String> map = new HashMap<String, String>(){
                    {
                        this.put("\"fhirId\"", "\"" + organizationId + "\"");
                        this.put("\"keycloakId\"", "\"" + group.getId() + "\"");
                    }
                };
                organizationIds.add(((Object)map).toString());
            }
            GroupModel parentGroup = group.getParent();
            this.collectParentOrganizationIds(parentGroup, organizationIds);
        }
    }

    static {
        OIDCAttributeMapperHelper.addTokenClaimNameConfig(configProperties);
        OIDCAttributeMapperHelper.addIncludeInTokensConfig(configProperties, CustomProtocolMapper.class);
    }
}

