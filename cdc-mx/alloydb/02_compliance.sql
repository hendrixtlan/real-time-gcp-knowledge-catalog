-- =============================================================================
-- AlloyDB schema 02: tablas de cumplimiento LFPDPPP
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS compliance;

-- =============================================================================
-- consent_log — Art. 8 LFPDPPP
-- Registro inmutable de consentimientos otorgados por titulares.
-- =============================================================================
CREATE TABLE compliance.consent_log (
    consent_id              BIGSERIAL PRIMARY KEY,
    titular_id              VARCHAR(64) NOT NULL,
    purpose                 VARCHAR(100) NOT NULL,
    consent_type            VARCHAR(20) NOT NULL CHECK (
        consent_type IN ('EXPRESS', 'TACIT', 'WITHDRAWN')
    ),
    privacy_notice_version  VARCHAR(20) NOT NULL,
    privacy_notice_url      TEXT,
    legal_basis             VARCHAR(50),
    collected_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    withdrawn_at            TIMESTAMPTZ,
    ip_address              INET,
    user_agent              TEXT,
    collection_channel      VARCHAR(50),  -- web, mobile, in_person, phone

    -- Para evidencia ante la Secretaría
    evidence_hash           VARCHAR(64),  -- hash SHA-256 del payload original

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ix_consent_titular ON compliance.consent_log (titular_id, purpose);
CREATE INDEX ix_consent_purpose_active ON compliance.consent_log (purpose)
    WHERE consent_type != 'WITHDRAWN' AND withdrawn_at IS NULL;

COMMENT ON TABLE compliance.consent_log IS
    'Registro inmutable de consentimientos. NO eliminar filas; usar withdrawn_at.';

-- Trigger: prevenir DELETE
CREATE OR REPLACE FUNCTION compliance.prevent_delete()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'compliance: DELETE no permitido en %, usar withdrawn_at', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_consent_no_delete
    BEFORE DELETE ON compliance.consent_log
    FOR EACH ROW EXECUTE FUNCTION compliance.prevent_delete();

-- =============================================================================
-- arco_requests — Art. 22 LFPDPPP
-- Solicitudes de derechos ARCO con SLA tracking automático.
-- =============================================================================
CREATE TABLE compliance.arco_requests (
    request_id              BIGSERIAL PRIMARY KEY,
    titular_id              VARCHAR(64) NOT NULL,
    titular_id_hash         VARCHAR(64),  -- SHA-256 para audit en BQ sin exponer PII
    request_type            VARCHAR(20) NOT NULL CHECK (
        request_type IN ('ACCESS', 'RECTIFICATION', 'CANCELLATION', 'OBJECTION')
    ),

    -- Solicitud
    submitted_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    submitted_via           VARCHAR(50),  -- web, email, in_person, phone
    submitted_by_email      VARCHAR(320),
    identity_verified       BOOLEAN NOT NULL DEFAULT FALSE,
    identity_verification_method VARCHAR(50),

    -- Detalles según tipo
    request_payload         JSONB,        -- detalles específicos
    affected_fields         TEXT[],       -- para rectificación

    -- SLA Art. 22
    deadline_resolution     TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '20 days'),
    deadline_execution      TIMESTAMPTZ,  -- se calcula al resolver

    -- Resolución
    resolution              VARCHAR(20) CHECK (
        resolution IS NULL OR resolution IN (
            'GRANTED', 'PARTIAL', 'DENIED', 'CANCELLED'
        )
    ),
    resolution_reason       TEXT,
    resolved_at             TIMESTAMPTZ,
    resolved_by             VARCHAR(100),

    -- Ejecución
    executed_at             TIMESTAMPTZ,
    execution_evidence_url  TEXT,         -- GCS signed URL al export, etc.

    -- Estado del SLA
    sla_breached            BOOLEAN GENERATED ALWAYS AS (
        resolved_at IS NOT NULL AND resolved_at > deadline_resolution
    ) STORED,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ix_arco_titular ON compliance.arco_requests (titular_id);
CREATE INDEX ix_arco_type_status ON compliance.arco_requests (request_type, resolution);
CREATE INDEX ix_arco_deadline ON compliance.arco_requests (deadline_resolution)
    WHERE resolved_at IS NULL;
CREATE INDEX ix_arco_at_risk ON compliance.arco_requests (deadline_resolution)
    WHERE resolved_at IS NULL AND deadline_resolution < (NOW() + INTERVAL '3 days');

-- Trigger: actualizar updated_at y calcular hash
CREATE OR REPLACE FUNCTION compliance.arco_before_upsert()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    IF NEW.titular_id_hash IS NULL AND NEW.titular_id IS NOT NULL THEN
        NEW.titular_id_hash = encode(digest(NEW.titular_id, 'sha256'), 'hex');
    END IF;
    -- Si se está resolviendo, calcular deadline de ejecución
    IF NEW.resolved_at IS NOT NULL AND OLD.resolved_at IS NULL THEN
        NEW.deadline_execution = NEW.resolved_at + INTERVAL '15 days';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tg_arco_before_upsert
    BEFORE INSERT OR UPDATE ON compliance.arco_requests
    FOR EACH ROW EXECUTE FUNCTION compliance.arco_before_upsert();

-- =============================================================================
-- Vista: solicitudes próximas a vencer (alimenta SLA check del scheduler)
-- =============================================================================
CREATE OR REPLACE VIEW compliance.v_arco_at_risk AS
SELECT
    request_id,
    titular_id_hash,
    request_type,
    submitted_at,
    deadline_resolution,
    EXTRACT(EPOCH FROM (deadline_resolution - NOW())) / 3600 AS hours_remaining,
    CASE
        WHEN deadline_resolution < NOW() THEN 'BREACHED'
        WHEN deadline_resolution < NOW() + INTERVAL '24 hours' THEN 'CRITICAL'
        WHEN deadline_resolution < NOW() + INTERVAL '72 hours' THEN 'WARNING'
        ELSE 'OK'
    END AS sla_status
FROM compliance.arco_requests
WHERE resolved_at IS NULL
ORDER BY deadline_resolution ASC;

-- =============================================================================
-- deletion_log — Art. 27 LFPDPPP
-- Bitácora de cancelaciones y bloqueos para evidencia ante la Secretaría.
-- =============================================================================
CREATE TABLE compliance.deletion_log (
    deletion_id             BIGSERIAL PRIMARY KEY,
    arco_request_id         BIGINT REFERENCES compliance.arco_requests(request_id),
    titular_id_hash         VARCHAR(64) NOT NULL,
    action                  VARCHAR(20) NOT NULL CHECK (
        action IN ('ANONYMIZE', 'DELETE', 'BLOCK')
    ),
    table_name              VARCHAR(100) NOT NULL,
    affected_rows           INTEGER NOT NULL DEFAULT 0,

    -- Si fue bloqueo (no eliminación) por obligación legal
    retention_basis         VARCHAR(100),
    retention_legal_ref     VARCHAR(200),  -- e.g. "CFF Art. 30"
    retention_until         DATE,

    executed_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    executed_by             VARCHAR(100),

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ix_deletion_arco ON compliance.deletion_log (arco_request_id);
CREATE INDEX ix_deletion_titular ON compliance.deletion_log (titular_id_hash);

CREATE TRIGGER tg_deletion_no_delete
    BEFORE DELETE ON compliance.deletion_log
    FOR EACH ROW EXECUTE FUNCTION compliance.prevent_delete();

-- =============================================================================
-- breach_log — Art. 20 LFPDPPP
-- =============================================================================
CREATE TABLE compliance.breach_log (
    breach_id               BIGSERIAL PRIMARY KEY,
    severity                VARCHAR(10) NOT NULL CHECK (
        severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')
    ),
    discovered_at           TIMESTAMPTZ NOT NULL,
    confirmed_at            TIMESTAMPTZ,
    discovered_by           VARCHAR(200),
    description             TEXT NOT NULL,
    affected_systems        TEXT[],
    estimated_records_affected INTEGER,
    data_categories         TEXT[],         -- EMAIL, PHONE, CURP, etc.

    -- Notificaciones
    titulares_notified_at   TIMESTAMPTZ,
    titulares_notified_count INTEGER,
    secretaria_notified_at  TIMESTAMPTZ,
    notification_method     VARCHAR(50),

    -- Containment
    contained_at            TIMESTAMPTZ,
    containment_actions     TEXT,

    -- Post-mortem
    root_cause              TEXT,
    remediation             TEXT,
    closed_at               TIMESTAMPTZ,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ix_breach_severity ON compliance.breach_log (severity, discovered_at DESC);
CREATE INDEX ix_breach_open ON compliance.breach_log (discovered_at) WHERE closed_at IS NULL;

CREATE TRIGGER tg_breach_no_delete
    BEFORE DELETE ON compliance.breach_log
    FOR EACH ROW EXECUTE FUNCTION compliance.prevent_delete();

-- =============================================================================
-- Función: anonimizar titular (para cancelación con bloqueo Art. 27)
-- =============================================================================
CREATE OR REPLACE FUNCTION compliance.anonymize_titular(
    p_titular_id BIGINT,
    p_arco_request_id BIGINT,
    p_executed_by VARCHAR
) RETURNS JSONB AS $$
DECLARE
    v_titular_hash VARCHAR(64);
    v_orders_count INTEGER;
    v_anonymized_email VARCHAR(320);
    v_anonymized_phone VARCHAR(20);
    v_result JSONB;
BEGIN
    v_titular_hash := encode(digest(p_titular_id::TEXT, 'sha256'), 'hex');
    v_anonymized_email := 'anon-' || substring(v_titular_hash, 1, 16) || '@anon.local';
    v_anonymized_phone := '0000000000';

    -- Verificar si tiene órdenes (CFF Art. 30: retención fiscal 5 años)
    SELECT COUNT(*) INTO v_orders_count
    FROM app.orders
    WHERE customer_id = p_titular_id
      AND placed_at > NOW() - INTERVAL '5 years';

    -- Anonimizar campos PII puros
    UPDATE app.customers
    SET email = v_anonymized_email,
        phone = v_anonymized_phone,
        first_name = 'ANONYMIZED',
        last_name = 'ANONYMIZED'
    WHERE customer_id = p_titular_id;

    -- Registrar en deletion_log
    IF v_orders_count > 0 THEN
        -- Bloqueo (Art. 27): mantener registros financieros
        INSERT INTO compliance.deletion_log (
            arco_request_id, titular_id_hash, action, table_name,
            affected_rows, retention_basis, retention_legal_ref,
            retention_until, executed_by
        ) VALUES (
            p_arco_request_id, v_titular_hash, 'BLOCK', 'app.customers',
            1, 'Obligación fiscal de retener registros contables',
            'Código Fiscal de la Federación, Art. 30',
            CURRENT_DATE + INTERVAL '5 years', p_executed_by
        );

        v_result := jsonb_build_object(
            'action', 'PARTIAL_ANONYMIZATION',
            'reason', 'Registros financieros retenidos por CFF Art. 30',
            'orders_retained', v_orders_count,
            'retention_until', (CURRENT_DATE + INTERVAL '5 years')::TEXT
        );
    ELSE
        -- Anonimización completa
        INSERT INTO compliance.deletion_log (
            arco_request_id, titular_id_hash, action, table_name,
            affected_rows, executed_by
        ) VALUES (
            p_arco_request_id, v_titular_hash, 'ANONYMIZE', 'app.customers',
            1, p_executed_by
        );

        v_result := jsonb_build_object(
            'action', 'FULL_ANONYMIZATION',
            'orders_retained', 0
        );
    END IF;

    -- Withdraw consentimientos
    UPDATE compliance.consent_log
    SET consent_type = 'WITHDRAWN', withdrawn_at = NOW()
    WHERE titular_id = p_titular_id::TEXT
      AND withdrawn_at IS NULL;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- Permisos
-- =============================================================================
CREATE ROLE arco_service NOLOGIN;
GRANT USAGE ON SCHEMA compliance TO arco_service;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA compliance TO arco_service;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA compliance TO arco_service;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA compliance TO arco_service;

GRANT USAGE ON SCHEMA app TO arco_service;
GRANT SELECT, UPDATE ON app.customers, app.orders, app.order_items TO arco_service;
