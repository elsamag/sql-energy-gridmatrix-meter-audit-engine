-- ============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Lead Technical Consultant: Samuel Chinwendu Agu
-- Repository Target: https://github.com/Elsamag/sql-energy-gridmatrix-meter-audit-engine
-- Client Entity: GridMatrix Systems
-- Production Artifact: src/03_orphan_anomaly_detection_pipeline.sql
-- Dialect: Google Cloud BigQuery Standard SQL
-- Description: Automated orphan telemetry anomaly detection pipeline isolating
--              unlinked utility meters, quantifying unbilled kWh exposure, and
--              generating prioritized technician dispatch triage queues.
-- ============================================================================

WITH telemetry_stream AS (
  SELECT
    meter_id,
    grid_node_id,
    reading_kwh,
    reading_timestamp,
    voltage_level,
    firmware_version,
    DATE(reading_timestamp) AS reading_date
  FROM
    `gridmatrix_energy.smart_telemetry_partitioned`
  WHERE
    _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))
    AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
),

billing_master AS (
  SELECT
    account_id,
    meter_id,
    tariff_plan,
    account_status,
    decommission_date,
    TO_HEX(SHA256(LOWER(TRIM(customer_ssn_tax_id)))) AS hashed_customer_id
  FROM
    `gridmatrix_energy.customer_billing_master`
),

orphan_meters AS (
  SELECT
    t.meter_id,
    t.grid_node_id,
    t.reading_kwh,
    t.reading_timestamp,
    t.reading_date,
    t.voltage_level,
    t.firmware_version,
    b.account_id,
    b.account_status,
    b.decommission_date,
    CASE
      WHEN b.meter_id IS NULL THEN 'UNREGISTERED_HARDWARE_ORPHAN'
      WHEN b.account_status = 'TERMINATED' AND t.reading_timestamp > b.decommission_date THEN 'POST_DECOMMISSION_DRAIN'
      WHEN b.account_status = 'SUSPENDED' THEN 'UNAUTHORIZED_SUSPENDED_DRAW'
      ELSE 'UNKNOWN_INTEGRITY_FAULT'
    END AS anomaly_classification
  FROM
    telemetry_stream t
  LEFT JOIN
    billing_master b
    ON t.meter_id = b.meter_id
  WHERE
    b.account_id IS NULL
    OR b.account_status IN ('TERMINATED', 'SUSPENDED')
),

aggregated_anomalies AS (
  SELECT
    meter_id,
    grid_node_id,
    anomaly_classification,
    COUNT(1) AS total_orphan_pings,
    MIN(reading_timestamp) AS first_anomaly_detected_at,
    MAX(reading_timestamp) AS last_anomaly_detected_at,
    ROUND(SUM(reading_kwh), 2) AS total_unbilled_kwh,
    ROUND(AVG(reading_kwh), 2) AS avg_draw_per_interval_kwh,
    ROUND(MAX(reading_kwh), 2) AS peak_spike_kwh,
    -- Default baseline commercial grid tariff for liability estimation ($0.165/kWh)
    ROUND(SUM(reading_kwh) * 0.165, 2) AS estimated_unbilled_liability_usd
  FROM
    orphan_meters
  GROUP BY
    meter_id,
    grid_node_id,
    anomaly_classification
)

SELECT
  meter_id,
  grid_node_id,
  anomaly_classification,
  total_orphan_pings,
  first_anomaly_detected_at,
  last_anomaly_detected_at,
  total_unbilled_kwh,
  avg_draw_per_interval_kwh,
  peak_spike_kwh,
  estimated_unbilled_liability_usd,
  CASE
    WHEN estimated_unbilled_liability_usd >= 1000.00 OR peak_spike_kwh >= 50.00 THEN 'P1_CRITICAL_DISPATCH'
    WHEN estimated_unbilled_liability_usd >= 250.00 THEN 'P2_ELEVATED_AUDIT'
    ELSE 'P3_STANDARD_RECONCILIATION'
  END AS dispatch_priority_tier
FROM
  aggregated_anomalies
ORDER BY
  estimated_unbilled_liability_usd DESC,
  total_orphan_pings DESC;
