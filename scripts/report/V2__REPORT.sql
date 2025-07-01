CREATE OR REPLACE VIEW strat_statistics AS
/* ============================================================================
   PARAMETER: RESEARCH STUDY ID
   ===========================================================================*/
WITH study_param AS (
    SELECT 'ResearchStudy/' || lr.res_id::text AS study_ref
    FROM hapi.public.hfj_res_ver lr
    WHERE lr.res_type = 'ResearchStudy'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(lr.res_text_vc::jsonb -> 'identifier') AS ident
        WHERE ident ->> 'value' = 'PatientJourney'
    )
)

/* ============================================================================
   0.  LATEST VERSION OF EVERY RESOURCE
   ===========================================================================*/
   , latest_resources AS (
    SELECT DISTINCT ON (res_type, res_id)
    res_type,
    res_id,
    res_text_vc
FROM   hapi.public.hfj_res_ver
ORDER  BY res_type, res_id, res_ver DESC
    ),

/* ============================================================================
   1.  PATIENT / ORG / STUDY CONTEXT (filtered by study_param)
   ===========================================================================*/
    latest_patients      AS (SELECT res_id, res_text_vc FROM latest_resources WHERE res_type = 'Patient'),
    latest_organizations AS (SELECT res_id, res_text_vc FROM latest_resources WHERE res_type = 'Organization'),
    latest_research_subj AS (SELECT res_id, res_text_vc FROM latest_resources WHERE res_type = 'ResearchSubject'),

    patients_with_study_org AS (
SELECT
    p.res_id AS patient_id,
    o.res_text_vc::jsonb ->> 'name' AS org_name,
    o.res_id as org_id,
    rs.res_text_vc::jsonb -> 'study' ->> 'reference' AS study_ref
FROM latest_patients p
    JOIN latest_organizations o
ON p.res_text_vc::jsonb -> 'managingOrganization' ->> 'reference' = 'Organization/' || o.res_id::text
    JOIN latest_research_subj rs
    ON rs.res_text_vc::jsonb -> 'individual' ->> 'reference' = 'Patient/' || p.res_id::text
    JOIN study_param sp ON rs.res_text_vc::jsonb -> 'study' ->> 'reference' = sp.study_ref
    ),

/* ============================================================================
   1.b EXCLUDE PATIENTS WITH TASK METHOD 'choice'
   ===========================================================================*/
    included_patients AS (
select DISTINCT
    (tsk.res_text_vc::jsonb -> 'requester' ->> 'reference') AS patient_ref
FROM hapi.public.hfj_res_ver tsk
WHERE tsk.res_type = 'Task'
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(tsk.res_text_vc::jsonb -> 'input') as patient_input_vs
    WHERE patient_input_vs ->> 'valueString' = 'random'
    )
    ),

    patients_with_study_org_filtered AS (
SELECT *
FROM patients_with_study_org pso
WHERE 'Patient/' || pso.patient_id::text IN (SELECT patient_ref FROM included_patients)
    ),

/* ============================================================================
   2.  THERAPY / TREATMENT CODES (only latest Observations)
   ===========================================================================*/
    therapy_treatment_codes AS (
SELECT  po.patient_id,
    MAX(coding->>'code') FILTER (WHERE coding->>'display'='hasTherapyElegibility')   AS therapy_code,
    MAX(coding->>'code') FILTER (WHERE coding->>'display'='hasTreatmentEligibility') AS treatment_code
FROM    hapi.public.hfj_res_ver hrv
    JOIN    patients_with_study_org po
ON hrv.res_text_vc::jsonb -> 'subject' ->> 'reference'
    = 'Patient/' || po.patient_id::text
    CROSS   JOIN LATERAL jsonb_array_elements(hrv.res_text_vc::jsonb -> 'code' -> 'coding') AS coding
WHERE   hrv.res_type = 'Observation'
  AND   coding->>'display' IN ('hasTherapyElegibility','hasTreatmentEligibility')
GROUP   BY po.patient_id
    ),

/* ============================================================================
   3.  DYNAMIC + FALL-BACK QUESTION CODES
   ===========================================================================*/
    group_ids AS (
SELECT DISTINCT therapy_code AS group_id FROM therapy_treatment_codes WHERE therapy_code IS NOT NULL
UNION
SELECT DISTINCT treatment_code AS group_id FROM therapy_treatment_codes WHERE treatment_code IS NOT NULL
    ),

    groups_with_q AS (
SELECT
    gi.group_id,
    ch -> 'valueReference' ->> 'reference' AS questionnaire_ref
FROM group_ids gi
    JOIN latest_resources g
ON g.res_type = 'Group' AND g.res_id::text = gi.group_id
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.res_text_vc::jsonb -> 'characteristic', '[]'::jsonb)) AS ch
WHERE ch -> 'code' -> 'coding' @> '[{"code":"questionnaire"}]'
  AND ch -> 'valueReference' ->> 'reference' LIKE 'Questionnaire/%'
    ),

    strat_questionnaires AS (
SELECT lr.res_id, lr.res_text_vc
FROM latest_resources lr
    JOIN (
    SELECT DISTINCT substring(questionnaire_ref FROM 'Questionnaire/([0-9]+)$') AS q_id
    FROM groups_with_q
    ) q ON lr.res_type = 'Questionnaire' AND lr.res_id::text = q.q_id
WHERE EXISTS (
    SELECT 1
    FROM jsonb_array_elements(lr.res_text_vc::jsonb -> 'identifier') ident
    WHERE coalesce(ident ->> 'use','') = 'secondary'
  AND (
    lower(ident ->> 'value') = 'stratification'
   OR lower(ident ->> 'system') LIKE '%strat%'
    )
    )
    ),

    dynamic_question_codes AS (
SELECT DISTINCT code_obj ->> 'code' AS question_code
FROM strat_questionnaires sq
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(sq.res_text_vc::jsonb -> 'item', '[]'::jsonb)) AS itm
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(itm -> 'code', '[]'::jsonb)) AS code_obj
WHERE code_obj -> 'code' IS NOT NULL
    ),

    question_codes AS (
SELECT question_code FROM dynamic_question_codes
    ),

    question_answers AS (
SELECT DISTINCT
    qcode->>'code' AS question_code,
    acode->>'code' AS answer_code
FROM hapi.public.hfj_res_ver hrv
    JOIN patients_with_study_org_filtered po
ON hrv.res_text_vc::jsonb -> 'subject' ->> 'reference' = 'Patient/' || po.patient_id::text
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(hrv.res_text_vc::jsonb -> 'code' -> 'coding', '[]'::jsonb)) AS qcode
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(hrv.res_text_vc::jsonb -> 'valueCodeableConcept' -> 'coding', '[]'::jsonb)) AS acode
WHERE hrv.res_type = 'Observation'
  AND qcode->>'code' IN (SELECT question_code FROM question_codes)
    ),

/* ============================================================================
   4.  TITLES
   ===========================================================================*/
    therapy_titles AS (
SELECT DISTINCT ON (ra->>'resource')
    ra->>'resource' AS group_ref,
    ad.res_text_vc::jsonb ->> 'title' AS therapy_title
FROM hapi.public.hfj_res_ver ad
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(ad.res_text_vc::jsonb -> 'relatedArtifact', '[]'::jsonb)) AS ra
WHERE ad.res_type = 'ActivityDefinition'
  AND ra->>'type' = 'composed-of'
    ),

    treatment_titles AS (
SELECT DISTINCT ON (e->>'reference')
    e->>'reference' AS group_ref,
    rs.res_text_vc::jsonb ->> 'title' AS treatment_title
FROM hapi.public.hfj_res_ver rs
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(rs.res_text_vc::jsonb -> 'enrollment', '[]'::jsonb)) AS e
WHERE rs.res_type = 'ResearchStudy'
    ),

/* ============================================================================
   5.  STRATIFICATION ANSWERS (only latest Observations)
   ===========================================================================*/
    strat_answers AS (
SELECT  po.patient_id,
    po.study_ref,
    qcode->>'code'   AS question_code,
    acode->>'code'   AS answer_code
FROM    hapi.public.hfj_res_ver hrv
    JOIN    patients_with_study_org po
ON hrv.res_text_vc::jsonb -> 'subject' ->> 'reference'
    = 'Patient/' || po.patient_id::text
    CROSS   JOIN LATERAL jsonb_array_elements(hrv.res_text_vc::jsonb -> 'code' -> 'coding') AS qcode
    CROSS   JOIN LATERAL jsonb_array_elements(hrv.res_text_vc::jsonb -> 'valueCodeableConcept' -> 'coding') AS acode
WHERE   hrv.res_type = 'Observation'
  AND   qcode->>'code' IN (SELECT question_code FROM question_codes)
    ),

/* ============================================================================
   6.  FINAL AGGREGATION (ZERO-FILL ENABLED)
   ===========================================================================*/
    base AS (
SELECT DISTINCT
    pso.study_ref,
    pso.org_name,
    pso.org_id,
    ttc.therapy_code,
    ttc.treatment_code
FROM patients_with_study_org_filtered pso
    JOIN therapy_treatment_codes ttc USING (patient_id)
WHERE ttc.therapy_code IS NOT NULL
    ),

    question_answer_map AS (
SELECT DISTINCT
    itm_code ->> 'code' AS question_code,
    itm_code ->> 'display' AS question_display,
    (ans -> 'valueCoding') ->> 'code' AS answer_code,
    (ans -> 'valueCoding') ->> 'display' AS answer_display
FROM strat_questionnaires sq
    CROSS JOIN LATERAL jsonb_array_elements(sq.res_text_vc::jsonb -> 'item') AS itm
    CROSS JOIN LATERAL jsonb_array_elements(itm -> 'code') AS itm_code
    CROSS JOIN LATERAL jsonb_array_elements(itm -> 'answerOption') AS ans
WHERE itm_code ->> 'code' IS NOT NULL
  AND ans -> 'valueCoding' ->> 'code' IS NOT NULL
    ),
    all_combinations AS (
SELECT
    b.study_ref,
    b.org_name,
    b.org_id,
    b.therapy_code,
    b.treatment_code,
    qam.question_code,
    qam.question_display,
    qam.answer_code,
    qam.answer_display
FROM base b
    JOIN question_answer_map qam ON TRUE
    ),

    strat_counts AS (
SELECT
    sa.study_ref,
    pso.org_name,
    ttc.therapy_code,
    ttc.treatment_code,
    sa.question_code,
    sa.answer_code,
    COUNT(DISTINCT sa.patient_id) AS patient_count
FROM strat_answers sa
    JOIN therapy_treatment_codes ttc USING (patient_id)
    JOIN patients_with_study_org_filtered pso ON pso.patient_id = sa.patient_id
GROUP BY sa.study_ref, pso.org_name, pso.org_id,
    ttc.therapy_code, ttc.treatment_code,
    sa.question_code, sa.answer_code
    )

SELECT
    ac.study_ref,
    ac.org_name,
    ac.org_id,
    ac.therapy_code,
    COALESCE(ttl.therapy_title, '-') AS therapy_title,
    ac.treatment_code,
    COALESCE(trl.treatment_title, '-') AS treatment_title,
    ac.question_code,
    ac.question_display,
    ac.answer_code,
    ac.answer_display,
    COALESCE(sc.patient_count, 0) AS patient_count
FROM all_combinations ac
         LEFT JOIN strat_counts sc
                   ON ac.study_ref = sc.study_ref
                       AND ac.org_name = sc.org_name
                       AND ac.therapy_code = sc.therapy_code
                       AND ac.treatment_code = sc.treatment_code
                       AND ac.question_code = sc.question_code
                       AND ac.answer_code = sc.answer_code
         LEFT JOIN therapy_titles ttl ON ttl.group_ref = 'Group/' || ac.therapy_code
         LEFT JOIN treatment_titles trl ON trl.group_ref = 'Group/' || ac.treatment_code