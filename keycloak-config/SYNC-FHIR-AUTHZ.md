# sync-fhir-authz.py — autorizzazioni FHIR mancanti su Keycloak

Controlla quali risorse FHIR instradate dal proxy non hanno la loro autorizzazione nel
realm Keycloak e crea quelle mancanti, **senza modificare nulla di ciò che esiste già**
(idempotente, rilanciabile).

## Quando serve

Sintomo: `403` su una rotta FHIR (es. `POST /DocumentReference`) per gli utenti **non
superadmin**, mentre il superadmin funziona.

Causa: per un tipo FHIR senza risorsa dedicata la rotta cade sulla sola **Admin Resource**
(`/fhir/*`), che ammette solo i profili admin. Succede perché:

- il `realm-export.json` di `irccs-docker` è un sottoinsieme dei tipi FHIR;
- il realm in esecuzione (preprod/prod) ha stato proprio e **non si riallinea** all'export.

Senza i ruoli `tipo:operazione` nessun profilo (nemmeno "All Resource") può contenere il
permesso: la UI Profili non li mostra come assegnabili.

## Cosa crea (per ogni tipo `T`)

| Cosa | Nomi |
|---|---|
| 6 realm role | `t:create`, `t:read`, `t:update`, `t:delete`, `t:search`, `t:history` (tipo in minuscolo) |
| 4 risorse (client `irccs`) | `Create T Resource` (`/fhir/T`), `Base T Resource` (`/fhir/T/{id}`), `Search T Resource` (`/fhir/T/_search`), `History T Resource` (`/_history` e varianti) |
| 6 role policy | `Create/Read/Update/Delete/Search/History T Policy` |
| 7 scope permission | `Create/Read/Update/Delete/Search/History T Permission` + `Search T Permission 2` |

Ogni permission include `Admin Group Policy` e `Admin Role Policy` (devono già esistere: se
mancano lo script si ferma). Struttura identica a quella di `Encounter` e delle altre risorse.

Tipi controllati di default: `DocumentReference`, `ImagingStudy`, `DiagnosticReport`,
`GuidanceResponse`, `Person`, `HealthcareService`, `PractitionerRole`.

## Requisiti

- Python 3 (solo libreria standard).
- Un utente admin di Keycloak (di norma `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` nel
  `.env` di `irccs-docker`).
- **Lanciarlo dall'host di Keycloak**: da `localhost` Keycloak accetta HTTP. Da remoto il
  realm `master` risponde `403 HTTPS required` (`sslRequired=external`); in tal caso usare
  l'URL HTTPS pubblico o un tunnel SSH.

## Uso

```bash
export KC_URL=http://localhost:9445      # porta pubblicata dal compose (9445:8080)
export REALM=pascale
export ADMIN_USER=<admin> ADMIN_PASS='<password>'
# se l'admin sta nel realm pascale:   export ADMIN_REALM=pascale
# se Keycloak ha il context path:     export KC_URL=http://localhost:9445/backoffice

python3 sync-fhir-authz.py --check       # SOLO report: non scrive, exit 2 se manca qualcosa
python3 sync-fhir-authz.py               # crea il mancante
```

Altre variabili: `CLIENT_ID` (default `irccs`).

### Scegliere i tipi

```bash
python3 sync-fhir-authz.py --check --types ImagingStudy,Person
python3 sync-fhir-authz.py --check --from-httpd ../httpd-config/irccs.conf
```

`--from-httpd` legge le rotte `ProxyPass /Tipo … /fhir/Tipo` di `irccs.conf`. **Attenzione:**
include anche tipi che potrebbero essere volutamente solo-admin (es. `Bundle`, `ValueSet`,
`CodeSystem`). Usarlo con `--check`, poi applicare con `--types` sui soli tipi voluti.

### Esempio di output

```
Keycloak http://localhost:9445 | realm pascale | client irccs | CHECK (non scrive)
Tipi: ImagingStudy, Person

MANCA    ImagingStudy: 23 elementi
           + ruolo imagingstudy:create
           ...
OK       Person

Mancano 23 elementi.
```

23 elementi = 6 ruoli + 4 risorse + 6 policy + 7 permission, cioè un tipo completamente assente.

## Dopo l'esecuzione (passi manuali)

1. **UI Profili:** spuntare i nuovi tipi (almeno `create`, `read`, `search`) nel profilo
   "All Resource" e negli altri che li usano. Lo script non assegna i ruoli a nessun profilo.
2. **Gli utenti rifanno logout/login** (il token di contesto va rigenerato).
3. **Verifica:** Keycloak → Clients → `irccs` → Authorization → **Evaluate**, utente di test,
   risorsa `Create T Resource`, scope `POST` → deve dare PERMIT. Se nega, la schermata mostra
   quale policy fallisce.

## Cosa NON fa

- Non assegna ruoli a profili, gruppi o utenti.
- Non modifica né ripara risorse/policy esistenti (se un elemento esiste con lo stesso nome
  lo considera a posto, anche se configurato diversamente).
- Non copre le rotte **non FHIR** (`/dicom`, `/zammad`, `/patients/*`…): non seguono questa
  convenzione e vanno verificate a parte.
- Non aggiorna `realm-export.json` (vedi sotto).

## Attenzione al riavvio di Keycloak

L'entrypoint del compose avvia Keycloak con
`--import-realm -Dkeycloak.migration.strategy=OVERWRITE_EXISTING`. Se quel parametro viene
onorato dalla versione in uso, un riavvio reimporta `realm-export.json` sul realm vivo e può
**cancellare** ciò che è stato creato a runtime (profili come "All Resource", modifiche dello
script). Prima di riavviare Keycloak in preprod/prod verificare cosa fa all'avvio
(`docker logs irccs-keycloak | grep -i import`).

## Allineamento di realm-export.json

Gli ambienti **nuovi** nascono dal `realm-export.json`: per questo i 7 tipi di default sono
stati aggiunti anche lì (stessa struttura generata dallo script, confrontata con
`irccs-common/i3-annotations/config/pascale_realm.json`). Aggiungendo un nuovo tipo allo
script, aggiungerlo anche all'export, altrimenti ambienti nuovi e vecchi divergono.

## Estendere

Aggiungere il tipo a `DEFAULT_TYPES` in `sync-fhir-authz.py` (o passarlo con `--types`).
Se un tipo ha URI diversi dalla convenzione (`/fhir/T`, `/fhir/T/{id}`, `/_search`,
`/_history`), modificare `resources_for()`.
