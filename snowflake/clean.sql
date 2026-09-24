-- ============================================================
-- 1. Load + standardise both source systems (Snowflake)
--    Input : PUBLIC.TOTARA_MUTUAL_CUSTOMERS, PUBLIC.HARBOURSIDE_BANK_CUSTOMERS
--    Output: clean.totara, clean.harbourside, clean.records (both banks), clean.phones
--    Snowflake version of ../clean.sql; same tables, same rules.
-- ============================================================

USE DATABASE BANK;
CREATE SCHEMA IF NOT EXISTS clean;


-- ---------- helper functions ----------

-- "Kōwhai" -> "Kowhai" (Snowflake has no built-in accent stripping)
CREATE OR REPLACE FUNCTION clean.strip_accents(s VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
RETURNS NULL ON NULL INPUT
IMMUTABLE
AS $$
    return S.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
$$;

-- Edit distance counting a swap of two adjacent characters as one edit, so a transposed
-- tax ID digit pair (109443176 vs 109443716) is distance 1. EDITDISTANCE would give 2.
CREATE OR REPLACE FUNCTION clean.damerau_levenshtein(a VARCHAR, b VARCHAR)
RETURNS FLOAT
LANGUAGE JAVASCRIPT
RETURNS NULL ON NULL INPUT
IMMUTABLE
AS $$
    var d = [];
    for (var i = 0; i <= A.length; i++) { d.push([i]); }
    for (var j = 1; j <= B.length; j++) { d[0][j] = j; }
    for (var i = 1; i <= A.length; i++) {
        for (var j = 1; j <= B.length; j++) {
            var cost = A[i - 1] === B[j - 1] ? 0 : 1;
            d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
            if (i > 1 && j > 1 && A[i - 1] === B[j - 2] && A[i - 2] === B[j - 1]) {
                d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
            }
        }
    }
    return d[A.length][B.length];
$$;

-- Street suffix standardisation: Harbourside spells them out, Totara abbreviates.
-- Snowflake regex has no \b, so a word boundary is written as (^|[^a-z0-9_]) ... ([^a-z0-9_]|$)
CREATE OR REPLACE FUNCTION clean.norm_street(s VARCHAR)
RETURNS VARCHAR
AS $$
    NULLIF(TRIM(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
            -- "unit 6, 128 seaview terrace" -> "6/128 seaview terrace"
            REGEXP_REPLACE(LOWER(clean.strip_accents(s)), '^unit\\s+([0-9]+),?\\s*', '\\1/'),
        '(^|[^a-z0-9_])crescent([^a-z0-9_]|$)', '\\1cres\\2'),
        '(^|[^a-z0-9_])terrace([^a-z0-9_]|$)',  '\\1tce\\2'),
        '(^|[^a-z0-9_])avenue([^a-z0-9_]|$)',   '\\1ave\\2'),
        '(^|[^a-z0-9_])road([^a-z0-9_]|$)',     '\\1rd\\2'),
        '(^|[^a-z0-9_])street([^a-z0-9_]|$)',   '\\1st\\2'),
        '(^|[^a-z0-9_])drive([^a-z0-9_]|$)',    '\\1dr\\2'),
        '(^|[^a-z0-9_])place([^a-z0-9_]|$)',    '\\1pl\\2'),
        '\\s+', ' ')
    ), '')
$$;

-- Business names: lower case, no accents (Kōwhai), no punctuation, no legal suffix
CREATE OR REPLACE FUNCTION clean.norm_business(s VARCHAR)
RETURNS VARCHAR
AS $$
    NULLIF(TRIM(
        REGEXP_REPLACE(
        REGEXP_REPLACE(
        REGEXP_REPLACE(LOWER(clean.strip_accents(s)), '[^a-z0-9 ]', ' '),
        '(^| )(limited|ltd)( |$)', ' '),
        '\\s+', ' ')
    ), '')
$$;

-- Phones: digits only, +64 -> 0 national format, empty -> NULL
CREATE OR REPLACE FUNCTION clean.norm_phone(s VARCHAR)
RETURNS VARCHAR
AS $$
    NULLIF(REGEXP_REPLACE(REGEXP_REPLACE(s, '[^0-9]', ''), '^64', '0'), '')
$$;

CREATE OR REPLACE FUNCTION clean.digits(s VARCHAR)
RETURNS VARCHAR
AS $$
    NULLIF(REGEXP_REPLACE(s, '[^0-9]', ''), '')
$$;

-- Totara dates look like 27-OCT-1968, Harbourside dates like 2003-05-18; a column loaded as
-- DATE arrives here as YYYY-MM-DD text
CREATE OR REPLACE FUNCTION clean.parse_date(s VARCHAR)
RETURNS DATE
AS $$
    COALESCE(TRY_TO_DATE(s, 'DD-MON-YYYY'), TRY_TO_DATE(s, 'YYYY-MM-DD'))
$$;

-- Y/N flags, also when a column was loaded as BOOLEAN
CREATE OR REPLACE FUNCTION clean.is_yes(s VARCHAR)
RETURNS BOOLEAN
AS $$
    UPPER(TRIM(s)) IN ('Y', 'YES', 'TRUE')
$$;


-- ---------- raw copies, every column as text ----------

-- Same starting point as the local version (CSV read as text): the source tables may hold
-- IDs and postcodes as numbers, which drops leading zeros (CUST_NO 00401267, postcode 0622)
CREATE OR REPLACE TABLE clean.raw_totara AS
SELECT
    LPAD(TO_VARCHAR(CUST_NO), 8, '0')        AS CUST_NO,
    NULLIF(TO_VARCHAR(CLIENT_SEGMENT), '')   AS CLIENT_SEGMENT,
    NULLIF(TO_VARCHAR(FULL_NAME), '')        AS FULL_NAME,
    NULLIF(TO_VARCHAR(ENTITY_NAME), '')      AS ENTITY_NAME,
    NULLIF(TO_VARCHAR(DOB), '')              AS DOB,
    NULLIF(TO_VARCHAR(SEX), '')              AS SEX,
    NULLIF(TO_VARCHAR(TAX_ID), '')           AS TAX_ID,
    NULLIF(TO_VARCHAR(COMPANY_REG_NO), '')   AS COMPANY_REG_NO,
    NULLIF(TO_VARCHAR(NZBN), '')             AS NZBN,
    NULLIF(TO_VARCHAR(ADDR_1), '')           AS ADDR_1,
    NULLIF(TO_VARCHAR(ADDR_2), '')           AS ADDR_2,
    NULLIF(TO_VARCHAR(ADDR_3), '')           AS ADDR_3,
    NULLIF(TO_VARCHAR(CONTACT_PH_1), '')     AS CONTACT_PH_1,
    NULLIF(TO_VARCHAR(CONTACT_PH_2), '')     AS CONTACT_PH_2,
    NULLIF(TO_VARCHAR(EMAIL_ADDR), '')       AS EMAIL_ADDR,
    NULLIF(TO_VARCHAR(ONBOARD_DT), '')       AS ONBOARD_DT,
    NULLIF(TO_VARCHAR(KYC_VERIFIED), '')     AS KYC_VERIFIED,
    NULLIF(TO_VARCHAR(AML_RISK), '')         AS AML_RISK,
    NULLIF(TO_VARCHAR(PEP_IND), '')          AS PEP_IND,
    NULLIF(TO_VARCHAR(PRODUCT_CODES), '')    AS PRODUCT_CODES,
    NULLIF(TO_VARCHAR(ACCT_CNT), '')         AS ACCT_CNT,
    NULLIF(TO_VARCHAR(TOTAL_DEP_BAL), '')    AS TOTAL_DEP_BAL,
    NULLIF(TO_VARCHAR(TOTAL_LOAN_BAL), '')   AS TOTAL_LOAN_BAL,
    NULLIF(TO_VARCHAR(DECEASED_IND), '')     AS DECEASED_IND,
    NULLIF(TO_VARCHAR(STATUS), '')           AS STATUS
FROM PUBLIC.TOTARA_MUTUAL_CUSTOMERS;

CREATE OR REPLACE TABLE clean.raw_harbourside AS
SELECT
    TO_VARCHAR(customer_id)                  AS customer_id,
    NULLIF(TO_VARCHAR(customer_type), '')    AS customer_type,
    NULLIF(TO_VARCHAR(first_name), '')       AS first_name,
    NULLIF(TO_VARCHAR(middle_name), '')      AS middle_name,
    NULLIF(TO_VARCHAR(last_name), '')        AS last_name,
    NULLIF(TO_VARCHAR(business_name), '')    AS business_name,
    NULLIF(TO_VARCHAR(trading_name), '')     AS trading_name,
    NULLIF(TO_VARCHAR(date_of_birth), '')    AS date_of_birth,
    NULLIF(TO_VARCHAR(gender), '')           AS gender,
    NULLIF(TO_VARCHAR(ird_number), '')       AS ird_number,
    NULLIF(TO_VARCHAR(nzbn), '')             AS nzbn,
    NULLIF(TO_VARCHAR(email), '')            AS email,
    NULLIF(TO_VARCHAR(mobile_phone), '')     AS mobile_phone,
    NULLIF(TO_VARCHAR(landline_phone), '')   AS landline_phone,
    NULLIF(TO_VARCHAR(street_address), '')   AS street_address,
    NULLIF(TO_VARCHAR(suburb), '')           AS suburb,
    NULLIF(TO_VARCHAR(city), '')             AS city,
    LPAD(NULLIF(TO_VARCHAR(postcode), ''), 4, '0') AS postcode,
    NULLIF(TO_VARCHAR(customer_since), '')   AS customer_since,
    NULLIF(TO_VARCHAR(kyc_status), '')       AS kyc_status,
    NULLIF(TO_VARCHAR(aml_risk_rating), '')  AS aml_risk_rating,
    NULLIF(TO_VARCHAR(pep_flag), '')         AS pep_flag,
    NULLIF(TO_VARCHAR(num_accounts), '')     AS num_accounts,
    NULLIF(TO_VARCHAR(products_held), '')    AS products_held,
    NULLIF(TO_VARCHAR(total_deposits_nzd), '') AS total_deposits_nzd,
    NULLIF(TO_VARCHAR(total_lending_nzd), '')  AS total_lending_nzd,
    NULLIF(TO_VARCHAR(customer_status), '')  AS customer_status
FROM PUBLIC.HARBOURSIDE_BANK_CUSTOMERS;


-- ---------- standardised records ----------

CREATE OR REPLACE TABLE clean.totara AS
SELECT
    CUST_NO                                                  AS customer_id,
    CASE WHEN CLIENT_SEGMENT = 'RETAIL' THEN 'PERSON' ELSE 'BUSINESS' END AS entity_type,
    -- "WHITE, OLIVER K" -> first "oliver", last "white" (initials dropped)
    NULLIF(LOWER(clean.strip_accents(SPLIT_PART(TRIM(SPLIT_PART(FULL_NAME, ',', 2)), ' ', 1))), '') AS first_name,
    NULLIF(LOWER(clean.strip_accents(TRIM(SPLIT_PART(FULL_NAME, ',', 1)))), '') AS last_name,
    clean.norm_business(ENTITY_NAME)                         AS business_name,
    NULL::VARCHAR                                            AS trading_name,
    clean.parse_date(DOB)                                    AS dob,
    clean.digits(TAX_ID)                                     AS tax_id,
    clean.digits(NZBN)                                       AS nzbn,
    clean.norm_street(ADDR_1)                                AS street,
    REGEXP_SUBSTR(ADDR_3, '([0-9]{4})\\s*$', 1, 1, 'e', 1)   AS postcode
FROM clean.raw_totara;

CREATE OR REPLACE TABLE clean.harbourside AS
SELECT
    customer_id,
    CASE WHEN customer_type = 'Business' THEN 'BUSINESS' ELSE 'PERSON' END AS entity_type,
    NULLIF(LOWER(clean.strip_accents(TRIM(first_name))), '') AS first_name,
    NULLIF(LOWER(clean.strip_accents(TRIM(last_name))), '')  AS last_name,
    clean.norm_business(business_name)                       AS business_name,
    clean.norm_business(trading_name)                        AS trading_name,
    clean.parse_date(date_of_birth)                          AS dob,
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
SELECT 'T:' || customer_id AS record_id, 'T' AS bank, customer_id, entity_type, first_name, last_name,
       business_name, trading_name, dob, tax_id, nzbn, street, postcode
FROM clean.totara
UNION ALL
SELECT 'H:' || customer_id, 'H', customer_id, entity_type, first_name, last_name,
       business_name, trading_name, dob, tax_id, nzbn, street, postcode
FROM clean.harbourside;
