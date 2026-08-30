-- ============================================================================
-- Enterprise Practice: Elsamag IT Solutions
-- Author & Lead Technical Consultant: Samuel Chinwendu Agu
-- Repository Target: https://github.com/Elsamag/sql-energy-gridmatrix-meter-audit-engine
-- File: src/04_sha256_pii_sanitization_layer.sql
-- Client Entity: GridMatrix Systems
-- Dialect: Google Cloud BigQuery Standard SQL
-- Description: Deterministic cryptographic SHA-256 identity sanitization layer.
--              Enforces zero raw PII exposure across customer billing records,
--              normalizes identifiers (whitespace trimming + case folding),
--              and provides pseudonymized staging views for audit reconciliation.
-- ============================================================================

CREATE OR REPLACE VIEW `gridmatrix_energy.v_sanitized_customer_billing` AS
WITH raw_customer_billing AS (
  SELECT
    account_id,
    meter_id,
    customer_ssn_tax_id,
    customer_email,
    customer_phone_number,
    tariff_plan,
    account_status,
    billing_cycle_day,
    created_at,
    updated_at
  FROM
    `gridmatrix_energy.customer_billing_master`
),

sanitized_layer AS (
  SELECT
    account_id,
    meter_id,
    tariff_plan,
    account_status,
    billing_cycle_day,
    
    -- Deterministic SHA-256 Tokenization for National/Tax Identifiers
    TO_HEX(
      SHA256(
        LOWER(TRIM(COALESCE(customer_ssn_tax_id, 'UNKNOWN_TAX_ID')))
      )
    ) AS hashed_customer_id,

    -- Cryptographic Pseudonymization for Contact Email
    TO_HEX(
      SHA256(
        LOWER(TRIM(COALESCE(customer_email, 'no-email-provided@gridmatrix.local')))
      )
    ) AS hashed_contact_email,

    -- Masked Phone Number (Retains Last 4 Digits for Verification, Hashes Full String)
    CONCAT(
      '***-***-', 
      RIGHT(REGEXP_REPLACE(customer_phone_number, r'\D', ''), 4)
    ) AS masked_phone_suffix,
    
    TO_HEX(
      SHA256(
        REGEXP_REPLACE(customer_phone_number, r'\D', '')
      )
    ) AS hashed_phone_token,

    -- Audit Metadata & Timestamp
    CURRENT_TIMESTAMP() AS sanitization_applied_at,
    created_at,
    updated_at
  FROM
    raw_customer_billing
)

SELECT
  account_id,
  meter_id,
  tariff_plan,
  account_status,
  billing_cycle_day,
  hashed_customer_id,
  hashed_contact_email,
  masked_phone_suffix,
  hashed_phone_token,
  sanitization_applied_at,
  created_at,
  updated_at
FROM
  sanitized_layer;
