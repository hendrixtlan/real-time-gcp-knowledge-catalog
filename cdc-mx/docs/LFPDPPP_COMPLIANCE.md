# Cumplimiento LFPDPPP 2025 — mapeo a controles técnicos

> Última reforma considerada: 14 de noviembre de 2025.
> Autoridad: Secretaría Anticorrupción y Buen Gobierno.

## Resumen ejecutivo

Este stack cubre los controles **técnicos** exigidos por la Nueva LFPDPPP
2025. La cobertura legal completa requiere también controles
administrativos y procedimentales que están fuera del alcance de
infraestructura.

| Categoría                              | Cobertura del stack |
|----------------------------------------|---------------------|
| Cifrado, control de acceso, logging    | 100%                |
| Detección de PII (incluyendo MX)       | 100%                |
| Derechos ARCO (Art. 22)                | 100% técnico        |
| Notificación de brechas (Art. 20)      | 80% (falta CRM)     |
| Aviso de privacidad                    | 0% (legal)          |
| Contratos con encargados externos      | 0% (legal)          |
| PIA / análisis de riesgo               | 0% (proceso)        |

## Mapeo por artículo

### Art. 5 — Principios

| Principio       | Control técnico                                                     |
|-----------------|---------------------------------------------------------------------|
| Licitud         | Aspect type `lfpdppp-legal-basis` por dataset                        |
| Finalidad       | Aspect type `lfpdppp-purpose`, distingue necesaria vs secundaria     |
| Lealtad         | Aviso de privacidad publicado (legal, fuera del stack)               |
| Consentimiento  | Tabla `consent_log` en AlloyDB, registro inmutable con timestamp     |
| Calidad         | DataScans con DQ rules (uniqueness, completeness, freshness, validity)|
| Proporcionalidad| Column-level masking + exclude lists en Datastream                   |
| Información     | Glosario Knowledge Catalog + URL del aviso en aspect type            |
| Responsabilidad | Audit logs Data Access + lineage + reconciliación periódica          |

### Art. 8 — Consentimiento

> "El consentimiento debe ser libre, específico e informado.
> Como regla general, el consentimiento tácito será válido."

**Control:** tabla `consent_log` en AlloyDB:

```sql
CREATE TABLE consent_log (
    consent_id BIGSERIAL PRIMARY KEY,
    titular_id VARCHAR(64) NOT NULL,
    purpose VARCHAR(100) NOT NULL,
    consent_type VARCHAR(20) NOT NULL CHECK (
        consent_type IN ('EXPRESS', 'TACIT', 'WITHDRAWN')
    ),
    privacy_notice_version VARCHAR(20) NOT NULL,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    withdrawn_at TIMESTAMPTZ,
    ip_address INET,
    user_agent TEXT
);
```

Cada finalidad declarada en el aviso requiere su propio registro de
consentimiento. La modificación del aviso (cambio de `privacy_notice_version`)
puede invalidar consentimientos existentes según la nueva ley.

### Art. 11 — Calidad y temporalidad

> "Los datos deben ser tratados sólo durante el tiempo necesario
> para cumplir con su finalidad."

**Control:** retención configurada en cada layer:

- **GCS landing (Datastream):** 7 días vía lifecycle rule
- **Pub/Sub:** 7 días `message_retention_duration` máximo
- **BigQuery:** `partition_expiration_days` por tabla, default 1825 días (5
  años, alineado con CFF Art. 30 para evidencia fiscal)
- **AlloyDB:** purga programada vía pg_cron (`alloydb/03_purge_jobs.sql`)
- **Audit logs archive:** 5 años, bucket GCS con retention policy

**Aspect type:** `lfpdppp-retention` documenta retention_days y
retention_basis (legal/contractual/business) por tabla.

**Validación continua de calidad:** DataScans de Knowledge Catalog se
ejecutan diariamente sobre cada tabla CDC en BigQuery con reglas de:

- Unicidad de la primary key (detecta CDC roto que duplica filas)
- Non-null en columnas críticas
- Profiling semanal (detecta nuevas columnas con apariencia de PII)

Los resultados se publican al topic `metadata-changes` para gobernanza
event-driven.

### Art. 14 — Confidencialidad

> "El responsable y terceros deben implementar controles para que
> todas las personas que intervengan en el tratamiento guarden la
> confidencialidad, incluso después de terminada la relación."

**Controles:**

- **CMEK con Cloud KMS:** revocar la key invalida el acceso a datos
  cifrados, incluso si Google retiene copias internas.
- **IAM con least privilege:** cuatro service accounts dedicados
  (datastream, dataflow, arco, reconciliation), cada uno con permisos
  mínimos para su tarea.
- **VPC privado:** AlloyDB con private IP, Cloud Run con ingress interno,
  Dataflow workers sin IP pública.
- **Audit logs:** evidencia de quién accedió, cuándo y a qué.

### Art. 16 — Aviso de privacidad

> "Debe contener el catálogo de datos personales que serán tratados,
> identificando los sensibles, finalidades necesarias y voluntarias."

**Control:** los aspect types `lfpdppp-purpose` y `pii-classification`
documentan en Knowledge Catalog las finalidades y categorías PII por
tabla/columna. El glosario de negocio incluye 7 términos LFPDPPP
estándar (titular, datos personales, datos sensibles, consentimiento,
ARCO, responsable, encargado) referenciables desde cualquier entry.

Esta documentación alimenta el aviso de privacidad (redactado por legal)
pero no lo sustituye.

### Art. 19 — Medidas de seguridad

> "Medidas administrativas, técnicas y físicas adecuadas que permitan
> proteger los datos personales contra daño, pérdida, alteración,
> destrucción o uso, acceso o tratamiento no autorizado."

**Controles técnicos:**

- Cifrado en reposo: CMEK obligatorio
- Cifrado en tránsito: TLS 1.3, IP privada para AlloyDB
- Control de acceso: column-level con policy tags, row-level security
  para datos de un titular específico
- Detección de incidentes: Cloud Monitoring con alertas de acceso anómalo
- Backups: AlloyDB automated backups + continuous backup, BQ time-travel
- Aislamiento de red: VPC dedicada, sin peering a redes externas

### Art. 20 — Notificación de vulneraciones

> "El responsable deberá informar al titular las vulneraciones de
> seguridad ocurridas que afecten de forma significativa sus derechos
> patrimoniales o morales, en cuanto se confirme y a fin de que
> el titular pueda tomar las medidas correspondientes."

**Plazo:** la ley dice "en cuanto se confirme". Práctica de la industria
es 72h alineado con GDPR. La interpretación de "inmediato" no está fijada
por la Secretaría aún.

**Controles:**

- Topic Pub/Sub `lfpdppp-data-breach-events` con CMEK
- Endpoint `/arco/breach-notify` registra incidente y publica al topic
- Service Cloud Run `breach-response` consume y dispara playbook
- Alertas de Cloud Monitoring para acceso anómalo (>1000 reads PII en
  5 min) que disparan investigación

**Limitación:** la notificación efectiva al titular (email, SMS, postal)
requiere integración con CRM/marketing automation. El stack publica el
evento; la entrega es responsabilidad de IR + CRM.

### Art. 22 — Derechos ARCO

> "El titular tiene derecho a acceder, rectificar, cancelar u oponerse
> al tratamiento. La respuesta debe darse en un plazo máximo de
> 20 días naturales y, si procede, ejecutarse en 15 días adicionales."

**Control:** servicio Cloud Run `services/arco/` con cuatro endpoints:

| Endpoint                 | Derecho        | Acción técnica                              |
|--------------------------|----------------|--------------------------------------------|
| `POST /arco/access`      | Acceso         | Export de datos del titular a GCS signed URL|
| `POST /arco/rectification`| Rectificación  | Update en Oracle (source of truth) o AlloyDB|
| `POST /arco/cancellation`| Cancelación    | Anonimización con bloqueo si hay retención legal|
| `POST /arco/objection`   | Oposición      | Withdraw en consent_log para finalidades secundarias|

**SLA tracking:**

- Tabla `arco_requests` con `deadline_resolution = NOW() + 20 days`
  calculado al inserción
- Vista `v_arco_at_risk` lista solicitudes a < 3 días de vencer
- Cloud Scheduler corre `/arco/sla-check` cada 4h, log severity ERROR si
  hay solicitud a < 24h

**Caso especial — Cancelación con retención legal (Art. 27):**

CFF Art. 30 obliga retener registros contables 5 años. Si un titular
solicita cancelación pero tiene operaciones recientes:

1. Anonimizar campos PII puros (nombre, email, teléfono)
2. Mantener registros financieros con `customer_id` anonimizado
3. Resolver con `resolution = 'PARTIAL'`
4. Reason: "Anonymized; orders retained per CFF Art. 30"

Esto no es violación — el Art. 27 LFPDPPP permite **bloquear** en lugar
de cancelar cuando hay obligación legal contraria.

### Art. 27 — Bloqueo

> "El responsable podrá negar el acceso, cancelación u oposición cuando
> exista una obligación legal del responsable de conservar los datos."

**Control:** la lógica del endpoint `/arco/cancellation` detecta
automáticamente obligaciones de retención y aplica anonimización en lugar
de delete duro. Documentado en `deletion_log` para evidencia.

### Art. 36 — Transferencias

La nueva ley elimina la obligación de informar transferencias en el aviso
de privacidad, pero mantiene la obligación de garantizar tratamiento
conforme a la ley.

**Controles:**

- Documentar qué servicios GCP actúan como encargados (ver
  `LFPDPPP_COMPLIANCE.md` § Encargados)
- Google Cloud DPA aplica automáticamente
- Para transferencias a servicios externos a GCP, contratos individuales

### Art. 75-77 — Sanciones

| Infracción                          | Multa (UMA)        | Equivalente USD aprox |
|-------------------------------------|--------------------|-----------------------|
| Violaciones leves                    | 100 a 160,000      | $565 - $905,120       |
| Violaciones graves                   | 200 a 320,000      | $1,131 - $1,810,240   |
| Si afecta datos sensibles            | × 2                | hasta $3.6M           |

**Nota:** la sanción es por infracción individual, no agregada. Una brecha
que afecta a 10,000 titulares puede traducirse en sanciones acumuladas.

## Datos sensibles (Art. 3 fracción VI)

Categorías especiales que duplican multas:

- Origen racial o étnico
- Estado de salud presente o futuro
- Información genética
- Creencias religiosas
- Opiniones políticas
- Preferencia sexual
- Datos biométricos
- Información financiera

**Detección automática vía DLP:**

InfoTypes custom mexicanos en `terraform/modules/catalog/`:

- `MX_CURP` — Clave Única de Registro de Población
- `MX_RFC_FISICA` / `MX_RFC_MORAL` — Registro Federal de Contribuyentes
- `MX_NSS` — Número de Seguridad Social IMSS
- `MX_CLAVE_ELECTOR` — clave de elector INE/IFE
- `MX_CLABE` — CLABE interbancaria

Más InfoTypes estándar de Google (email, phone, credit card, etc.).

DLP profiling diario sobre BigQuery con estos InfoTypes detecta PII no
clasificado y dispara reconciliación con aspect types.

## Encargados identificados (Art. 50)

Servicios GCP que actúan como **encargados** sobre los datos personales:

| Servicio              | Rol                            | DPA Google |
|-----------------------|--------------------------------|------------|
| Cloud Datastream      | CDC desde Oracle               | Sí         |
| Cloud Pub/Sub         | Buffer de eventos              | Sí         |
| Cloud Dataflow        | Transformación serving         | Sí         |
| AlloyDB               | Hot tier                       | Sí         |
| BigQuery              | Analítica                      | Sí         |
| Cloud Storage         | Landing intermedio + audit     | Sí         |
| Cloud KMS             | Cifrado                        | Sí         |
| Cloud Run             | ARCO + reconciliation services | Sí         |
| Cloud Logging         | Audit logs                     | Sí         |
| Knowledge Catalog     | Metadatos (no datos personales)| N/A        |

El **responsable** sigue siendo único: tu organización. Google es
encargado del responsable. La cadena se documenta en el aviso de
privacidad simplificado.

## Cumplimiento continuo

Este stack incluye `scripts/compliance_check.py` que valida en CI/CD:

- Todas las tablas BQ con PII tienen `kms_key_name` configurado
- Todas las columnas con PII tienen policy tag asignado
- AlloyDB cluster tiene `encryption_config`
- Audit logs Data Access habilitados
- DLP custom InfoTypes existen
- Tablas `consent_log`, `arco_requests`, `deletion_log` existen
- Servicio ARCO responde en `/health`
- Cloud Scheduler de SLA check activo
- Aspect types LFPDPPP aplicados a datasets relevantes

Falla el deploy si cualquiera de estos checks no pasa.
