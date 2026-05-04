#!/usr/bin/env python3
"""
Reconciliation service — valida que Oracle, BigQuery y AlloyDB sean consistentes.

Ejecutado por Cloud Scheduler cada hora. Si detecta divergencia > threshold,
emite log con severity ERROR (dispara alerta).

Estrategia:
  1. COUNT(*) por tabla en cada sink.
  2. Si counts difieren > 0.1%, log ERROR con detalle.
  3. Reporta en formato estructurado para análisis.

Endpoint: POST /reconcile
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone

import oracledb
import psycopg2
import psycopg2.extras
from flask import Flask, jsonify
from google.cloud import bigquery, secretmanager

logging.basicConfig(level=logging.INFO,
                   format='%(asctime)s %(levelname)s %(message)s')
LOGGER = logging.getLogger(__name__)

app = Flask(__name__)

PROJECT_ID = os.environ["PROJECT_ID"]
BQ_DATASET = os.environ["BQ_DATASET"]
ALLOYDB_CONN_SECRET = os.environ["ALLOYDB_CONN_SECRET"]
ALLOYDB_PASSWORD_SECRET = os.environ["ALLOYDB_PASSWORD_SECRET"]
ORACLE_DSN_SECRET = os.environ["ORACLE_DSN_SECRET"]
ORACLE_USER_SECRET = os.environ["ORACLE_USER_SECRET"]
ORACLE_PASSWORD_SECRET = os.environ["ORACLE_PASSWORD_SECRET"]

DIVERGENCE_THRESHOLD = float(os.environ.get("DIVERGENCE_THRESHOLD", "0.001"))

_secret_client = secretmanager.SecretManagerServiceClient()
_bq_client = bigquery.Client()


# =============================================================================
# Tablas a reconciliar (debe coincidir con cdc_tables del Terraform)
# =============================================================================
TABLES = [
    {
        "oracle_schema": "APP_SCHEMA",
        "oracle_table": "CUSTOMERS",
        "bq_table": "APP_SCHEMA_CUSTOMERS",
        "alloydb_schema": "app",
        "alloydb_table": "customers",
    },
    {
        "oracle_schema": "APP_SCHEMA",
        "oracle_table": "ORDERS",
        "bq_table": "APP_SCHEMA_ORDERS",
        "alloydb_schema": "app",
        "alloydb_table": "orders",
    },
    {
        "oracle_schema": "APP_SCHEMA",
        "oracle_table": "ORDER_ITEMS",
        "bq_table": "APP_SCHEMA_ORDER_ITEMS",
        "alloydb_schema": "app",
        "alloydb_table": "order_items",
    },
]


def _get_secret(secret_id: str) -> str:
    name = f"projects/{PROJECT_ID}/secrets/{secret_id}/versions/latest"
    return _secret_client.access_secret_version(
        request={"name": name}
    ).payload.data.decode("UTF-8")


def _oracle_conn():
    return oracledb.connect(
        user=_get_secret(ORACLE_USER_SECRET),
        password=_get_secret(ORACLE_PASSWORD_SECRET),
        dsn=_get_secret(ORACLE_DSN_SECRET),
    )


def _alloydb_conn():
    return psycopg2.connect(
        dsn=_get_secret(ALLOYDB_CONN_SECRET),
        password=_get_secret(ALLOYDB_PASSWORD_SECRET),
        connect_timeout=10,
    )


def _count_oracle(table_cfg: dict) -> int:
    sql = (f"SELECT COUNT(*) FROM "
           f"{table_cfg['oracle_schema']}.{table_cfg['oracle_table']}")
    with _oracle_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return cur.fetchone()[0]


def _count_bq(table_cfg: dict) -> int:
    table_ref = f"{PROJECT_ID}.{BQ_DATASET}.{table_cfg['bq_table']}"
    query = f"SELECT COUNT(*) AS c FROM `{table_ref}`"
    return list(_bq_client.query(query).result())[0].c


def _count_alloydb(table_cfg: dict) -> int:
    sql = (f"SELECT COUNT(*) FROM "
           f"{table_cfg['alloydb_schema']}.{table_cfg['alloydb_table']} "
           f"WHERE NOT is_deleted")
    with _alloydb_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            return cur.fetchone()[0]


def _reconcile_table(table_cfg: dict) -> dict:
    LOGGER.info("Reconciling %s.%s",
                table_cfg["oracle_schema"], table_cfg["oracle_table"])

    try:
        oracle_count = _count_oracle(table_cfg)
        bq_count = _count_bq(table_cfg)
        alloydb_count = _count_alloydb(table_cfg)
    except Exception as e:
        LOGGER.exception("Error obteniendo counts: %s", e)
        return {
            "table": f"{table_cfg['oracle_schema']}.{table_cfg['oracle_table']}",
            "status": "ERROR",
            "error": str(e),
        }

    bq_diff_pct = abs(oracle_count - bq_count) / max(oracle_count, 1)
    alloydb_diff_pct = abs(oracle_count - alloydb_count) / max(oracle_count, 1)

    bq_ok = bq_diff_pct < DIVERGENCE_THRESHOLD
    alloydb_ok = alloydb_diff_pct < DIVERGENCE_THRESHOLD

    return {
        "table": f"{table_cfg['oracle_schema']}.{table_cfg['oracle_table']}",
        "status": "OK" if bq_ok and alloydb_ok else "DIVERGED",
        "counts": {
            "oracle": oracle_count,
            "bigquery": bq_count,
            "alloydb": alloydb_count,
        },
        "divergence_pct": {
            "bigquery": round(bq_diff_pct * 100, 4),
            "alloydb": round(alloydb_diff_pct * 100, 4),
        },
        "sinks_ok": {"bigquery": bq_ok, "alloydb": alloydb_ok},
    }


@app.route("/reconcile", methods=["POST"])
def reconcile():
    started_at = datetime.now(timezone.utc)
    results = [_reconcile_table(t) for t in TABLES]

    diverged = [r for r in results if r["status"] != "OK"]
    overall_status = "OK" if not diverged else "DIVERGED"

    summary = {
        "started_at": started_at.isoformat(),
        "completed_at": datetime.now(timezone.utc).isoformat(),
        "overall_status": overall_status,
        "tables_total": len(results),
        "tables_diverged": len(diverged),
        "results": results,
    }

    log_event = "RECONCILIATION_DIVERGENCE" if diverged else "RECONCILIATION_OK"
    log_fn = LOGGER.error if diverged else LOGGER.info
    log_fn(json.dumps({"event_type": log_event, **summary}))

    return jsonify(summary), 200 if overall_status == "OK" else 207


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
