window.APP_CONFIG = {
    VITE_APP_ZAMMAD_HOST: "https://pj-tk.istitutotumori.na.it",
    VITE_APP_ZAMMAD_POLL_INTERVAL_SECONDS: "120",
    VITE_APP_ZAMMAD_TICKET_ANNUNCE_STATE_ID: "7",
    VITE_APP_ZAMMAD_FALLBACK_GROUP_ID: "9",
    // Scan-session (keycloak-scan-spi). VITE_SCAN_SESSION_SCANNER_USER_ID
    // DEVE essere lo user-id (UUID) dell'utente service-account scanner
    // creato nel realm Keycloak di QUESTO ambiente. Lasciarlo vuoto fa
    // ricadere sul default di sviluppo -> errore "scannerUserId not found in realm".
    VITE_SCAN_SESSION_SCANNER_USER_ID: "4f814033-5e6b-4094-9c13-88582b03353a",
    VITE_SCAN_SESSION_CLIENT_ID: "irccs",
    VITE_SCAN_SESSION_REDIRECT_URI: "https://pj.istitutotumori.na.it/app/",
    VITE_SCAN_SESSION_EXPIRES_IN: "3600",
    VITE_SCAN_SESSION_STATE: "scan-session",
    VITE_APP_CHATBOT_ENABLED: false,
    // Faro (log/errori frontend -> Loki via Alloy, vedi src/faro.ts).
    // Vuoto = Faro disabilitato. api-key e' visibile lato browser (pagina
    // pubblica): non e' un vero segreto, serve solo a filtrare traffico non
    // intenzionale sul receiver. Deve combaciare con AGENT_KEY_APP_RECEIVER
    // in irccs-docker/.env.
    VITE_API_FARO_COLLECTOR_API: "https://pj.istitutotumori.na.it/faro-collector/collect",
    VITE_API_FARO_API_KEY: "fe0ffe6e904e90b7e15d080ee2e1bf7df7a23dda4142ebff61462f90727692d2"
};
