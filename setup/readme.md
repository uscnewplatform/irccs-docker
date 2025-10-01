# IRCCS PASCALE – Ambiente Pulito

## 1. Installazione SearchParameters FHIR

```bash
bash install_searchparameters.sh hostname:port
Usage: install_searchparameters.sh hostname:port
```
##### hostname:port deve corrispondere all’istanza FHIR target.

Lo script installerà i parametri di ricerca necessari per garantire il corretto funzionamento dei microservizi che interagiscono con il server FHIR.

## 2. Configurazione SMTP in Keycloak

Accedere alla dashboard di Keycloak ed effettuare i seguenti passaggi:

- Autenticarsi con:

```bash
Username: gennaro.aurilia@gmail.com
Password: Qwerty123!
```

**Assicurarsi di cambiare password di quest'ultimo**

- Selezionare il realm: _pascale_.

- Nel menu laterale, aprire _Realm Settings_ → scheda _Email_.

- Nella sezione Connection & Authentication (in fondo alla pagina):

- Inserire i parametri SMTP forniti dall’infrastruttura.

- Verificare la connessione cliccando su _Test connection_.


> #### Nota tecnica
>La configurazione SMTP è fondamentale:
>Keycloak utilizzerà il servizio SMTP per l’invio delle email di registrazione utenti e reset password.
>Anche i microservizi collegati all’ecosistema PASCALE sfrutteranno lo stesso canale SMTP per notifiche automatiche e flussi di validazione.