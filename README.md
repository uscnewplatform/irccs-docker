Per attivare Keycloak in SSL è necessario:
inserire certificato e chiave tramite volume, e riportarli nel keycloak.conf.
rimuovere lo start-dev dal docker-compose

Momentaneamente inserito in /etc/hosts:

127.0.0.1 keycloak.irccs.infocube.it

per testare keycloak.

Va verificato come impostare l'hostname di Keycloak in funzione delle chiamate che arrivano dai microservizi, altrimenti non è raggiungibile se non fa match l'url chiamato con quello dichiarato nel conf.

Notare che in SSL la porta passa da 9445 a 8443 (inserita nella versione corrente del docker-compose) 



Nel docker compose yaml, in entrypoint sono state inserite comandi per installare le search parameters in hapi fhir. La chiamata viene fatta solo dopo 60 secondi, perche è necessario che HAPI FHIR sia disponibile, ed il check viene fatto tramite chiamata a HAPI FHIR (ogni 15 secondi)