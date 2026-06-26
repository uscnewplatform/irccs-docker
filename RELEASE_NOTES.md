# Release Notes — Piattaforma IRCCS Pascale
> Generato: 2026-05-26
> Stato versioni: **SNAPSHOT** = in sviluppo, non ancora taggato | **RELEASE** = versione taggata e rilasciata

---

## Riepilogo stato corrente

| Componente | Ultimo tag (RELEASE) | Versione corrente | Stato |
|---|---|---|---|
| irccs-react-dashboard | `2.3.0` | `2.5.13` | SNAPSHOT |
| irccs-common | `25.3.1` | `25.3.1-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-auth | `2.0.0` | `2.1.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-anagrafica-pazienti | `2.0.0` | `2.0.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-centro-ricerca | `2.0.0` | `2.1.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-clinical-reasoning | `2.0.0` | `2.1.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-notification | `2.0.0` | `2.1.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-practitioner | `2.0.0` | `2.1.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-studio-clinico | `2.0.0` | `2.1.0-SNAPSHOT` | SNAPSHOT |
| irccs-microservice-patient-interview | *(mai taggato)* | `2.1.0-SNAPSHOT` | SNAPSHOT — primo rilascio atteso |
| irccs-microservice-tac | *(mai taggato)* | `2.1.0-SNAPSHOT` | SNAPSHOT — primo rilascio atteso |
| irccs-microservice-webpush | *(mai taggato)* | `1.0.0-SNAPSHOT` | SNAPSHOT — nuovo servizio |
| irccs-microservice-zammad | *(mai taggato)* | `2.1.0-SNAPSHOT` | SNAPSHOT — primo rilascio atteso |

---

## Modifiche in sviluppo rispetto all'ultimo RELEASE

### IRCCS.REACT.GUI — `2.5.13-SNAPSHOT` (ultimo tag: `2.3.0` del 2025-05-21)

* Nuovo **Catalogo Questionari**: ricerca, filtro per tipo, infinite scroll, gestione utilizzi per studio
* Supporto **score sulle answerOption** (extension `ordinalValue`) e campo calcolato con FHIRPath (`sdf-calculatedExpression`)
* **Pre-popolamento cicli**: nuova extension `prepopulateFromPreviousCycle` — il designer può abilitare la copia automatica dei valori dal ciclo precedente
* Ricerca librerie CRF esterne (ValueSet/CodeSystem) nel Questionnaire Builder
* Integrazione **farmaci AIFA** nel Questionnaire Builder
* Limite creazione cicli terapeutici (PASTRL-683)
* Gestione **traduzioni multilingua** per notifiche e messaggi
* Aggiunta estensione `ORDINAL_VALUE_URL` centralizzata in `src/fhir/extensions/ordinalValue.ts`

### IRCCS.COMMONLIB.BE — `25.3.1-SNAPSHOT` (ultimo tag: `25.3.1` del 2025-05-21)

* Aggiunto modulo `i3-mail` per invio email centralizzato (migrazione da implementazioni locali)
* Aggiunto servizio traduzioni (`translate service`)
* Aggiornamenti documentazione Antora

### IRCCS.MICROSERVICE.BE — tutti a `2.1.0-SNAPSHOT` (ultimo tag: `2.0.0` del 2025-05-21)

**irccs-microservice-auth** (`2.1.0-SNAPSHOT`)
* Migrazione invio email al modulo `i3-mail` di irccs-common
* Aggiunta logo Pascale nelle email
* Fix parsing identifier organizzazione
* Nuova API organizzazioni senza autenticazione (e successivo revert per sicurezza, PASTRL-628)

**irccs-microservice-studio-clinico** (`2.1.0-SNAPSHOT`)
* Integrazione **WebPush**: notifica push alla creazione CarePlan
* Messaggi WebPush multilingua con fallback italiano
* Esternalizzazione configurazione messaggi via MicroProfile Config
* Aggiunto servizio traduzioni

**irccs-microservice-notification** (`2.1.0-SNAPSHOT`)
* Rimozione gestione librerie CRF locali: migrate a ValueSet/CodeSystem su HAPI FHIR
* Migrazione invio email al modulo `i3-mail`

**irccs-microservice-centro-ricerca** (`2.1.0-SNAPSHOT`)
* Nuova API organizzazioni senza autenticazione

**irccs-microservice-clinical-reasoning** (`2.1.0-SNAPSHOT`)
* Fix versione librerie CQL

**irccs-microservice-practitioner** (`2.1.0-SNAPSHOT`)
* Bump versione, fix test Testcontainers

**irccs-microservice-anagrafica-pazienti** (`2.0.0-SNAPSHOT`)
* Aggiunta controller Consensi e AdverseEvent (PASTRL-468)
* Test controlli ResearchSubject

**irccs-microservice-patient-interview** (`2.1.0-SNAPSHOT`) — *primo rilascio atteso*
* Endpoint visibilità, estensioni, submit, recupero CarePlan parent

**irccs-microservice-tac** (`2.1.0-SNAPSHOT`) — *primo rilascio atteso*
* Integrazione dcm4che per DICOM/TAC storage

**irccs-microservice-webpush** (`1.0.0-SNAPSHOT`) — *nuovo servizio*
* Gestione notifiche Web Push
* Filtro per stato Questionnaire
* Validazione CarePlan–QuestionnaireResponse prima dell'invio notifica

**irccs-microservice-zammad** (`2.1.0-SNAPSHOT`) — *primo rilascio atteso*
* Integrazione ticketing Zammad

---

## Storico RELEASE

### `2.3.0` — 2025-05-21
* **GUI** `2.3.0`: Rilascio ufficiale Patient Journey JLI con randomizzazione e minimizzazione pazienti tramite CQL
* **BE** `2.0.0`: Migrazione piattaforma ad HL7 FHIR R4 per utilizzo CQL di HAPI FHIR
* **Common** `25.3.1`: Rilascio ufficiale Patient Journey JLI

### `2.0.0` — 2025-04-07
* **GUI** `2.0.0`: Migrazione piattaforma ad HL7 FHIR R4
* **Common** `25.2.0`: Migrazione da HL7 FHIR R5 ad HL7 FHIR R4

### `1.0.0-R5-RELEASE` — 2025-03-13
* **GUI** `1.0.0-R5-RELEASE`: Primo rilascio piattaforma studi clinici in HL7 FHIR R5
* **BE** `1.0.0-R5-RELEASE`: Primo rilascio backend in HL7 FHIR R5
* **Common** `25.1.1`: Primo rilascio libreria comune
