## Introduzione.
La presente guida si pone l'obiettivo di semplificare la prima installazione del portale
di ticketing basato sull'applicativo ZAMMAD

## PREREQUISITI INSTALLAZIONE :
Vedere Readme.md della guida all'installazione della piattaforma 

Nel caso in cui si voglia disabilitare la gestione dei ticket, va commentato/eliminato la property VITE_APP_ZAMMAD_HOST all'interno di httpd-config/config-prod.js : questo
nasconderà i bottoni e bloccherà le chiamate di polling di ricerca dei ticket
