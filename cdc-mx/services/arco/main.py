#!/usr/bin/env python3
"""
ARCO service — derechos de Acceso, Rectificación, Cancelación y Oposición
según Art. 22 de la Nueva LFPDPPP 2025.

Endpoints:
  POST /arco/access          — derecho de acceso (export de datos)
  POST /arco/rectification   — derecho de rectificación
  POST /arco/cancellation    — derecho de cancelación con bloqueo Art. 27
  POST /arco/objection       — derecho de oposición (withdraw consent)
  POST /arco/sla-check       — invocado por Cloud Scheduler cada 4h
  POST /arco/breach-notify   — registra brecha de seguridad Art. 20
  GET  /health               — liveness probe

Cada endpoint requiere identity_verified=true (la verificación ocurre
upstream, este servicio no maneja autenticación de titulares).

SLA Art. 22:
  - 20 días naturales para resolver
  - 15 días adicionales para ejecutar la resolución
  - SLA breach se registra con sla_breached=true
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from datetime import datetime, timezone, timedelta
from typing import Any

import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, request
from google.cloud import bigquery, pubsub_v1, secretmanager, storage

logging.basicConfig(level=logging.INFO,
                   format='%(asctime)s %(levelname)s %(message)s')
LOGGER = logging.getLogger(__name__)

app = Flask(__name__)

# =============================================================================
# Configuración (env vars inyectadas por Terraform)
# =============================================================================
PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
BQ_DATASET = os.environ["BQ_DATASET"]
BQ_OPS_DATASET = os.environ["BQ_OPS_DATASET"]
EXPORT_BUCKET = os.environ["EXPORT_BUCKET"]
BREACH_TOPIC = os.environ["BREACH_TOPIC"]
ALLOYDB_CONN_SECRET = os.environ["ALLOYDB_CONN_SECRET"]
ALLOYDB_PASSWORD_SECRET = os.environ["ALLOYDB_PASSWORD_SECRET"]


# =============================================================================
# Clientes
# =============================================================================
_secret_client = secretmanager.SecretManagerServiceClient()
_storage_client = storage.Client()
_bq_client = bigquery.Client()
_pubsub_publisher = pubsub_v1.PublisherClient()


def _get_secret(secret_id: str) -> str:
    name = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"
    response = _secret_client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")


def _get_db_conn():
    """Connection a AlloyDB."""
    conn_string = _get_secret(ALLOYDB_CONN_SECRET)
    password = _get_secret(ALLOYDB_PASSWORD_SECRET)
    return psycopg2.connect(
        dsn=conn_string,
        password=password,
        connect_timeout=10,
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def _hash_titular(titular_id: str) -> str:
    return hashlib.sha256(str(titular_id).encode()).hexdigest()


def _audit_log(event_type: str, payload: dict[str, Any]) -> None:
    """Logging estructurado para Cloud Logging — alimenta alert policies."""
    LOGGER.info(json.dumps({
        "event_type": event_type,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        **payload,
    }))


# =============================================================================
# Validación común
# =============================================================================
def _validate_arco_request(body: dict, required_fields: list[str]):
    if not body.get("identity_verified"):
        return jsonify({
            "error": "identity_verification_required",
            "message": ("La verificación de identidad debe ocurrir upstream "
                        "antes de invocar este endpoint.")
        }), 403

    for field in required_fields:
        if field not in body:
            return jsonify({"error": "missing_field", "field": field}), 400

    return None


def _create_arco_request(
    titular_id: str,
    request_type: str,
    payload: dict,
    submitted_by_email: str | None = None,
    submitted_via: str = "api",
    identity_method: str = "upstream",
):
    """Inserta solicitud y retorna (request_id, deadline_resolution)."""
    with _get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO compliance.arco_requests (
                    titular_id, request_type, submitted_via,
                    submitted_by_email, identity_verified,
                    identity_verification_method, request_payload
                ) VALUES (%s, %s, %s, %s, TRUE, %s, %s)
                RETURNING request_id, deadline_resolution
            """, (
                titular_id, request_type, submitted_via,
                submitted_by_email, identity_method,
                psycopg2.extras.Json(payload),
            ))
            result = cur.fetchone()
            conn.commit()
            return result["request_id"], result["deadline_resolution"]


def _resolve_arco_request(
    request_id: int,
    resolution: str,
    resolution_reason: str,
    resolved_by: str,
    execution_evidence_url: str | None = None,
) -> None:
    with _get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE compliance.arco_requests
                SET resolution = %s,
                    resolution_reason = %s,
                    resolved_at = NOW(),
                    resolved_by = %s,
                    executed_at = CASE WHEN %s IS NOT NULL THEN NOW() ELSE NULL END,
                    execution_evidence_url = %s
                WHERE request_id = %s
            """, (resolution, resolution_reason, resolved_by,
                  execution_evidence_url, execution_evidence_url, request_id))
            conn.commit()


# =============================================================================
# /arco/access — derecho de acceso (Art. 22)
# =============================================================================
@app.route("/arco/access", methods=["POST"])
def arco_access():
    body = request.get_json(force=True)
    err = _validate_arco_request(body, ["titular_id", "identity_verified"])
    if err:
        return err

    titular_id = str(body["titular_id"])
    request_id, deadline = _create_arco_request(
        titular_id=titular_id,
        request_type="ACCESS",
        payload={"requested_format": body.get("format", "json")},
        submitted_by_email=body.get("email"),
    )

    # Export en BQ → GCS
    export_uri = f"gs://{EXPORT_BUCKET}/arco/{request_id}/customer_data.json"
    query = f"""
        EXPORT DATA OPTIONS(
            uri='{export_uri}',
            format='JSON',
            overwrite=true
        ) AS
        SELECT
            c.* EXCEPT(_metadata),
            ARRAY_AGG(STRUCT(o.*)) AS orders
        FROM `{PROJECT_ID}.{BQ_DATASET}.APP_SCHEMA_CUSTOMERS` c
        LEFT JOIN `{PROJECT_ID}.{BQ_DATASET}.APP_SCHEMA_ORDERS` o
            ON c.CUSTOMER_ID = o.CUSTOMER_ID
        WHERE c.CUSTOMER_ID = @titular_id
        GROUP BY c
    """
    try:
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("titular_id", "INT64",
                                              int(titular_id)),
            ]
        )
        query_job = _bq_client.query(query, job_config=job_config)
        query_job.result(timeout=60)
    except Exception as e:
        LOGGER.exception("Error en export ARCO access: %s", e)
        _resolve_arco_request(request_id, "DENIED",
                             f"export_failed: {e}", "system")
        return jsonify({"error": "export_failed",
                       "request_id": request_id}), 500

    # Signed URL válido 7 días
    bucket = _storage_client.bucket(EXPORT_BUCKET)
    blob = bucket.blob(f"arco/{request_id}/customer_data.json")
    signed_url = blob.generate_signed_url(
        version="v4",
        expiration=timedelta(days=7),
        method="GET",
    )

    _resolve_arco_request(
        request_id=request_id,
        resolution="GRANTED",
        resolution_reason="Export generated and delivered via signed URL",
        resolved_by="arco-service",
        execution_evidence_url=export_uri,
    )

    _audit_log("ARCO_ACCESS_GRANTED", {
        "request_id": request_id,
        "titular_hash": _hash_titular(titular_id),
    })

    return jsonify({
        "request_id": request_id,
        "status": "GRANTED",
        "deadline_resolution": deadline.isoformat(),
        "download_url": signed_url,
        "expires_in_days": 7,
        "lfpdppp_article": "Art. 22 - Derecho de Acceso",
    })


# =============================================================================
# /arco/rectification — derecho de rectificación
# =============================================================================
@app.route("/arco/rectification", methods=["POST"])
def arco_rectification():
    body = request.get_json(force=True)
    err = _validate_arco_request(
        body, ["titular_id", "identity_verified", "field_changes"]
    )
    if err:
        return err

    titular_id = str(body["titular_id"])
    field_changes = body["field_changes"]

    request_id, deadline = _create_arco_request(
        titular_id=titular_id,
        request_type="RECTIFICATION",
        payload={"field_changes": field_changes},
        submitted_by_email=body.get("email"),
    )

    # Oracle es Source of Truth. NO actualizamos AlloyDB directamente
    # para evitar conflictos con CDC.
    _audit_log("ARCO_RECTIFICATION_PENDING", {
        "request_id": request_id,
        "titular_hash": _hash_titular(titular_id),
        "fields": list(field_changes.keys()),
    })

    return jsonify({
        "request_id": request_id,
        "status": "PENDING",
        "message": ("Solicitud registrada. La rectificación debe aplicarse "
                    "en Oracle (Source of Truth) y se propagará vía CDC. "
                    "Tiempo estimado: 1-3s a AlloyDB, 5-30s a BigQuery."),
        "deadline_resolution": deadline.isoformat(),
        "lfpdppp_article": "Art. 22 - Derecho de Rectificación",
        "next_step": ("Equipo de aplicación debe aplicar UPDATE en Oracle. "
                      "Confirmar via PATCH /arco/requests/{id}/confirm"),
    })


# =============================================================================
# /arco/cancellation — derecho de cancelación + Art. 27 (bloqueo)
# =============================================================================
@app.route("/arco/cancellation", methods=["POST"])
def arco_cancellation():
    body = request.get_json(force=True)
    err = _validate_arco_request(body, ["titular_id", "identity_verified"])
    if err:
        return err

    titular_id = str(body["titular_id"])

    request_id, deadline = _create_arco_request(
        titular_id=titular_id,
        request_type="CANCELLATION",
        payload={"reason": body.get("reason", "no_reason_provided")},
        submitted_by_email=body.get("email"),
    )

    # La función AlloyDB decide: anonimizar completo o bloquear si CFF aplica
    try:
        with _get_db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT compliance.anonymize_titular(%s, %s, %s) AS result",
                    (int(titular_id), request_id, "arco-service")
                )
                result = cur.fetchone()["result"]
                conn.commit()
    except Exception as e:
        LOGGER.exception("Error en anonimización: %s", e)
        _resolve_arco_request(request_id, "DENIED",
                             f"anon_failed: {e}", "system")
        return jsonify({"error": "anonymization_failed",
                       "request_id": request_id}), 500

    if result.get("action") == "PARTIAL_ANONYMIZATION":
        resolution = "PARTIAL"
        reason = (
            f"Anonimización parcial. Datos financieros retenidos por "
            f"obligación legal: {result.get('reason', 'CFF Art. 30')}. "
            f"Retención hasta: {result.get('retention_until')}."
        )
        article = "Art. 27 - Bloqueo por obligación legal"
    else:
        resolution = "GRANTED"
        reason = "Anonimización completa aplicada"
        article = "Art. 22 - Derecho de Cancelación"

    _resolve_arco_request(
        request_id=request_id,
        resolution=resolution,
        resolution_reason=reason,
        resolved_by="arco-service",
    )

    _audit_log("ARCO_CANCELLATION_RESOLVED", {
        "request_id": request_id,
        "titular_hash": _hash_titular(titular_id),
        "resolution": resolution,
        "action": result.get("action"),
    })

    return jsonify({
        "request_id": request_id,
        "status": resolution,
        "action": result.get("action"),
        "reason": reason,
        "lfpdppp_article": article,
        "deadline_resolution": deadline.isoformat(),
    })


# =============================================================================
# /arco/objection — derecho de oposición
# =============================================================================
@app.route("/arco/objection", methods=["POST"])
def arco_objection():
    body = request.get_json(force=True)
    err = _validate_arco_request(
        body, ["titular_id", "identity_verified", "purposes"]
    )
    if err:
        return err

    titular_id = str(body["titular_id"])
    purposes = body["purposes"]

    request_id, deadline = _create_arco_request(
        titular_id=titular_id,
        request_type="OBJECTION",
        payload={"purposes_withdrawn": purposes},
        submitted_by_email=body.get("email"),
    )

    with _get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                UPDATE compliance.consent_log
                SET consent_type = 'WITHDRAWN',
                    withdrawn_at = NOW()
                WHERE titular_id = %s
                  AND purpose = ANY(%s)
                  AND withdrawn_at IS NULL
                RETURNING consent_id
            """, (titular_id, purposes))
            withdrawn = cur.fetchall()
            conn.commit()

    _resolve_arco_request(
        request_id=request_id,
        resolution="GRANTED",
        resolution_reason=f"Withdrew consent for {len(withdrawn)} entries",
        resolved_by="arco-service",
    )

    _audit_log("ARCO_OBJECTION_GRANTED", {
        "request_id": request_id,
        "titular_hash": _hash_titular(titular_id),
        "purposes_count": len(purposes),
        "consents_withdrawn": len(withdrawn),
    })

    return jsonify({
        "request_id": request_id,
        "status": "GRANTED",
        "purposes_withdrawn": purposes,
        "consents_withdrawn_count": len(withdrawn),
        "lfpdppp_article": "Art. 22 - Derecho de Oposición",
        "deadline_resolution": deadline.isoformat(),
    })


# =============================================================================
# /arco/sla-check — invocado por Cloud Scheduler cada 4h
# =============================================================================
@app.route("/arco/sla-check", methods=["POST"])
def arco_sla_check():
    """Detecta solicitudes próximas al deadline y emite alertas."""
    with _get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT request_id, request_type, submitted_at,
                       deadline_resolution, hours_remaining, sla_status
                FROM compliance.v_arco_at_risk
                WHERE sla_status IN ('CRITICAL', 'BREACHED')
            """)
            at_risk = cur.fetchall()

    for r in at_risk:
        _audit_log("ARCO_SLA_CRITICAL", {
            "request_id": r["request_id"],
            "request_type": r["request_type"],
            "hours_remaining": float(r["hours_remaining"]),
            "sla_status": r["sla_status"],
            "deadline": r["deadline_resolution"].isoformat(),
        })

    return jsonify({
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "at_risk_count": len(at_risk),
        "critical_count": sum(1 for r in at_risk if r["sla_status"] == "CRITICAL"),
        "breached_count": sum(1 for r in at_risk if r["sla_status"] == "BREACHED"),
    })


# =============================================================================
# /arco/breach-notify — Art. 20 LFPDPPP
# =============================================================================
@app.route("/arco/breach-notify", methods=["POST"])
def breach_notify():
    body = request.get_json(force=True)

    required = ["severity", "affected_systems", "description"]
    for f in required:
        if f not in body:
            return jsonify({"error": "missing_field", "field": f}), 400

    with _get_db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO compliance.breach_log (
                    severity, discovered_at, discovered_by,
                    description, affected_systems,
                    estimated_records_affected, data_categories
                ) VALUES (%s, NOW(), %s, %s, %s, %s, %s)
                RETURNING breach_id
            """, (
                body["severity"],
                body.get("discovered_by", "unknown"),
                body["description"],
                body["affected_systems"],
                body.get("estimated_records_affected"),
                body.get("data_categories", []),
            ))
            breach_id = cur.fetchone()["breach_id"]
            conn.commit()

    # Publica al topic para que el playbook se active
    topic_path = _pubsub_publisher.topic_path(PROJECT_ID, BREACH_TOPIC)
    _pubsub_publisher.publish(
        topic_path,
        json.dumps({
            "breach_id": breach_id,
            "severity": body["severity"],
            "discovered_at": datetime.now(timezone.utc).isoformat(),
            "affected_systems": body["affected_systems"],
            "estimated_records_affected": body.get("estimated_records_affected"),
            "data_categories": body.get("data_categories", []),
        }).encode("utf-8")
    )

    _audit_log("DATA_BREACH_DETECTED", {
        "breach_id": breach_id,
        "severity": body["severity"],
        "estimated_records": body.get("estimated_records_affected"),
    })

    return jsonify({
        "breach_id": breach_id,
        "status": "REGISTERED",
        "lfpdppp_article": "Art. 20 - Notificación de vulneraciones",
        "next_steps": [
            "Activar plan de respuesta a incidentes",
            "Confirmar alcance y contener",
            "Notificar a titulares afectados (recomendado: 72h)",
            "Documentar acciones para evidencia ante Secretaría",
        ],
    }), 201


# =============================================================================
# Health
# =============================================================================
@app.route("/health", methods=["GET"])
def health():
    try:
        with _get_db_conn() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        return jsonify({"status": "ok"}), 200
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 503


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
