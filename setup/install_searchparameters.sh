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

# Enrollment SearchParameter
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
  "expression": "ActivityDefinition.relatedArtifact.where(type = 'documentation').url",
  "xpathUsage": "normal",
  "target": ["CarePlan"]
}
EOF
)
curl -s -X POST "http://$HOSTNAME_PORT/fhir/SearchParameter" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY"
