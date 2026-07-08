window.APP_CONFIG = {
    VITE_APP_STAGING_MS_HOST: "",
    VITE_APP_STAGING_AUTH_HOST: "",
    VITE_APP_ZAMMAD_HOST: "https://pj.istitutotumori.na.it:8443",
    VITE_APP_ZAMMAD_POLL_INTERVAL_SECONDS: "120",
    VITE_APP_ZAMMAD_TICKET_ANNUNCE_STATE_ID: "7",

    // Scan-session (keycloak-scan-spi). VITE_SCAN_SESSION_SCANNER_USER_ID
    // DEVE essere lo user-id (UUID) dell'utente service-account scanner
    // creato nel realm Keycloak di QUESTO ambiente. Lasciarlo vuoto fa
    // ricadere sul default di sviluppo -> errore "scannerUserId not found in realm".
    VITE_SCAN_SESSION_SCANNER_USER_ID: "",
    VITE_SCAN_SESSION_CLIENT_ID: "irccs",
    VITE_SCAN_SESSION_REDIRECT_URI: "https://pj.istitutotumori.na.it/app/",
    VITE_SCAN_SESSION_EXPIRES_IN: "3600",
    VITE_SCAN_SESSION_STATE: "scan-session"
};
