-- ============================================================================
-- Protezione a livello database degli AuditEvent (immodificabilita' / WORM).
--
-- Complemento agli interceptor HAPI (AuditEventAppendOnlyInterceptor,
-- AuditEventHashChainInterceptor): quelli agiscono a livello applicativo/REST,
-- questi trigger agiscono direttamente su Postgres e coprono anche chi ha
-- accesso SQL diretto al database (amministratore di sistema).
--
-- Cosa e' consentito su una riga con res_type = 'AuditEvent':
--   - INSERT (append)
--   - UPDATE di sp_index_status / colonne di indicizzazione ($reindex)
-- Cosa e' BLOCCATO:
--   - DELETE su hfj_resource / hfj_res_ver (hard delete, $expunge)
--   - UPDATE che valorizza res_deleted_at (soft delete) o incrementa res_ver
--     (nuova versione = modifica via API)
--   - UPDATE del contenuto della risorsa (hfj_res_ver.res_text_vc / res_text)
--
-- Idempotente: rieseguibile senza effetti collaterali.
-- Applicare al database di HAPI FHIR (non a quello di Keycloak).
-- ============================================================================

CREATE OR REPLACE FUNCTION irccs_block_auditevent_mutation() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.res_type = 'AuditEvent' THEN
            RAISE EXCEPTION 'AuditEvent e'' append-only: DELETE non consentito (res_id=%)', OLD.res_id
                USING ERRCODE = 'check_violation';
        END IF;
        RETURN OLD;
    END IF;

    -- UPDATE
    IF OLD.res_type = 'AuditEvent' THEN
        IF TG_TABLE_NAME = 'hfj_resource' THEN
            IF (NEW.res_deleted_at IS DISTINCT FROM OLD.res_deleted_at)
               OR (NEW.res_ver IS DISTINCT FROM OLD.res_ver) THEN
                RAISE EXCEPTION 'AuditEvent e'' append-only: UPDATE non consentito (res_id=%)', OLD.res_id
                    USING ERRCODE = 'check_violation';
            END IF;
        ELSIF TG_TABLE_NAME = 'hfj_res_ver' THEN
            IF (NEW.res_text_vc IS DISTINCT FROM OLD.res_text_vc)
               OR (NEW.res_text IS DISTINCT FROM OLD.res_text)
               OR (NEW.res_encoding IS DISTINCT FROM OLD.res_encoding) THEN
                RAISE EXCEPTION 'AuditEvent e'' append-only: modifica del contenuto non consentita (res_id=%)', OLD.res_id
                    USING ERRCODE = 'check_violation';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_auditevent_no_delete_resource ON hfj_resource;
CREATE TRIGGER trg_auditevent_no_delete_resource
    BEFORE DELETE ON hfj_resource
    FOR EACH ROW EXECUTE FUNCTION irccs_block_auditevent_mutation();

DROP TRIGGER IF EXISTS trg_auditevent_no_update_resource ON hfj_resource;
CREATE TRIGGER trg_auditevent_no_update_resource
    BEFORE UPDATE ON hfj_resource
    FOR EACH ROW EXECUTE FUNCTION irccs_block_auditevent_mutation();

DROP TRIGGER IF EXISTS trg_auditevent_no_delete_resver ON hfj_res_ver;
CREATE TRIGGER trg_auditevent_no_delete_resver
    BEFORE DELETE ON hfj_res_ver
    FOR EACH ROW EXECUTE FUNCTION irccs_block_auditevent_mutation();

DROP TRIGGER IF EXISTS trg_auditevent_no_update_resver ON hfj_res_ver;
CREATE TRIGGER trg_auditevent_no_update_resver
    BEFORE UPDATE ON hfj_res_ver
    FOR EACH ROW EXECUTE FUNCTION irccs_block_auditevent_mutation();
