#!/bin/bash
# Seed del registry dinamico dei tipi di consenso (CodeSystem urn:irccs:consent-type).
#
# I tipi di consenso non sono piu' hardcoded nel frontend: vivono come concept[]
# di questo CodeSystem, gestibili a runtime da un admin (UI "Tipi di consenso").
# Questo script pre-carica un tipo per ciascun codice HL7 consentcategorycodes
# (7.1.0), con lo scope HL7 consentscope coerente.
#
# Terminologia: SOLO HL7 (NON LOINC).
#   - scope    -> http://terminology.hl7.org/CodeSystem/consentscope
#   - category -> http://terminology.hl7.org/CodeSystem/consentcategorycodes
#
# La dashboard scrive/legge il CodeSystem direttamente su HAPI
# (apache: ProxyPass /CodeSystem -> irccs-hapi-fhir/fhir/CodeSystem).
#
# Uso conditional update (PUT ?url=...): idempotente, non duplica.

if [ -z "$1" ]; then
  echo "Usage: $0 hostname:port"
  exit 1
fi

HOSTNAME_PORT=$1

SCOPE_SYS="http://terminology.hl7.org/CodeSystem/consentscope"
CAT_SYS="http://terminology.hl7.org/CodeSystem/consentcategorycodes"

JSON_BODY=$(cat <<EOF
{
  "resourceType": "CodeSystem",
  "url": "urn:irccs:consent-type",
  "name": "IrccsConsentType",
  "title": "IRCCS Consent Types",
  "status": "active",
  "content": "complete",
  "caseSensitive": true,
  "property": [
    { "code": "scope", "type": "Coding" },
    { "code": "category", "type": "Coding" }
  ],
  "concept": [
    {
      "code": "privacy",
      "display": "Privacy Consent",
      "designation": [
        { "language": "it", "value": "Consenso privacy" },
        { "language": "en", "value": "Privacy Consent" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "patient-privacy", "display": "Privacy Consent" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "npp", "display": "Notice of Privacy Practices" } }
      ]
    },
    {
      "code": "research",
      "display": "Research Information Access",
      "designation": [
        { "language": "it", "value": "Consenso alla ricerca" },
        { "language": "en", "value": "Research Information Access" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "research", "display": "Research" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "research", "display": "Research Information Access" } }
      ]
    },
    {
      "code": "research-deidentified",
      "display": "De-identified Information Access",
      "designation": [
        { "language": "it", "value": "Accesso a dati anonimizzati" },
        { "language": "en", "value": "De-identified Information Access" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "research", "display": "Research" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "rsdid", "display": "De-identified Information Access" } }
      ]
    },
    {
      "code": "research-reidentifiable",
      "display": "Re-identifiable Information Access",
      "designation": [
        { "language": "it", "value": "Accesso a dati ri-identificabili" },
        { "language": "en", "value": "Re-identifiable Information Access" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "research", "display": "Research" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "rsreid", "display": "Re-identifiable Information Access" } }
      ]
    },
    {
      "code": "advance-directive",
      "display": "Advance Directive",
      "designation": [
        { "language": "it", "value": "Direttive anticipate" },
        { "language": "en", "value": "Advance Directive" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "adr", "display": "Advanced Care Directive" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "acd", "display": "Advance Directive" } }
      ]
    },
    {
      "code": "health-care-directive",
      "display": "Health Care Directive",
      "designation": [
        { "language": "it", "value": "Direttiva sanitaria" },
        { "language": "en", "value": "Health Care Directive" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "adr", "display": "Advanced Care Directive" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "hcd", "display": "Health Care Directive" } }
      ]
    },
    {
      "code": "polst",
      "display": "POLST",
      "designation": [
        { "language": "it", "value": "POLST (ordini medici per trattamenti di fine vita)" },
        { "language": "en", "value": "POLST" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "adr", "display": "Advanced Care Directive" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "polst", "display": "POLST" } }
      ]
    },
    {
      "code": "dnr",
      "display": "Do Not Resuscitate",
      "designation": [
        { "language": "it", "value": "Non rianimare (DNR)" },
        { "language": "en", "value": "Do Not Resuscitate" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "adr", "display": "Advanced Care Directive" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "dnr", "display": "Do Not Resuscitate" } }
      ]
    },
    {
      "code": "emergency-only",
      "display": "Emergency Only",
      "designation": [
        { "language": "it", "value": "Solo emergenza" },
        { "language": "en", "value": "Emergency Only" }
      ],
      "property": [
        { "code": "scope", "valueCoding": { "system": "$SCOPE_SYS", "code": "treatment", "display": "Treatment" } },
        { "code": "category", "valueCoding": { "system": "$CAT_SYS", "code": "emrgonly", "display": "Emergency Only" } }
      ]
    }
  ]
}
EOF
)

curl -s -X PUT "http://$HOSTNAME_PORT/fhir/CodeSystem?url=urn:irccs:consent-type" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"
echo
