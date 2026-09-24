-- ============================================================
-- 3. Golden record: one merged row per customer (DuckDB, runs locally)
--    Input : clean.customer_clusters (fetureEngineer.sql), clean.records, clean.phones,
--            clean.raw_totara, clean.raw_harbourside (clean.sql)
--    Output: clean.record_profile (every record in one display format, ranked),
--            clean.golden_record (one row per customer),
--            clean.golden_review (source records of customers that need review)
--
-- Survivorship rules, per customer. Records are ranked twice:
--   * identity_rank, for the name, gender and identifiers (DOB, tax ID, NZBN): Harbourside
--     first, then records with a tax ID, then active records, then lowest ID. Harbourside
--     stores full, properly cased names (Totara keeps only a middle initial), and the name
--     typos in the data (Willaims, Malceod, Charltote) are all on the Totara side.
--   * contact_rank, for the address and primary email: active records first (an active
--     relationship is more likely to hold the current address), then as identity_rank.
--   * The name block and the address block are each taken whole from the best-ranked record
--     that has one, so a street is never combined with another record's suburb.
--   * Status and risk: the most severe value wins (deceased, highest AML risk, PEP if any).
--   * Accounts, balances and products are added up: duplicate records hold different accounts.
--   * Nothing is dropped: other names, all emails and all phones are kept, and disagreements
--     between records are listed in review_reasons for a data steward.
-- ============================================================

-- "TE RANGI" -> "Te Rangi"; values already in mixed case are left alone
CREATE OR REPLACE MACRO clean.title_case(s) AS
    CASE WHEN s = upper(s)
         THEN array_to_string(list_transform(string_split(lower(s), ' '),
                                             lambda w: upper(w[1]) || w[2:]), ' ')
         ELSE s END;

-- Totara street in Harbourside's format: "6/128 SEAVIEW TCE" -> "Unit 6, 128 Seaview Terrace"
CREATE OR REPLACE MACRO clean.display_street(s) AS
    regexp_replace(
    regexp_replace(
    regexp_replace(
    regexp_replace(
    regexp_replace(
    regexp_replace(
    regexp_replace(
        regexp_replace(clean.title_case(TRIM(s)), '^(\d+)/', 'Unit \1, '),
    ' Tce$',  ' Terrace'),
    ' Rd$',   ' Road'),
    ' St$',   ' Street'),
    ' Ave$',  ' Avenue'),
    ' Cres$', ' Crescent'),
    ' Dr$',   ' Drive'),
    ' Pl$',   ' Place');

-- Totara product codes -> Harbourside product names
CREATE OR REPLACE MACRO clean.product_name(code) AS
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
    END;


CREATE OR REPLACE TABLE clean.record_profile AS
WITH totara AS (
    SELECT
        'T:' || CUST_NO                                                           AS record_id,
        -- "WHITE, OLIVER K" -> first "Oliver", middle "K", last "White"
        NULLIF(clean.title_case(split_part(TRIM(split_part(FULL_NAME, ',', 2)), ' ', 1)), '') AS first_name,
        NULLIF(clean.title_case(regexp_extract(TRIM(split_part(FULL_NAME, ',', 2)), '\s+(.+)$', 1)), '') AS middle_name,
        NULLIF(clean.title_case(TRIM(split_part(FULL_NAME, ',', 1))), '')        AS last_name,
        clean.title_case(ENTITY_NAME)                                             AS business_name,
        NULL::VARCHAR                                                             AS trading_name,
        SEX                                                                       AS gender,
        clean.display_street(ADDR_1)                                              AS street,
        clean.title_case(ADDR_2)                                                  AS suburb,
        clean.title_case(TRIM(regexp_replace(ADDR_3, '\s*\d{4}\s*$', '')))        AS city,
        lower(EMAIL_ADDR)                                                         AS email,
        CASE WHEN DECEASED_IND = 'Y' THEN 'Deceased'
             WHEN STATUS = 'A' THEN 'Active'
             WHEN STATUS = 'D' THEN 'Dormant'
             WHEN STATUS = 'C' THEN 'Closed' END                                  AS status,
        try_strptime(ONBOARD_DT, '%d-%b-%Y')::DATE                                AS customer_since,
        KYC_VERIFIED = 'Y'                                                        AS kyc_verified,
        CASE AML_RISK WHEN 'L' THEN 'Low' WHEN 'M' THEN 'Medium' WHEN 'H' THEN 'High' END AS aml_risk,
        PEP_IND = 'Y'                                                             AS pep,
        TRY_CAST(ACCT_CNT AS INT)                                                 AS num_accounts,
        TRY_CAST(TOTAL_DEP_BAL AS DECIMAL(14, 2))                                 AS deposits_nzd,
        TRY_CAST(TOTAL_LOAN_BAL AS DECIMAL(14, 2))                                AS lending_nzd,
        list_transform(string_split(PRODUCT_CODES, '|'), lambda c: clean.product_name(TRIM(c))) AS products
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
        lower(email)                                                              AS email,
        customer_status                                                           AS status,
        TRY_CAST(customer_since AS DATE)                                          AS customer_since,
        kyc_status = 'Verified'                                                   AS kyc_verified,
        aml_risk_rating                                                           AS aml_risk,
        pep_flag = 'Y'                                                            AS pep,
        TRY_CAST(num_accounts AS INT)                                             AS num_accounts,
        TRY_CAST(total_deposits_nzd AS DECIMAL(14, 2))                            AS deposits_nzd,
        TRY_CAST(total_lending_nzd AS DECIMAL(14, 2))                             AS lending_nzd,
        list_transform(string_split(products_held, ';'), lambda p: TRIM(p))       AS products
    FROM clean.raw_harbourside
)
SELECT
    c.cluster_id                     AS customer_key,
    r.record_id, r.bank, r.customer_id, r.entity_type,
    -- standardised values from clean.sql
    r.dob, r.tax_id, r.nzbn, r.postcode,
    r.last_name                      AS last_name_key,
    r.street                         AS street_key,
    d.* EXCLUDE (record_id),
    concat_ws(' ', d.first_name, d.last_name)                                     AS person_name,
    row_number() OVER (
        PARTITION BY c.cluster_id
        ORDER BY (r.bank = 'H') DESC, (r.tax_id IS NOT NULL) DESC, (d.status = 'Active') DESC, r.record_id
    )                                AS identity_rank,
    row_number() OVER (
        PARTITION BY c.cluster_id
        ORDER BY (d.status = 'Active') DESC, (r.bank = 'H') DESC, (r.tax_id IS NOT NULL) DESC, r.record_id
    )                                AS contact_rank
FROM clean.customer_clusters c
JOIN clean.records r USING (record_id)
JOIN (FROM totara UNION ALL BY NAME FROM harbourside) d USING (record_id);


CREATE OR REPLACE TABLE clean.golden_record AS
WITH phones AS (
    SELECT p.customer_key, string_agg(DISTINCT ph.phone, '; ' ORDER BY ph.phone) AS phones
    FROM clean.record_profile p
    JOIN clean.phones ph ON ph.bank = p.bank AND ph.customer_id = p.customer_id
    GROUP BY p.customer_key
),
merged AS (
    SELECT
        customer_key,
        first(entity_type ORDER BY identity_rank)                                 AS entity_type,
        first({'first_name': first_name, 'middle_name': middle_name, 'last_name': last_name}
              ORDER BY identity_rank) FILTER (WHERE last_name IS NOT NULL)        AS person,
        first({'business_name': business_name, 'trading_name': trading_name}
              ORDER BY identity_rank) FILTER (WHERE business_name IS NOT NULL)    AS business,
        list(DISTINCT COALESCE(NULLIF(person_name, ''), business_name))           AS all_names,
        first(dob    ORDER BY identity_rank) FILTER (WHERE dob IS NOT NULL)       AS date_of_birth,
        first(gender ORDER BY identity_rank) FILTER (WHERE gender IS NOT NULL)    AS gender,
        first(tax_id ORDER BY identity_rank) FILTER (WHERE tax_id IS NOT NULL)    AS tax_id,
        first(nzbn   ORDER BY identity_rank) FILTER (WHERE nzbn IS NOT NULL)      AS nzbn,
        first({'street': street, 'suburb': suburb, 'city': city, 'postcode': postcode}
              ORDER BY contact_rank) FILTER (WHERE street IS NOT NULL)            AS address,
        first(email  ORDER BY contact_rank) FILTER (WHERE email IS NOT NULL)      AS email,
        string_agg(DISTINCT email, '; ' ORDER BY email)                           AS all_emails,

        CASE WHEN bool_or(status = 'Deceased') THEN 'Deceased'
             WHEN bool_or(status = 'Active')   THEN 'Active'
             WHEN bool_or(status = 'Dormant')  THEN 'Dormant'
             ELSE 'Closed' END                                                    AS customer_status,
        min(customer_since)                                                       AS customer_since,
        bool_or(kyc_verified)                                                     AS kyc_verified,
        CASE max(CASE aml_risk WHEN 'Low' THEN 1 WHEN 'Medium' THEN 2 WHEN 'High' THEN 3 END)
             WHEN 1 THEN 'Low' WHEN 2 THEN 'Medium' WHEN 3 THEN 'High' END        AS aml_risk,
        bool_or(pep)                                                              AS pep,

        sum(num_accounts)::INT                                                    AS num_accounts,
        sum(deposits_nzd)                                                         AS total_deposits_nzd,
        sum(lending_nzd)                                                          AS total_lending_nzd,
        array_to_string(list_sort(list_distinct(flatten(list(products)))), '; ')  AS products,

        bool_or(bank = 'T')                                                       AS in_totara,
        bool_or(bank = 'H')                                                       AS in_harbourside,
        count(*)                                                                  AS n_records,
        -- provenance: which record supplied the name and which the address
        first(record_id ORDER BY identity_rank)                                   AS name_source,
        first(record_id ORDER BY contact_rank) FILTER (WHERE street IS NOT NULL)  AS address_source,
        string_agg(record_id, '; ' ORDER BY identity_rank)                        AS source_records,

        NULLIF(concat_ws('; ',
            CASE WHEN count(DISTINCT tax_id) > 1        THEN 'tax ID differs' END,
            CASE WHEN count(DISTINCT dob) > 1           THEN 'DOB differs' END,
            CASE WHEN count(DISTINCT last_name_key) > 1 THEN 'last name differs (name change or typo)' END,
            CASE WHEN count(DISTINCT street_key) > 1    THEN 'address differs (confirm current address)' END,
            CASE WHEN bool_or(status = 'Deceased') AND bool_or(status = 'Active')
                                                        THEN 'deceased in one record, active in another' END
        ), '')                                                                    AS review_reasons
    FROM clean.record_profile
    GROUP BY customer_key
)
SELECT
    m.customer_key,
    m.entity_type,
    COALESCE(NULLIF(concat_ws(' ', m.person.first_name, m.person.middle_name, m.person.last_name), ''),
             m.business.business_name)                                            AS full_name,
    m.person.first_name, m.person.middle_name, m.person.last_name,
    m.business.business_name, m.business.trading_name,
    -- every other name the customer is held under (nicknames, typos, previous surnames);
    -- compared after normalising, so "Ltd" vs "Limited" or a change of case is not a new name
    NULLIF(array_to_string(list_sort(list_filter(m.all_names, lambda n:
        clean.norm_business(n) <> clean.norm_business(
            COALESCE(NULLIF(concat_ws(' ', m.person.first_name, m.person.last_name), ''),
                     m.business.business_name)))), '; '), '')                     AS other_names,
    m.date_of_birth, m.gender, m.tax_id, m.nzbn,
    m.address.street, m.address.suburb, m.address.city, m.address.postcode,
    m.email, m.all_emails, p.phones,
    m.customer_status, m.customer_since, m.kyc_verified, m.aml_risk, m.pep,
    m.num_accounts, m.total_deposits_nzd, m.total_lending_nzd, m.products,
    m.in_totara, m.in_harbourside, m.n_records, m.name_source, m.address_source, m.source_records,
    m.review_reasons
FROM merged m
LEFT JOIN phones p USING (customer_key)
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
    concat_ws(', ', g.street, g.suburb, concat_ws(' ', g.city, g.postcode))       AS golden_address,
    p.record_id,
    CASE p.bank WHEN 'T' THEN 'Totara' ELSE 'Harbourside' END                     AS bank,
    NULLIF(concat_ws(' + ',
        CASE WHEN p.record_id = g.name_source    THEN 'name' END,
        CASE WHEN p.record_id = g.address_source THEN 'address' END), '')         AS used_for,
    COALESCE(NULLIF(concat_ws(' ', p.first_name, p.middle_name, p.last_name), ''),
             p.business_name)                                                     AS record_name,
    p.dob                                                                         AS record_dob,
    p.tax_id                                                                      AS record_tax_id,
    concat_ws(', ', p.street, p.suburb, concat_ws(' ', p.city, p.postcode))       AS record_address,
    p.status                                                                      AS record_status,
    p.customer_since                                                              AS record_customer_since,
    p.email                                                                       AS record_email
FROM clean.golden_record g
JOIN clean.record_profile p USING (customer_key)
WHERE g.review_reasons IS NOT NULL
ORDER BY g.review_reasons, g.customer_key, p.identity_rank;
