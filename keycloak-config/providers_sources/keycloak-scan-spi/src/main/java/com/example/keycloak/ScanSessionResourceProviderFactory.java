package com.example.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.services.resource.RealmResourceProvider;
import org.keycloak.services.resource.RealmResourceProviderFactory;

/**
 * Factory that registers the /scan-session custom REST resource with Keycloak.
 *
 * Keycloak discovers this class via:
 *   META-INF/services/org.keycloak.services.resource.RealmResourceProviderFactory
 *
 * The PROVIDER_ID ("scan-session") becomes the URL path segment:
 *   /realms/{realm}/scan-session/generate
 */
public class ScanSessionResourceProviderFactory implements RealmResourceProviderFactory {

    public static final String PROVIDER_ID = "scan-session";

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public RealmResourceProvider create(KeycloakSession session) {
        return new ScanSessionResourceProvider(session);
    }

    @Override
    public void init(Config.Scope config) { /* no static config needed */ }

    @Override
    public void postInit(KeycloakSessionFactory factory) { /* nothing to do */ }

    @Override
    public void close() { /* nothing to close */ }
}
