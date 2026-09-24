-- ============================================================
-- 1. Load + standardise both source systems (DuckDB, runs locally)
--    Output: clean.totara, clean.harbourside, clean.records (both banks), clean.phones
-- ============================================================

CREATE SCHEMA IF NOT EXISTS clean;

-- all_varchar keeps leading zeros in CUST_NO and postcodes such as 0622
CREATE OR REPLACE TABLE clean.raw_totara AS
SELECT * FROM read_csv('totara_mutual_customers.csv', header = true, all_varchar = true);

CREATE OR REPLACE TABLE clean.raw_harbourside AS
SELECT * FROM read_csv('harbourside_bank_customers.csv', header = true, all_varchar = true);


-- Street suffix standardisation: Harbourside spells them out, Totara abbreviates
CREATE OR REPLACE MACRO clean.norm_street(s) AS
    NULLIF(TRIM(
        regexp_replace(
        regexp_replace(
        regexp_replace(
        regexp_replace(
        regexp_replace(
        regexp_replace(
        regexp_replace(
        regexp_replace(
            -- "unit 6, 128 seaview terrace" -> "6/128 seaview terrace"
            regexp_replace(lower(strip_accents(s)), '^unit\s+(\d+),?\s*', '\1/'),
        '\bcrescent\b', 'cres', 'g'),
        '\bterrace\b',  'tce',  'g'),
        '\bavenue\b',   'ave',  'g'),
        '\broad\b',     'rd',   'g'),
        '\bstreet\b',   'st',   'g'),
        '\bdrive\b',    'dr',   'g'),
        '\bplace\b',    'pl',   'g'),
        '\s+', ' ', 'g')
    ), '');

-- Business names: lower case, no accents (Kōwhai), no punctuation, no legal suffix
CREATE OR REPLACE MACRO clean.norm_business(s) AS
    NULLIF(TRIM(
        regexp_replace(
        regexp_replace(
        regexp_replace(lower(strip_accents(s)), '[^a-z0-9 ]', ' ', 'g'),
        '\b(limited|ltd)\b', ' ', 'g'),
        '\s+', ' ', 'g')
    ), '');

-- Phones: digits only, +64 -> 0 national format, empty -> NULL
CREATE OR REPLACE MACRO clean.norm_phone(s) AS
    NULLIF(regexp_replace(regexp_replace(s, '[^0-9]', '', 'g'), '^64', '0'), '');

CREATE OR REPLACE MACRO clean.digits(s) AS
    NULLIF(regexp_replace(s, '[^0-9]', '', 'g'), '');


CREATE OR REPLACE TABLE clean.totara AS
SELECT
    CUST_NO                                                  AS customer_id,
    CASE WHEN CLIENT_SEGMENT = 'RETAIL' THEN 'PERSON' ELSE 'BUSINESS' END AS entity_type,
    -- "WHITE, OLIVER K" -> first "oliver", last "white" (initials dropped)
    NULLIF(lower(strip_accents(split_part(TRIM(split_part(FULL_NAME, ',', 2)), ' ', 1))), '') AS first_name,
    NULLIF(lower(strip_accents(TRIM(split_part(FULL_NAME, ',', 1)))), '') AS last_name,
    clean.norm_business(ENTITY_NAME)                         AS business_name,
    NULL::VARCHAR                                            AS trading_name,
    try_strptime(DOB, '%d-%b-%Y')::DATE                      AS dob,
    clean.digits(TAX_ID)                                     AS tax_id,
    clean.digits(NZBN)                                       AS nzbn,
    clean.norm_street(ADDR_1)                                AS street,
    regexp_extract(ADDR_3, '(\d{4})\s*$', 1)                 AS postcode
FROM clean.raw_totara;

CREATE OR REPLACE TABLE clean.harbourside AS
SELECT
    customer_id,
    CASE WHEN customer_type = 'Business' THEN 'BUSINESS' ELSE 'PERSON' END AS entity_type,
    NULLIF(lower(strip_accents(TRIM(first_name))), '')       AS first_name,
    NULLIF(lower(strip_accents(TRIM(last_name))), '')        AS last_name,
    clean.norm_business(business_name)                       AS business_name,
    clean.norm_business(trading_name)                        AS trading_name,
    TRY_CAST(date_of_birth AS DATE)                          AS dob,
    clean.digits(ird_number)                                 AS tax_id,
    clean.digits(nzbn)                                       AS nzbn,
    clean.norm_street(street_address)                        AS street,
    NULLIF(TRIM(postcode), '')                               AS postcode
FROM clean.raw_harbourside;

-- One row per (customer, phone number) so any shared number counts as a match
CREATE OR REPLACE TABLE clean.phones AS
SELECT DISTINCT bank, customer_id, phone
FROM (
    SELECT 'T' AS bank, CUST_NO AS customer_id, clean.norm_phone(CONTACT_PH_1) AS phone FROM clean.raw_totara
    UNION ALL
    SELECT 'T', CUST_NO, clean.norm_phone(CONTACT_PH_2) FROM clean.raw_totara
    UNION ALL
    SELECT 'H', customer_id, clean.norm_phone(mobile_phone) FROM clean.raw_harbourside
    UNION ALL
    SELECT 'H', customer_id, clean.norm_phone(landline_phone) FROM clean.raw_harbourside
)
WHERE phone IS NOT NULL;

-- Both banks in one table, so the same scoring covers cross-bank pairs and duplicate
-- records inside one bank
CREATE OR REPLACE TABLE clean.records AS
SELECT 'T:' || customer_id AS record_id, 'T' AS bank, * FROM clean.totara
UNION ALL BY NAME
SELECT 'H:' || customer_id AS record_id, 'H' AS bank, * FROM clean.harbourside;
