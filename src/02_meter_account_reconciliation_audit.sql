-- ============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Lead Technical Consultant: Samuel Chinwendu Agu
-- Repository Target: https://github.com/Elsamag/sql-energy-gridmatrix-meter-audit-engine
-- Client Entity: GridMatrix Systems
-- File Path: src/02_meter_account_reconciliation_audit.sql
-- Dialect: Google Cloud BigQuery Standard SQL
-- Description: High-throughput relational reconciliation engine detecting orphan
--              telemetry feeds and synchronizing meter-to-account billing states.
-- ============================================================================

WITH raw_telemetry AS (
  SELECT
    meter_id,
    grid_node_id,
    reading_kwh,
    reading_timestamp,
    DATE(reading_timestamp) AS reading_date
  FROM
    `gridmatrix_energy.smart_telemetry_partitioned`
  WHERE
    _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))
    AND FORMAT_DATE('%Y%m%d', CURRENT_DATE())
),

customer_accounts AS (
  SELECT
    account_id,
    meter_id,
    tariff_plan,
    account_status,
    TO_HEX(SHA256(LOWER(TRIM(customer_ssn_tax_id)))) AS hashed_customer_id
  FROM
    `gridmatrix_energy.customer_billing_master`
  WHERE
    account_status = 'ACTIVE'
),

reconciled_audit AS (
  SELECT
    t.meter_id,
    t.grid_node_id,
    a.account_id,
    a.hashed_customer_id,
    t.reading_kwh,
    t.reading_timestamp,
    CASE
      WHEN a.account_id IS NULL THEN 'ORPHAN_METER_UNLINKED'
      ELSE 'VERIFIED_ACTIVE_BILLING'
    END AS audit_status
  FROM
    raw_telemetry t
  LEFT JOIN
    customer_accounts a
    ON t.meter_id = a.meter_id
)

SELECT
  audit_status,
  grid_node_id,
  COUNT(DISTINCT meter_id) AS total_meters_audited,
  ROUND(SUM(reading_kwh), 2) AS total_aggregated_kwh,
  ROUND(AVG(reading_kwh), 2) AS avg_reading_kwh
FROM
  reconciled_audit
GROUP BY
  audit_status,
  grid_node_id
ORDER BY
  audit_status DESC,
  total_aggregated_kwh DESC;
