-- ============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Lead Technical Consultant: Samuel Chinwendu Agu
-- Target Repository: https://github.com/Elsamag/sql-energy-gridmatrix-meter-audit-engine
-- Client Entity: GridMatrix Systems
-- File Target: src/01_raw_telemetry_partition_ingest.sql
-- Dialect: Google Cloud BigQuery Standard SQL
-- Objective: High-throughput ingestion, validation, and partition-pruned staging
--            of smart meter telemetry feeds across distributed grid nodes.
-- ============================================================================

CREATE OR REPLACE TABLE `gridmatrix_energy.staging_telemetry_daily`
PARTITION BY reading_date
CLUSTER BY grid_node_id, meter_id
OPTIONS(
  description = "Partition-pruned, sanitized daily smart meter telemetry ingestion layer.",
  require_partition_filter = TRUE
) AS

WITH source_telemetry AS (
  SELECT
    TRIM(meter_id) AS meter_id,
    TRIM(grid_node_id) AS grid_node_id,
    reading_timestamp,
    DATE(reading_timestamp) AS reading_date,
    CAST(reading_kwh AS NUMERIC) AS reading_kwh,
    CAST(voltage_rms AS NUMERIC) AS voltage_rms,
    status_code,
    ingestion_timestamp
  FROM
    `gridmatrix_energy.smart_telemetry_raw_*`
  WHERE
    -- Date-partition boundary pruning: Restrict scan window to target trailing interval
    _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))
    AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
),

validated_readings AS (
  SELECT
    meter_id,
    grid_node_id,
    reading_timestamp,
    reading_date,
    reading_kwh,
    voltage_rms,
    status_code,
    ingestion_timestamp,
    -- Deterministic deduplication: retain latest ingestion packet per meter timestamp
    ROW_NUMBER() OVER (
      PARTITION BY meter_id, reading_timestamp
      ORDER BY ingestion_timestamp DESC
    ) AS dedupe_rank
  FROM
    source_telemetry
  WHERE
    meter_id IS NOT NULL
    AND reading_timestamp IS NOT NULL
    -- Filter erroneous negative power draws and telemetry sensor spikes
    AND reading_kwh >= 0
    AND voltage_rms BETWEEN 80.0 AND 300.0
)

SELECT
  meter_id,
  grid_node_id,
  reading_timestamp,
  reading_date,
  reading_kwh,
  voltage_rms,
  status_code,
  ingestion_timestamp,
  CURRENT_TIMESTAMP() AS audit_loaded_at
FROM
  validated_readings
WHERE
  dedupe_rank = 1;
