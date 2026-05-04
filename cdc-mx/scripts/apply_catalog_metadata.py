#!/usr/bin/env python3
"""
Post-deploy: aplica aspect types y policy tags a las tablas BigQuery
que Datastream crea automáticamente después del primer ingest.

Este script DEBE ejecutarse:
  1. Después del primer apply de Terraform
  2. Después de que Datastream haya hecho al menos un backfill (las
     tablas analytics.APP_SCHEMA_* deben existir en BQ)

Idempotente: re-ejecutarlo sobrescribe metadata existente con el estado
declarado aquí.

Uso:
    python apply_catalog_metadata.py \\
        --project-id mi-proyecto \\
        --region northamerica-south1 \\
        --bq-dataset analytics

Nota: las APIs de aspects en Knowledge Catalog usan REST porque no hay
recurso Terraform nativo todavía para entries+aspects en BigQuery.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from typing import Any

import google.auth
import google.auth.transport.requests
from google.cloud import bigquery

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
LOGGER = logging.getLogger(__name__)


# =============================================================================
# Mapeo: por cada tabla, qué aspect types y policy tags aplicar a qué columnas
#
# Mantén esto alineado con:
#   - terraform/modules/catalog/main.tf (aspect types y policy tags)
#   - terraform/envs/prod/variables.tf (cdc_tables)
#   - oracle/setup.sql (qué columnas existen)
# =============================================================================
TABLE_METADATA = {
    "APP_SCHEMA_CUSTOMERS": {
        "aspects": {
            "lfpdppp-pii-classification": {
                "sensitivity_level": "RESTRICTED",
                "pii_category": "NAME",
                "is_sensitive_lfpdppp": False,
                "data_steward": "data-governance@miempresa.mx",
            },
            "lfpdppp-legal-basis": {
                "basis_type": "CONSENT_EXPRESS",
                "legal_reference": "Art. 8 LFPDPPP",
                "withdrawal_mechanism_url": "https://miempresa.mx/privacidad/retiro",
            },
            "lfpdppp-purpose": {
                "primary_purpose": "Gestión de relación comercial con clientes",
                "category": "NECESSARY",
                "privacy_notice_url": "https://miempresa.mx/aviso-privacidad",
                "privacy_notice_version": "v3.2-2025",
            },
            "lfpdppp-retention": {
                "retention_days": 1825,
                "retention_basis": "LEGAL_OBLIGATION",
                "deletion_method": "anonymization_with_block",
            },
        },
        "column_policy_tags": {
            "EMAIL":         "pii-medium",
            "PHONE":         "pii-medium",
            "FIRST_NAME":    "pii-medium",
            "LAST_NAME":     "pii-medium",
            # COUNTRY_CODE no es PII por sí solo
        },
        "column_descriptions": {
            "EMAIL":      "Correo del cliente. PII categoría email. LFPDPPP.",
            "PHONE":      "Teléfono del cliente. PII categoría phone. LFPDPPP.",
            "FIRST_NAME": "Nombre del cliente. PII categoría name. LFPDPPP.",
            "LAST_NAME":  "Apellido del cliente. PII categoría name. LFPDPPP.",
        },
    },
    "APP_SCHEMA_ORDERS": {
        "aspects": {
            "lfpdppp-pii-classification": {
                "sensitivity_level": "CONFIDENTIAL",
                "pii_category": "FINANCIAL",
                "is_sensitive_lfpdppp": True,
                "data_steward": "data-governance@miempresa.mx",
            },
            "lfpdppp-legal-basis": {
                "basis_type": "CONTRACT_EXECUTION",
                "legal_reference": "Art. 8 fracción II LFPDPPP",
            },
            "lfpdppp-purpose": {
                "primary_purpose": "Procesamiento de pedidos y facturación",
                "category": "NECESSARY",
                "privacy_notice_version": "v3.2-2025",
            },
            "lfpdppp-retention": {
                "retention_days": 1825,
                "retention_basis": "LEGAL_OBLIGATION",
                "deletion_method": "block_per_cff_30",
            },
        },
        "column_policy_tags": {
            "TOTAL_AMOUNT": "pii-medium",
        },
        "column_descriptions": {
            "TOTAL_AMOUNT": "Monto total del pedido. Información financiera del titular.",
        },
    },
    "APP_SCHEMA_ORDER_ITEMS": {
        "aspects": {
            "lfpdppp-pii-classification": {
                "sensitivity_level": "INTERNAL",
                "pii_category": "NONE",
                "is_sensitive_lfpdppp": False,
                "data_steward": "data-governance@miempresa.mx",
            },
            "lfpdppp-purpose": {
                "primary_purpose": "Detalle de pedidos para facturación",
                "category": "NECESSARY",
                "privacy_notice_version": "v3.2-2025",
            },
            "lfpdppp-retention": {
                "retention_days": 1825,
                "retention_basis": "LEGAL_OBLIGATION",
                "deletion_method": "block_per_cff_30",
            },
        },
        "column_policy_tags": {},
        "column_descriptions": {},
    },
}


# =============================================================================
# Helpers
# =============================================================================
def get_access_token() -> str:
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    auth_req = google.auth.transport.requests.Request()
    creds.refresh(auth_req)
    return creds.token


def get_policy_tag_id(
    bq_client: bigquery.Client,
    project_id: str,
    region: str,
    prefix: str,
    tag_display_name: str,
) -> str | None:
    """Resuelve display_name → policy tag fully-qualified ID."""
    import requests

    token = get_access_token()
    list_taxonomies = (
        f"https://datacatalog.googleapis.com/v1/projects/{project_id}/"
        f"locations/{region}/taxonomies"
    )
    resp = requests.get(
        list_taxonomies,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    resp.raise_for_status()
    taxonomies = resp.json().get("taxonomies", [])

    target_taxonomy = next(
        (t for t in taxonomies
         if t.get("displayName") == f"{prefix}-pii-taxonomy"),
        None,
    )
    if not target_taxonomy:
        LOGGER.warning("Taxonomy %s-pii-taxonomy no encontrada", prefix)
        return None

    list_tags = (
        f"https://datacatalog.googleapis.com/v1/{target_taxonomy['name']}"
        f"/policyTags"
    )
    resp = requests.get(
        list_tags,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    resp.raise_for_status()
    tags = resp.json().get("policyTags", [])

    for tag in tags:
        if tag.get("displayName") == tag_display_name:
            return tag["name"]

    LOGGER.warning("Policy tag %s no encontrado", tag_display_name)
    return None


def apply_policy_tags_and_descriptions(
    bq_client: bigquery.Client,
    project_id: str,
    region: str,
    prefix: str,
    bq_dataset: str,
    table_name: str,
    column_policy_tags: dict[str, str],
    column_descriptions: dict[str, str],
) -> None:
    """Aplica policy tags y descripciones a las columnas via ALTER TABLE."""
    table_ref = bigquery.TableReference.from_string(
        f"{project_id}.{bq_dataset}.{table_name}"
    )
    try:
        table = bq_client.get_table(table_ref)
    except Exception as e:
        LOGGER.warning("Tabla %s no existe aún (%s). "
                       "Asegúrate de que Datastream haya hecho backfill.",
                       table_name, e)
        return

    new_schema = []
    changed = 0

    for field in table.schema:
        new_description = column_descriptions.get(
            field.name, field.description
        )
        new_policy_tags = field.policy_tags

        if field.name in column_policy_tags:
            tag_id = get_policy_tag_id(
                bq_client, project_id, region, prefix,
                column_policy_tags[field.name],
            )
            if tag_id:
                new_policy_tags = bigquery.PolicyTagList(names=[tag_id])
                changed += 1

        new_schema.append(bigquery.SchemaField(
            name=field.name,
            field_type=field.field_type,
            mode=field.mode,
            description=new_description,
            policy_tags=new_policy_tags,
        ))

    table.schema = new_schema
    bq_client.update_table(table, ["schema"])
    LOGGER.info("Tabla %s: %d columnas con policy tags actualizadas",
                table_name, changed)


def apply_aspects_to_bq_table(
    project_id: str,
    region: str,
    bq_dataset: str,
    table_name: str,
    aspects: dict[str, dict],
) -> None:
    """
    Aplica aspect types al entry de BigQuery via Dataplex Catalog REST API.

    Los entries de BQ los crea Knowledge Catalog automáticamente
    (entry_group = '@bigquery'). Aquí solo asignamos aspects.
    """
    import requests

    token = get_access_token()

    entry_name = (
        f"projects/{project_id}/locations/{region}/"
        f"entryGroups/@bigquery/entries/"
        f"bigquery.googleapis.com%2Fprojects%2F{project_id}%2F"
        f"datasets%2F{bq_dataset}%2Ftables%2F{table_name}"
    )

    aspects_payload = {}
    for aspect_type, data in aspects.items():
        aspect_key = (
            f"{project_id}.global.{aspect_type}"
        )
        aspects_payload[aspect_key] = {
            "data": data,
        }

    body = {
        "name": entry_name,
        "aspects": aspects_payload,
    }
    update_mask = ",".join(f"aspects.\"{k}\"" for k in aspects_payload.keys())

    url = (
        f"https://dataplex.googleapis.com/v1/{entry_name}"
        f"?updateMask={update_mask}"
    )

    resp = requests.patch(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=30,
    )

    if resp.status_code in (200, 201):
        LOGGER.info("Aspects aplicados a %s: %s",
                    table_name, list(aspects.keys()))
    elif resp.status_code == 404:
        LOGGER.warning("Entry %s no existe aún. Knowledge Catalog "
                       "necesita ~5 min después de crear la tabla.",
                       table_name)
    else:
        LOGGER.error("Error aplicando aspects a %s: HTTP %d %s",
                     table_name, resp.status_code, resp.text[:500])


# =============================================================================
# Main
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description="Aplica metadata de Knowledge Catalog post-deploy"
    )
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--region", default="northamerica-south1")
    parser.add_argument("--prefix", default="cdc-mx")
    parser.add_argument("--bq-dataset", default="analytics")
    parser.add_argument("--skip-aspects", action="store_true",
                       help="Skip aspect application (only policy tags)")
    parser.add_argument("--skip-policy-tags", action="store_true",
                       help="Skip policy tag application (only aspects)")
    args = parser.parse_args()

    bq_client = bigquery.Client(project=args.project_id)
    errors = 0

    for table_name, metadata in TABLE_METADATA.items():
        LOGGER.info("=" * 60)
        LOGGER.info("Procesando tabla: %s", table_name)

        # 1. Policy tags y descripciones de columnas
        if not args.skip_policy_tags:
            try:
                apply_policy_tags_and_descriptions(
                    bq_client=bq_client,
                    project_id=args.project_id,
                    region=args.region,
                    prefix=args.prefix,
                    bq_dataset=args.bq_dataset,
                    table_name=table_name,
                    column_policy_tags=metadata.get("column_policy_tags", {}),
                    column_descriptions=metadata.get("column_descriptions", {}),
                )
            except Exception as e:
                LOGGER.exception("Error aplicando policy tags a %s: %s",
                                table_name, e)
                errors += 1

        # 2. Aspects en el entry de BigQuery
        if not args.skip_aspects:
            try:
                apply_aspects_to_bq_table(
                    project_id=args.project_id,
                    region=args.region,
                    bq_dataset=args.bq_dataset,
                    table_name=table_name,
                    aspects=metadata.get("aspects", {}),
                )
            except Exception as e:
                LOGGER.exception("Error aplicando aspects a %s: %s",
                                table_name, e)
                errors += 1

    LOGGER.info("=" * 60)
    if errors == 0:
        LOGGER.info("Metadata aplicada correctamente a %d tablas",
                    len(TABLE_METADATA))
        sys.exit(0)
    else:
        LOGGER.error("Hubo %d errores. Revisa los logs.", errors)
        sys.exit(1)


if __name__ == "__main__":
    main()
