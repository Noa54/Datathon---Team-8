-- ============================================================
-- 4. Evaluate against the answer key (DuckDB, runs locally)
--    Input : answer key CSV exported from PUBLIC.BANK_MERGER_ANSWER_KEY
--            (columns BANK, CUSTOMER_ID, TRUEENTITYID), path in variable answer_key_path
--    Output: clean.key_coverage, clean.match_evaluation, clean.match_metrics,
--            clean.customer_metrics, clean.threshold_sweep, clean.same_bank_duplicates
--
-- Evaluation is on customers, not single links: two records count as predicted "same"
-- when they end up in the same cluster. True pairs are every two records that share a
-- TRUEENTITYID, across banks AND within one bank, so a missed duplicate always counts
-- as a false negative.
-- ============================================================

CREATE OR REPLACE TABLE clean.answer_key AS
SELECT *, bank || ':' || customer_id AS record_id
FROM (
    SELECT
        CASE WHEN lower(bank) LIKE '%totara%'  THEN 'T'
             WHEN lower(bank) LIKE '%harbour%' THEN 'H' END             AS bank,
        -- Totara IDs are 8-digit, zero-padded (CUST_NO); pad in case the export dropped zeros
        CASE WHEN lower(bank) LIKE '%totara%' THEN lpad(TRIM(customer_id), 8, '0')
             ELSE TRIM(customer_id) END                                  AS customer_id,
        TRIM(trueentityid)                                               AS true_entity_id
    FROM read_csv(getvariable('answer_key_path'), header = true, all_varchar = true, normalize_names = true)
);


-- Every key row should join to a cleaned record, and vice versa; non-zero here means an ID format problem
CREATE OR REPLACE TABLE clean.key_coverage AS
SELECT 'key rows with unrecognised BANK' AS check_name,
       count(*) FILTER (WHERE bank IS NULL) AS n FROM clean.answer_key
UNION ALL
SELECT 'key rows not in clean.records', count(*)
FROM clean.answer_key k ANTI JOIN clean.records r USING (record_id)
UNION ALL
SELECT 'clean.records rows missing from key', count(*)
FROM clean.records r ANTI JOIN clean.answer_key k USING (record_id)
UNION ALL
-- Informational, not an error: customers with several records in one bank
SELECT 'info: entities with >1 record in the same bank', count(*)
FROM (SELECT true_entity_id FROM clean.answer_key GROUP BY true_entity_id, bank HAVING count(*) > 1);


-- Every two records of the same real customer, oriented like clean.customer_match_features
CREATE OR REPLACE TABLE clean.true_pairs AS
SELECT a.record_id AS record_a, b.record_id AS record_b
FROM clean.answer_key a
JOIN clean.answer_key b
  ON a.true_entity_id = b.true_entity_id
 AND clean.is_ordered_pair(a.bank, a.customer_id, b.bank, b.customer_id);


-- Predicted vs true pairs: TP / FP / FN (TN is every other of the 169,071 pairs, not informative)
CREATE OR REPLACE TABLE clean.match_evaluation AS
WITH predicted AS (
    SELECT a.record_id AS record_a, b.record_id AS record_b
    FROM clean.customer_clusters a
    JOIN clean.customer_clusters b
      ON a.cluster_id = b.cluster_id
     AND clean.is_ordered_pair(a.bank, a.customer_id, b.bank, b.customer_id)
)
SELECT
    s.record_a, s.record_b, s.pair_type, s.entity_type,
    s.name_a, s.name_b, s.match_score,
    CASE WHEN p.record_a IS NOT NULL AND g.record_a IS NOT NULL THEN 'TP'
         WHEN p.record_a IS NOT NULL                            THEN 'FP'
         ELSE 'FN' END                           AS outcome
FROM predicted p
FULL OUTER JOIN clean.true_pairs g
       ON p.record_a = g.record_a AND p.record_b = g.record_b
JOIN clean.customer_match_score s
  ON s.record_a = COALESCE(p.record_a, g.record_a)
 AND s.record_b = COALESCE(p.record_b, g.record_b);


-- Overall, per pair type (T-H across banks, T-T / H-H duplicates inside a bank), per entity type
CREATE OR REPLACE TABLE clean.match_metrics AS
WITH counts AS (
    SELECT
        CASE WHEN GROUPING(pair_type) = 0   THEN 'pairs ' || pair_type
             WHEN GROUPING(entity_type) = 0 THEN entity_type
             ELSE 'ALL' END                     AS segment,
        GROUPING(pair_type, entity_type)        AS sort_key,
        count(*) FILTER (WHERE outcome = 'TP') AS tp,
        count(*) FILTER (WHERE outcome = 'FP') AS fp,
        count(*) FILTER (WHERE outcome = 'FN') AS fn
    FROM clean.match_evaluation
    GROUP BY GROUPING SETS ((), (pair_type), (entity_type))
)
SELECT
    segment, tp, fp, fn,
    round(tp / NULLIF(tp + fp, 0), 4)          AS precision,
    round(tp / NULLIF(tp + fn, 0), 4)          AS recall,
    round(2 * tp / NULLIF(2 * tp + fp + fn, 0), 4) AS f1
FROM counts
ORDER BY sort_key DESC, segment;


-- Customer view: is every real customer exactly one cluster?
CREATE OR REPLACE TABLE clean.customer_metrics AS
WITH k AS (
    SELECT k.true_entity_id, c.cluster_id, c.record_id
    FROM clean.answer_key k JOIN clean.customer_clusters c USING (record_id)
),
truth AS (SELECT true_entity_id, list(record_id ORDER BY record_id) AS members FROM k GROUP BY 1),
pred  AS (SELECT cluster_id,     list(record_id ORDER BY record_id) AS members FROM k GROUP BY 1)
SELECT
    (SELECT count(*) FROM truth)                                         AS true_customers,
    (SELECT count(*) FROM pred)                                          AS predicted_customers,
    (SELECT count(*) FROM truth JOIN pred USING (members))               AS exactly_right,
    -- one real customer spread over several clusters (missed duplicate / missed match)
    (SELECT count(*) FROM (SELECT true_entity_id FROM k GROUP BY 1 HAVING count(DISTINCT cluster_id) > 1))
                                                                         AS split_customers,
    -- one cluster holding several real customers (wrong merge)
    (SELECT count(*) FROM (SELECT cluster_id FROM k GROUP BY 1 HAVING count(DISTINCT true_entity_id) > 1))
                                                                         AS merged_clusters;


-- Same link + cluster rule as fetureEngineer.sql, at each threshold
CREATE OR REPLACE TABLE clean.threshold_sweep AS
WITH clusters AS (
    FROM clean.clusters_at(range(10, 155, 5))
),
predicted AS (
    SELECT a.threshold, a.record_id AS record_a, b.record_id AS record_b
    FROM clusters a
    JOIN clusters b
      ON a.threshold = b.threshold
     AND a.cluster_id = b.cluster_id
     AND clean.is_ordered_pair(a.bank, a.customer_id, b.bank, b.customer_id)
),
counts AS (
    SELECT
        t.threshold,
        count(g.record_a)                                AS tp,
        count(p.record_a) - count(g.record_a)            AS fp,
        (SELECT count(*) FROM clean.true_pairs) - count(g.record_a) AS fn
    FROM (SELECT DISTINCT threshold FROM clusters) t
    LEFT JOIN predicted p ON p.threshold = t.threshold
    LEFT JOIN clean.true_pairs g
           ON p.record_a = g.record_a AND p.record_b = g.record_b
    GROUP BY t.threshold
)
SELECT
    threshold, tp, fp, fn,
    round(tp / NULLIF(tp + fp, 0), 4)          AS precision,
    round(tp / NULLIF(tp + fn, 0), 4)          AS recall,
    round(2 * tp / NULLIF(2 * tp + fp + fn, 0), 4) AS f1
FROM counts
ORDER BY threshold;


-- Customers held twice in one bank and not at all in the other, as they appear in the source
-- CSVs. Only within-bank matching can find these; a cross-bank-only comparison splits them.
CREATE OR REPLACE TABLE clean.same_bank_duplicates AS
WITH dups AS (
    SELECT k.*, c.cluster_id
    FROM clean.answer_key k
    JOIN clean.customer_clusters c USING (record_id)
    WHERE k.true_entity_id IN (
        SELECT true_entity_id FROM clean.answer_key
        GROUP BY 1 HAVING count(DISTINCT bank) = 1 AND count(*) > 1)
)
SELECT d.true_entity_id, 'Totara' AS bank, r.CUST_NO AS customer_id, d.cluster_id,
       r.CLIENT_SEGMENT AS customer_type, COALESCE(r.FULL_NAME, r.ENTITY_NAME) AS name,
       r.DOB AS dob, r.TAX_ID AS tax_id,
       -- a missing suburb stays visible as ", ,"
       r.ADDR_1 || ', ' || COALESCE(r.ADDR_2, '') || ', ' || COALESCE(r.ADDR_3, '') AS address,
       r.CONTACT_PH_1 AS phone_1, r.CONTACT_PH_2 AS phone_2, r.EMAIL_ADDR AS email, r.STATUS AS status
FROM dups d JOIN clean.raw_totara r ON d.bank = 'T' AND r.CUST_NO = d.customer_id
UNION ALL
SELECT d.true_entity_id, 'Harbourside', r.customer_id, d.cluster_id, r.customer_type,
       COALESCE(NULLIF(concat_ws(' ', r.first_name, r.middle_name, r.last_name), ''), r.business_name),
       r.date_of_birth, r.ird_number,
       concat_ws(', ', r.street_address, r.suburb, concat_ws(' ', r.city, r.postcode)),
       r.mobile_phone, r.landline_phone, r.email, r.customer_status
FROM dups d JOIN clean.raw_harbourside r ON d.bank = 'H' AND r.customer_id = d.customer_id
ORDER BY bank DESC, true_entity_id, customer_id;
