-- ============================================================
-- 3. Golden record: one merged row per customer (Snowflake)
--    Input : clean.customer_clusters (fetureEngineer.sql), clean.records, clean.phones,
--            clean.raw_totara, clean.raw_harbourside (clean.sql)
--    Output: clean.record_profile (every record in one display format, ranked),
--            clean.golden_record (one row per customer),
--            clean.golden_review (source records of customers that need review)
--    Snowflake version of ../goldenRecord.sql; the survivorship rules are described there.
--
-- Two Snowflake notes:
--   * MIN_BY(value, rank) takes the value from the best-ranked record. Setting the rank to NULL
--     for records without the value skips them, like first(... ) FILTER (WHERE ...) in DuckDB.
--   * CONCAT_WS returns NULL if any part is NULL, so text that skips missing parts is built
--     with ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(...), separator).
-- ============================================================

USE DATABASE BANK;

-- "TE RANGI" -> "Te Rangi"; values already in mixed case are left alone
CREATE OR REPLACE FUNCTION clean.title_case(s VARCHAR)
RETURNS VARCHAR
AS $$
    IFF(s = UPPER(s), INITCAP(s, ' '), s)
$$;

-- Totara street in Harbourside's format: "6/128 SEAVIEW TCE" -> "Unit 6, 128 Seaview Terrace"
CREATE OR REPLACE FUNCTION clean.display_street(s VARCHAR)
RETURNS VARCHAR
AS $$
    REGEXP_REPLACE(
    REGEXP_REPLACE(
    REGEXP_REPLACE(
    REGEXP_REPLACE(
    REGEXP_REPLACE(
    REGEXP_REPLACE(
    REGEXP_REPLACE(
        REGEXP_REPLACE(clean.title_case(TRIM(s)), '^([0-9]+)/', 'Unit \\1, '),
    ' Tce$',  ' Terrace'),
    ' Rd$',   ' Road'),
    ' St$',   ' Street'),
    ' Ave$',  ' Avenue'),
    ' Cres$', ' Crescent'),
    ' Dr$',   ' Drive'),
    ' Pl$',   ' Place')
$$;

-- Totara product codes -> Harbourside product names
CREATE OR REPLACE FUNCTION clean.product_name(code VARCHAR)
RETURNS VARCHAR
AS $$
    CASE code
        WHEN 'CHQ'   THEN 'Everyday'
        WHEN 'SAV'   THEN 'Savings'
        WHEN 'TD'    THEN 'Term Deposit'
        WHEN 'CC'    THEN 'Credit Card'
        WHEN 'PL'    THEN 'Personal Loan'
        WHEN 'MTG'   THEN 'Home Loan'
        WHEN 'OD'    THEN 'Overdraft'
        WHEN 'INS'   THEN 'Insurance'
        WHEN 'BCHQ'  THEN 'Business Everyday'
        WHEN 'BSAV'  THEN 'Business Savings'
        WHEN 'BCC'   THEN 'Business Credit Card'
        WHEN 'EQF'   THEN 'Equipment Finance'
        WHEN 'MERCH' THEN 'Merchant Services'
        ELSE code
    END
$$;


CREATE OR REPLACE TABLE clean.record_profile AS
WITH totara_products AS (
    SELECT 'T:' || r.CUST_NO AS record_id,
           ARRAY_AGG(clean.product_name(TRIM(f.value::VARCHAR))) AS products
    FROM clean.raw_totara r,
         LATERAL FLATTEN(input => SPLIT(r.PRODUCT_CODES, '|')) f
    GROUP BY r.CUST_NO
),
harbourside_products AS (
    SELECT 'H:' || r.customer_id AS record_id,
           ARRAY_AGG(TRIM(f.value::VARCHAR)) AS products
    FROM clean.raw_harbourside r,
         LATERAL FLATTEN(input => SPLIT(r.products_held, ';')) f
    GROUP BY r.customer_id
),
totara AS (
    SELECT
        'T:' || CUST_NO                                                           AS record_id,
        -- "WHITE, OLIVER K" -> first "Oliver", middle "K", last "White"
        NULLIF(clean.title_case(SPLIT_PART(TRIM(SPLIT_PART(FULL_NAME, ',', 2)), ' ', 1)), '') AS first_name,
        NULLIF(clean.title_case(REGEXP_SUBSTR(TRIM(SPLIT_PART(FULL_NAME, ',', 2)), '\\s+(.+)$', 1, 1, 'e', 1)), '') AS middle_name,
        NULLIF(clean.title_case(TRIM(SPLIT_PART(FULL_NAME, ',', 1))), '')        AS last_name,
        clean.title_case(ENTITY_NAME)                                             AS business_name,
        NULL::VARCHAR                                                             AS trading_name,
        SEX                                                                       AS gender,
        clean.display_street(ADDR_1)                                              AS street,
        clean.title_case(ADDR_2)                                                  AS suburb,
        clean.title_case(TRIM(REGEXP_REPLACE(ADDR_3, '\\s*[0-9]{4}\\s*$', '')))   AS city,
        LOWER(EMAIL_ADDR)                                                         AS email,
        CASE WHEN clean.is_yes(DECEASED_IND) THEN 'Deceased'
             WHEN STATUS = 'A' THEN 'Active'
             WHEN STATUS = 'D' THEN 'Dormant'
             WHEN STATUS = 'C' THEN 'Closed' END                                  AS status,
        clean.parse_date(ONBOARD_DT)                                              AS customer_since,
        clean.is_yes(KYC_VERIFIED)                                                AS kyc_verified,
        CASE AML_RISK WHEN 'L' THEN 'Low' WHEN 'M' THEN 'Medium' WHEN 'H' THEN 'High' END AS aml_risk,
        clean.is_yes(PEP_IND)                                                     AS pep,
        TRY_TO_NUMBER(ACCT_CNT)                                                   AS num_accounts,
        TRY_TO_DECIMAL(TOTAL_DEP_BAL, 14, 2)                                      AS deposits_nzd,
        TRY_TO_DECIMAL(TOTAL_LOAN_BAL, 14, 2)                                     AS lending_nzd
    FROM clean.raw_totara
),
harbourside AS (
    SELECT
        'H:' || customer_id                                                       AS record_id,
        NULLIF(TRIM(first_name), '')                                              AS first_name,
        NULLIF(TRIM(middle_name), '')                                             AS middle_name,
        NULLIF(TRIM(last_name), '')                                               AS last_name,
        NULLIF(TRIM(business_name), '')                                           AS business_name,
        NULLIF(TRIM(trading_name), '')                                            AS trading_name,
        gender,
        street_address                                                            AS street,
        suburb,
        city,
        LOWER(email)                                                              AS email,
        customer_status                                                           AS status,
        clean.parse_date(customer_since)                                          AS customer_since,
        kyc_status = 'Verified'                                                   AS kyc_verified,
        aml_risk_rating                                                           AS aml_risk,
        clean.is_yes(pep_flag)                                                    AS pep,
        TRY_TO_NUMBER(num_accounts)                                               AS num_accounts,
        TRY_TO_DECIMAL(total_deposits_nzd, 14, 2)                                 AS deposits_nzd,
        TRY_TO_DECIMAL(total_lending_nzd, 14, 2)                                  AS lending_nzd
    FROM clean.raw_harbourside
),
display AS (
    SELECT t.*, tp.products FROM totara t LEFT JOIN totara_products tp ON tp.record_id = t.record_id
    UNION ALL
    SELECT h.*, hp.products FROM harbourside h LEFT JOIN harbourside_products hp ON hp.record_id = h.record_id
)
SELECT
    c.cluster_id                     AS customer_key,
    r.record_id, r.bank, r.customer_id, r.entity_type,
    -- standardised values from clean.sql
    r.dob, r.tax_id, r.nzbn, r.postcode,
    r.last_name                      AS last_name_key,
    r.street                         AS street_key,
    d.first_name, d.middle_name, d.last_name, d.business_name, d.trading_name, d.gender,
    d.street, d.suburb, d.city, d.email, d.status, d.customer_since, d.kyc_verified,
    d.aml_risk, d.pep, d.num_accounts, d.deposits_nzd, d.lending_nzd, d.products,
    ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(d.first_name, d.last_name), ' ')     AS person_name,
    ROW_NUMBER() OVER (
        PARTITION BY c.cluster_id
        ORDER BY (r.bank = 'H') DESC, (r.tax_id IS NOT NULL) DESC,
                 (d.status = 'Active') DESC NULLS LAST, r.record_id
    )                                AS identity_rank,
    ROW_NUMBER() OVER (
        PARTITION BY c.cluster_id
        ORDER BY (d.status = 'Active') DESC NULLS LAST, (r.bank = 'H') DESC,
                 (r.tax_id IS NOT NULL) DESC, r.record_id
    )                                AS contact_rank
FROM clean.customer_clusters c
JOIN clean.records r ON r.record_id = c.record_id
JOIN display d ON d.record_id = c.record_id;


CREATE OR REPLACE TABLE clean.golden_record AS
WITH phones AS (
    SELECT p.customer_key, LISTAGG(DISTINCT ph.phone, '; ') WITHIN GROUP (ORDER BY ph.phone) AS phones
    FROM clean.record_profile p
    JOIN clean.phones ph ON ph.bank = p.bank AND ph.customer_id = p.customer_id
    GROUP BY p.customer_key
),
products AS (
    SELECT p.customer_key,
           LISTAGG(DISTINCT f.value::VARCHAR, '; ') WITHIN GROUP (ORDER BY f.value::VARCHAR) AS products
    FROM clean.record_profile p,
         LATERAL FLATTEN(input => p.products) f
    GROUP BY p.customer_key
),
merged AS (
    SELECT
        customer_key,
        MIN_BY(entity_type, identity_rank)                                        AS entity_type,
        -- name block: first, middle and last name all from the same record
        MIN_BY(first_name,    IFF(last_name IS NOT NULL, identity_rank, NULL))    AS first_name,
        MIN_BY(middle_name,   IFF(last_name IS NOT NULL, identity_rank, NULL))    AS middle_name,
        MIN_BY(last_name,     IFF(last_name IS NOT NULL, identity_rank, NULL))    AS last_name,
        MIN_BY(business_name, IFF(business_name IS NOT NULL, identity_rank, NULL)) AS business_name,
        MIN_BY(trading_name,  IFF(business_name IS NOT NULL, identity_rank, NULL)) AS trading_name,
        ARRAY_AGG(DISTINCT COALESCE(NULLIF(person_name, ''), business_name))      AS all_names,
        MIN_BY(dob,    IFF(dob IS NOT NULL, identity_rank, NULL))                 AS date_of_birth,
        MIN_BY(gender, IFF(gender IS NOT NULL, identity_rank, NULL))              AS gender,
        MIN_BY(tax_id, IFF(tax_id IS NOT NULL, identity_rank, NULL))              AS tax_id,
        MIN_BY(nzbn,   IFF(nzbn IS NOT NULL, identity_rank, NULL))                AS nzbn,
        -- address block: street, suburb, city and postcode all from the same record
        MIN_BY(street,   IFF(street IS NOT NULL, contact_rank, NULL))             AS street,
        MIN_BY(suburb,   IFF(street IS NOT NULL, contact_rank, NULL))             AS suburb,
        MIN_BY(city,     IFF(street IS NOT NULL, contact_rank, NULL))             AS city,
        MIN_BY(postcode, IFF(street IS NOT NULL, contact_rank, NULL))             AS postcode,
        MIN_BY(email,    IFF(email IS NOT NULL, contact_rank, NULL))              AS email,
        NULLIF(LISTAGG(DISTINCT email, '; ') WITHIN GROUP (ORDER BY email), '')   AS all_emails,

        CASE WHEN BOOLOR_AGG(status = 'Deceased') THEN 'Deceased'
             WHEN BOOLOR_AGG(status = 'Active')   THEN 'Active'
             WHEN BOOLOR_AGG(status = 'Dormant')  THEN 'Dormant'
             ELSE 'Closed' END                                                    AS customer_status,
        MIN(customer_since)                                                       AS customer_since,
        BOOLOR_AGG(kyc_verified)                                                  AS kyc_verified,
        CASE MAX(CASE aml_risk WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 END)
             WHEN 1 THEN 'Low' WHEN 2 THEN 'Medium' WHEN 3 THEN 'High' END        AS aml_risk,
        BOOLOR_AGG(pep)                                                           AS pep,

        SUM(num_accounts)::INT                                                    AS num_accounts,
        SUM(deposits_nzd)                                                         AS total_deposits_nzd,
        SUM(lending_nzd)                                                          AS total_lending_nzd,

        BOOLOR_AGG(bank = 'T')                                                    AS in_totara,
        BOOLOR_AGG(bank = 'H')                                                    AS in_harbourside,
        COUNT(*)                                                                  AS n_records,
        -- provenance: which record supplied the name and which the address
        MIN_BY(record_id, identity_rank)                                          AS name_source,
        MIN_BY(record_id, IFF(street IS NOT NULL, contact_rank, NULL))            AS address_source,
        LISTAGG(record_id, '; ') WITHIN GROUP (ORDER BY identity_rank)            AS source_records,

        NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
            CASE WHEN COUNT(DISTINCT tax_id) > 1        THEN 'tax ID differs' END,
            CASE WHEN COUNT(DISTINCT dob) > 1           THEN 'DOB differs' END,
            CASE WHEN COUNT(DISTINCT last_name_key) > 1 THEN 'last name differs (name change or typo)' END,
            CASE WHEN COUNT(DISTINCT street_key) > 1    THEN 'address differs (confirm current address)' END,
            CASE WHEN BOOLOR_AGG(status = 'Deceased') AND BOOLOR_AGG(status = 'Active')
                                                        THEN 'deceased in one record, active in another' END
        ), '; '), '')                                                             AS review_reasons
    FROM clean.record_profile
    GROUP BY customer_key
),
named AS (
    SELECT m.*,
           COALESCE(NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(m.first_name, m.last_name), ' '), ''),
                    m.business_name)                                              AS main_name
    FROM merged m
),
-- every other name the customer is held under (nicknames, typos, previous surnames);
-- compared after normalising, so "Ltd" vs "Limited" or a change of case is not a new name
other_names AS (
    SELECT n.customer_key,
           LISTAGG(a.value::VARCHAR, '; ') WITHIN GROUP (ORDER BY a.value::VARCHAR) AS other_names
    FROM named n,
         LATERAL FLATTEN(input => n.all_names) a
    WHERE clean.norm_business(a.value::VARCHAR) <> clean.norm_business(n.main_name)
    GROUP BY n.customer_key
)
SELECT
    m.customer_key,
    m.entity_type,
    COALESCE(NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(m.first_name, m.middle_name, m.last_name), ' '), ''),
             m.business_name)                                                     AS full_name,
    m.first_name, m.middle_name, m.last_name,
    m.business_name, m.trading_name,
    o.other_names,
    m.date_of_birth, m.gender, m.tax_id, m.nzbn,
    m.street, m.suburb, m.city, m.postcode,
    m.email, m.all_emails, p.phones,
    m.customer_status, m.customer_since, m.kyc_verified, m.aml_risk, m.pep,
    m.num_accounts, m.total_deposits_nzd, m.total_lending_nzd, pr.products,
    m.in_totara, m.in_harbourside, m.n_records, m.name_source, m.address_source, m.source_records,
    m.review_reasons
FROM named m
LEFT JOIN phones p       ON p.customer_key = m.customer_key
LEFT JOIN products pr    ON pr.customer_key = m.customer_key
LEFT JOIN other_names o  ON o.customer_key = m.customer_key
ORDER BY m.customer_key;


-- Review list for a data steward: every source record of each flagged customer, next to the
-- merged value, so the conflicting values can be compared and the chosen one confirmed
CREATE OR REPLACE TABLE clean.golden_review AS
SELECT
    g.customer_key,
    g.review_reasons,
    g.full_name                                                                   AS golden_name,
    g.date_of_birth                                                               AS golden_dob,
    g.tax_id                                                                      AS golden_tax_id,
    ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(g.street, g.suburb,
        ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(g.city, g.postcode), ' ')), ', ') AS golden_address,
    p.record_id,
    CASE p.bank WHEN 'T' THEN 'Totara' ELSE 'Harbourside' END                     AS bank,
    NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
        CASE WHEN p.record_id = g.name_source    THEN 'name' END,
        CASE WHEN p.record_id = g.address_source THEN 'address' END), ' + '), '') AS used_for,
    COALESCE(NULLIF(ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(p.first_name, p.middle_name, p.last_name), ' '), ''),
             p.business_name)                                                     AS record_name,
    p.dob                                                                         AS record_dob,
    p.tax_id                                                                      AS record_tax_id,
    ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(p.street, p.suburb,
        ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(p.city, p.postcode), ' ')), ', ') AS record_address,
    p.status                                                                      AS record_status,
    p.customer_since                                                              AS record_customer_since,
    p.email                                                                       AS record_email
FROM clean.golden_record g
JOIN clean.record_profile p ON p.customer_key = g.customer_key
WHERE g.review_reasons IS NOT NULL
ORDER BY g.review_reasons, g.customer_key, p.identity_rank;
