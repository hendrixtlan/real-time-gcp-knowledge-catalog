#!/usr/bin/env python3
"""
Dataflow streaming job: serving path Oracle CDC → AlloyDB.

Pipeline:
  1. Lee notificaciones de Pub/Sub (GCS object created por Datastream).
  2. Lee el Avro completo de GCS para cada notificación.
  3. Procesa cada cambio CDC (Insert/Update/Delete).
  4. Aplica upsert idempotente a AlloyDB con SCN guard.
  5. Publica métrica de lag end-to-end.
  6. Mensajes con error van al DLQ.

Diseño:
  - Streaming Engine ON.
  - Triggering frequency 1s para baja latencia.
  - Connection pool por worker (no por bundle).
  - SCN guard previene desorden y duplicados.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import time
from datetime import datetime, timezone
from typing import Iterable

import apache_beam as beam
import fastavro
import psycopg2
import psycopg2.pool
from apache_beam.io.gcp.pubsub import ReadFromPubSub, WriteToPubSub
from apache_beam.options.pipeline_options import (
    PipelineOptions,
    StandardOptions,
    GoogleCloudOptions,
    WorkerOptions,
)
from google.cloud import secretmanager, storage

LOGGER = logging.getLogger(__name__)


# =============================================================================
# Configuración de tablas
# =============================================================================
# Cada entrada describe cómo aplicar el upsert para una tabla CDC.
# El nombre upsert_function debe existir en AlloyDB schema `app`.
TABLE_MAPPINGS = {
    "APP_SCHEMA.CUSTOMERS": {
        "pk_field": "CUSTOMER_ID",
        "upsert_function": "app.upsert_customer",
        "params_order": [
            "CUSTOMER_ID", "EMAIL", "PHONE", "FIRST_NAME", "LAST_NAME",
            "COUNTRY_CODE", "CREATED_AT", "UPDATED_AT",
        ],
    },
    "APP_SCHEMA.ORDERS": {
        "pk_field": "ORDER_ID",
        "upsert_function": "app.upsert_order",
        "params_order": [
            "ORDER_ID", "CUSTOMER_ID", "ORDER_STATUS", "TOTAL_AMOUNT",
            "CURRENCY", "PLACED_AT", "UPDATED_AT",
        ],
    },
    "APP_SCHEMA.ORDER_ITEMS": {
        "pk_field": "ITEM_ID",
        "upsert_function": "app.upsert_order_item",
        "params_order": [
            "ITEM_ID", "ORDER_ID", "PRODUCT_ID", "QUANTITY", "UNIT_PRICE",
        ],
    },
}


# =============================================================================
# Utilidades para leer secretos
# =============================================================================
def get_secret(project_id: str, secret_id: str) -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project_id}/secrets/{secret_id}/versions/latest"
    response = client.access_secret_version(request={"name": name})
    return response.payload.data.decode("UTF-8")


# =============================================================================
# DoFn: parsear notificación GCS de Pub/Sub
# =============================================================================
class ParseGcsNotification(beam.DoFn):
    """Convierte un mensaje Pub/Sub de GCS notification en (bucket, object_name)."""

    def process(self, element: bytes) -> Iterable[dict]:
        try:
            payload = json.loads(element.decode("utf-8"))
            yield {
                "bucket": payload["bucket"],
                "object_name": payload["name"],
                "size": int(payload.get("size", 0)),
                "time_created": payload.get("timeCreated"),
            }
        except (KeyError, ValueError, json.JSONDecodeError) as e:
            LOGGER.exception("Falló parsing de notificación: %s", e)


# =============================================================================
# DoFn: leer Avro de GCS y emitir registros CDC
# =============================================================================
class ReadAvroFromGcs(beam.DoFn):
    """Lee un archivo Avro de Datastream y emite cada registro CDC."""

    def setup(self):
        self.gcs_client = storage.Client()

    def process(self, element: dict) -> Iterable[dict]:
        bucket_name = element["bucket"]
        object_name = element["object_name"]

        # Solo Avro
        if not object_name.endswith(".avro"):
            return

        try:
            bucket = self.gcs_client.bucket(bucket_name)
            blob = bucket.blob(object_name)
            content = blob.download_as_bytes()

            # Parse avro
            from io import BytesIO
            reader = fastavro.reader(BytesIO(content))

            for record in reader:
                # Datastream injecta metadata en _metadata
                metadata = record.get("source_metadata", {})
                payload = record.get("payload", {}) or {}

                table_full = (
                    f"{metadata.get('schema', '')}."
                    f"{metadata.get('table', '')}"
                )

                if table_full not in TABLE_MAPPINGS:
                    continue

                yield {
                    "table": table_full,
                    "op": metadata.get("change_type", "INSERT")[0:1],
                    "scn": int(metadata.get("scn", 0)),
                    "op_ts": metadata.get("source_timestamp"),
                    "payload": payload,
                }
        except Exception as e:
            LOGGER.exception("Falló lectura de Avro %s/%s: %s",
                           bucket_name, object_name, e)


# =============================================================================
# DoFn: aplicar upsert a AlloyDB con connection pool por worker
# =============================================================================
class UpsertToAlloyDB(beam.DoFn):
    """Aplica upsert idempotente. Reintenta en errores transitorios."""

    def __init__(
        self,
        project_id: str,
        conn_secret: str,
        password_secret: str,
        dlq_topic: str,
    ):
        self.project_id = project_id
        self.conn_secret = conn_secret
        self.password_secret = password_secret
        self.dlq_topic = dlq_topic
        self.pool = None

    def setup(self):
        # Pool de conexiones por worker
        conn_string = get_secret(self.project_id, self.conn_secret)
        password = get_secret(self.project_id, self.password_secret)

        self.pool = psycopg2.pool.ThreadedConnectionPool(
            minconn=2,
            maxconn=10,
            dsn=conn_string,
            password=password,
            connect_timeout=10,
        )

    def teardown(self):
        if self.pool:
            self.pool.closeall()

    def _to_iso(self, ts):
        if ts is None:
            return None
        if isinstance(ts, datetime):
            return ts
        # Datastream timestamps vienen como dict {"isoStringRep": "..."} o string
        if isinstance(ts, dict):
            return ts.get("isoStringRep")
        return ts

    def process(self, element: dict) -> Iterable[bytes]:
        table = element["table"]
        mapping = TABLE_MAPPINGS[table]
        op = element["op"]
        scn = element["scn"]
        op_ts = self._to_iso(element["op_ts"])
        payload = element["payload"]

        # Construir parámetros en el orden esperado
        params = []
        for field in mapping["params_order"]:
            value = payload.get(field)
            params.append(self._to_iso(value) if 'AT' in field else value)

        # Agregar SCN, op_ts, op
        params.extend([scn, op_ts, op])

        placeholders = ", ".join(["%s"] * len(params))
        sql = f"SELECT {mapping['upsert_function']}({placeholders})"

        conn = None
        applied = False
        try:
            conn = self.pool.getconn()
            with conn.cursor() as cur:
                cur.execute(sql, tuple(params))
                applied = cur.fetchone()[0]
                conn.commit()

            # Métrica de lag end-to-end
            now = datetime.now(timezone.utc)
            try:
                op_dt = datetime.fromisoformat(op_ts.replace("Z", "+00:00")) \
                    if isinstance(op_ts, str) else op_ts
                lag_ms = int((now - op_dt).total_seconds() * 1000)
                LOGGER.info(json.dumps({
                    "metric": "e2e_lag_ms",
                    "table_name": table,
                    "lag_ms": lag_ms,
                    "scn": scn,
                    "applied": applied,
                }))
            except Exception:
                pass

        except (psycopg2.OperationalError, psycopg2.InterfaceError) as e:
            # Error transitorio: lo reintenta el runner
            LOGGER.warning("Error transitorio: %s", e)
            if conn:
                try:
                    self.pool.putconn(conn, close=True)
                except Exception:
                    pass
                conn = None
            raise

        except Exception as e:
            # Error no recuperable: enviar al DLQ
            LOGGER.exception("Error procesando %s SCN=%s: %s", table, scn, e)
            yield json.dumps({
                "error": str(e),
                "error_type": type(e).__name__,
                "table": table,
                "scn": scn,
                "op": op,
                "payload": str(payload)[:1000],
                "failed_at": datetime.now(timezone.utc).isoformat(),
            }).encode("utf-8")

        finally:
            if conn:
                self.pool.putconn(conn)


# =============================================================================
# Pipeline
# =============================================================================
def run(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--gcs_notifications_subscription", required=True)
    parser.add_argument("--cdc_events_topic", required=True)
    parser.add_argument("--dlq_topic", required=True)
    parser.add_argument("--alloydb_writer_secret", required=True)
    parser.add_argument("--alloydb_password_secret", required=True)
    parser.add_argument("--triggering_frequency_seconds", type=int, default=1)
    parser.add_argument("--upsert_batch_size", type=int, default=100)

    known_args, pipeline_args = parser.parse_known_args(argv)

    pipeline_options = PipelineOptions(pipeline_args)
    pipeline_options.view_as(StandardOptions).streaming = True

    gcp_options = pipeline_options.view_as(GoogleCloudOptions)
    project_id = gcp_options.project

    with beam.Pipeline(options=pipeline_options) as p:
        notifications = (
            p
            | "Read GCS Notifications"
            >> ReadFromPubSub(subscription=known_args.gcs_notifications_subscription)
            | "Parse Notifications" >> beam.ParDo(ParseGcsNotification())
        )

        cdc_records = (
            notifications
            | "Read Avro" >> beam.ParDo(ReadAvroFromGcs())
        )

        # Upsert a AlloyDB; los errores van al DLQ
        dlq_msgs = (
            cdc_records
            | "Upsert to AlloyDB"
            >> beam.ParDo(UpsertToAlloyDB(
                project_id=project_id,
                conn_secret=known_args.alloydb_writer_secret,
                password_secret=known_args.alloydb_password_secret,
                dlq_topic=known_args.dlq_topic,
            ))
        )

        _ = (
            dlq_msgs
            | "Write to DLQ" >> WriteToPubSub(topic=known_args.dlq_topic)
        )


if __name__ == "__main__":
    logging.getLogger().setLevel(logging.INFO)
    run()
