#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 hostname:port"
  exit 1
fi

HOSTNAME_PORT=$1
ITEMS=(
    "Account"
    "ActivityDefinition"
    "ActorDefinition"
    "AdministrableProductDefinition"
    "AdverseEvent"
    "AllergyIntolerance"
    "Appointment"
    "AppointmentResponse"
    "ArtifactAssessment"
    "AuditEvent"
    "Basic"
    "Binary"
    "BiologicallyDerivedProduct"
    "BiologicallyDerivedProductDispense"
    "BodyStructure"
    "Bundle"
    "CapabilityStatement"
    "CarePlan"
    "CareTeam"
    "ChargeItem"
    "ChargeItemDefinition"
    "Citation"
    "Claim"
    "ClaimResponse"
    "ClinicalImpression"
    "ClinicalUseDefinition"
    "CodeSystem"
    "Communication"
    "CommunicationRequest"
    "CompartmentDefinition"
    "Composition"
    "ConceptMap"
    "Condition"
    "ConditionDefinition"
    "Consent"
    "Contract"
    "Coverage"
    "CoverageEligibilityRequest"
    "CoverageEligibilityResponse"
    "DetectedIssue"
    "Device"
    "DeviceAssociation"
    "DeviceDefinition"
    "DeviceDispense"
    "DeviceMetric"
    "DeviceRequest"
    "DeviceUsage"
    "DiagnosticReport"
    "DocumentReference"
    "Encounter"
    "EncounterHistory"
    "Endpoint"
    "EnrollmentRequest"
    "EnrollmentResponse"
    "EpisodeOfCare"
    "EventDefinition"
    "Evidence"
    "EvidenceReport"
    "EvidenceVariable"
    "ExampleScenario"
    "ExplanationOfBenefit"
    "FamilyMemberHistory"
    "Flag"
    "FormularyItem"
    "GenomicStudy"
    "Goal"
    "GraphDefinition"
    "Group"
    "GuidanceResponse"
    "HealthcareService"
    "ImagingSelection"
    "ImagingStudy"
    "Immunization"
    "ImmunizationEvaluation"
    "ImmunizationRecommendation"
    "ImplementationGuide"
    "Ingredient"
    "InsurancePlan"
    "InventoryItem"
    "InventoryReport"
    "Invoice"
    "Library"
    "Linkage"
    "List"
    "Location"
    "ManufacturedItemDefinition"
    "Measure"
    "MeasureReport"
    "Medication"
    "MedicationAdministration"
    "MedicationDispense"
    "MedicationKnowledge"
    "MedicationRequest"
    "MedicationStatement"
    "MedicinalProductDefinition"
    "MessageDefinition"
    "MessageHeader"
    "MolecularSequence"
    "NamingSystem"
    "NutritionIntake"
    "NutritionOrder"
    "NutritionProduct"
    "Observation"
    "ObservationDefinition"
    "OperationDefinition"
    "OperationOutcome"
    "Organization"
    "OrganizationAffiliation"
    "PackagedProductDefinition"
    "Parameters"
    "Patient"
    "PaymentNotice"
    "PaymentReconciliation"
    "Permission"
    "Person"
    "PlanDefinition"
    "Practitioner"
    "PractitionerRole"
    "Procedure"
    "Provenance"
    "Questionnaire"
    "QuestionnaireResponse"
    "RegulatedAuthorization"
    "RelatedPerson"
    "RequestOrchestration"
    "Requirements"
    "ResearchStudy"
    "ResearchSubject"
    "RiskAssessment"
    "Schedule"
    "SearchParameter"
    "ServiceRequest"
    "Slot"
    "Specimen"
    "SpecimenDefinition"
    "StructureDefinition"
    "StructureMap"
    "Subscription"
    "SubscriptionStatus"
    "SubscriptionTopic"
    "Substance"
    "SubstanceDefinition"
    "SubstanceNucleicAcid"
    "SubstancePolymer"
    "SubstanceProtein"
    "SubstanceReferenceInformation"
    "SubstanceSourceMaterial"
    "SupplyDelivery"
    "SupplyRequest"
    "Task"
    "TerminologyCapabilities"
    "TestPlan"
    "TestReport"
    "TestScript"
    "Transport"
    "ValueSet"
    "VerificationResult"
    "VisionPrescription"
)

for item in "${ITEMS[@]}"; do
  JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "name": "group-id",
  "title": "group-id",
  "status": "active",
  "experimental": true,
  "publisher": "Infocube",
  "description": "Search by extension value",
  "code": "group-id",
  "base": ["$item"],
  "type": "string",
  "expression": "$item.identifier.value | $item.extension.where(url = 'group_ids').value",
  "processingMode": "normal",
  "modifier": ["exact"]
}
EOF
  )

  curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
        -H "Content-Type: application/json" \
        -d "$JSON_BODY"
done

# Enrollment SearchParameter (string — ricerca per ID stringa)
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "name": "enrollment",
  "title": "enrollment",
  "status": "active",
  "experimental": true,
  "publisher": "Infocube",
  "description": "Search by enrollment reference",
  "code": "enrollment",
  "base": ["ResearchStudy"],
  "type": "string",
  "expression": "ResearchStudy.enrollment.reference",
  "processingMode": "normal",
  "modifier": ["exact"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# Enrollment-group SearchParameter (reference type — per _revinclude:iterate)
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "name": "enrollment-group",
  "title": "enrollment-group",
  "status": "active",
  "publisher": "Infocube",
  "description": "Reference search on ResearchStudy.enrollment for _revinclude",
  "code": "enrollment-group",
  "base": ["ResearchStudy"],
  "type": "reference",
  "expression": "ResearchStudy.enrollment",
  "target": ["Group"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# CarePlan.activity.outcomeReference SearchParameter
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://your.fhir.server/SearchParameter/CarePlan-activity-outcomeReference",
  "name": "activity-outcomeReference",
  "status": "active",
  "description": "References used in CarePlan.activity.outcomeReference",
  "code": "activity-outcomeReference",
  "base": ["CarePlan"],
  "type": "reference",
  "expression": "CarePlan.activity.outcomeReference",
  "target": ["Questionnaire"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# ActivityDefinition.documentation SearchParameter
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://your.fhir.server/SearchParameter/ActivityDefinition-documentation",
  "name": "documentation",
  "status": "active",
  "description": "Include CarePlan referenced as documentation in ActivityDefinition.relatedArtifact",
  "code": "documentation",
  "base": ["ActivityDefinition"],
  "type": "reference",
  "expression": "ActivityDefinition.relatedArtifact.where(type='documentation').resource",
  "xpathUsage": "normal",
  "target": ["CarePlan"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# PlanDefinition.documentation SearchParameter
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://your.fhir.server/SearchParameter/PlanDefinition-documentation",
  "name": "documentation",
  "status": "active",
  "description": "Include CarePlan referenced as documentation in PlanDefinition.relatedArtifact",
  "code": "documentation",
  "base": ["PlanDefinition"],
  "type": "reference",
  "expression": "PlanDefinition.relatedArtifact.where(type='documentation').resource",
  "xpathUsage": "normal",
  "target": ["CarePlan"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# PlanDefinition.action.definitionCanonical SearchParameter (per _revinclude da ActivityDefinition)
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://your.fhir.server/SearchParameter/PlanDefinition-action-definition",
  "name": "action-definition",
  "status": "active",
  "description": "ActivityDefinition or PlanDefinition referenced in PlanDefinition.action.definitionCanonical or action.definition",
  "code": "action-definition",
  "base": ["PlanDefinition"],
  "type": "reference",
  "expression": "PlanDefinition.action.definitionCanonical | PlanDefinition.action.definition",
  "target": ["ActivityDefinition", "PlanDefinition"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# Group name SearchParameter
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "id": "group-name",
  "url": "http://hl7.org/fhir/SearchParameter/Group-name",
  "name": "name",
  "status": "active",
  "description": "Search by group name",
  "code": "name",
  "base": [
    "Group"
  ],
  "type": "string",
  "expression": "Group.name"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# Group identifier-assigner SearchParameter
JSON_BODY=$(cat <<EOF
{
    "resourceType": "SearchParameter",
    "status": "active",
    "code": "identifier-assigner",
    "base": [
        "Group"
    ],
    "type": "reference",
    "expression": "Group.identifier.assigner"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# Group assigner SearchParameter
JSON_BODY=$(cat <<EOF
{
    "resourceType": "SearchParameter",
    "status": "active",
    "code": "assigner",
    "base": [
        "Group"
    ],
    "type": "reference",
    "expression": "Group.identifier.assigner"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"


# Group questionnaire SearchParameter
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://yourserver/SearchParameter/group-questionnaire",
  "name": "group-questionnaire",
  "status": "active",
  "code": "questionnaire",
  "base": ["Group"],
  "type": "reference",
  "expression": "Group.characteristic.where(code.coding.code='questionnaire').value.ofType(Reference)",
  "target": ["Questionnaire"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# Create ADMIN first User inHAPI FHIR
JSON_BODY=$(cat <<EOF
{
      "resourceType": "Practitioner",
      "extension": [ ],
      "active": true,
      "name": [ {
        "text": " Gennaro Aurilia",
        "family": "Aurilia",
        "given": [ "Gennaro" ]
      } ],
      "telecom": [ {
        "system": "phone",
        "value": ""
      }, {
        "system": "email",
        "value": "gennaro.aurilia@gmail.com"
      } ]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/Practitioner" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# ── Consent ─────────────────────────────────────────────────────────────────
# La dashboard cerca i consensi con `Consent?patient=<id>&status=active`
# (vedi ConsentClient.fetchActiveConsents). Su alcuni HAPI questi param non sono
# attivi di default → la ricerca torna vuota anche se la risorsa esiste.
# Una volta installati, ogni salvataggio successivo viene indicizzato in automatico;
# per i consensi gia esistenti serve un $reindex una-tantum.

# Consent.patient (reference)
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://irccs.pascale.it/SearchParameter/Consent-patient",
  "name": "patient",
  "status": "active",
  "description": "Search Consent by patient reference",
  "code": "patient",
  "base": ["Consent"],
  "type": "reference",
  "expression": "Consent.patient",
  "target": ["Patient"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"

# Consent.status (token)
JSON_BODY=$(cat <<EOF
{
  "resourceType": "SearchParameter",
  "url": "http://irccs.pascale.it/SearchParameter/Consent-status",
  "name": "status",
  "status": "active",
  "description": "Search Consent by status",
  "code": "status",
  "base": ["Consent"],
  "type": "token",
  "expression": "Consent.status"
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"
