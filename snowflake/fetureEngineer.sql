-- ============================================================
-- 2. Features -> score -> links -> customers (Snowflake)
--    Input : clean.records, clean.phones (clean.sql)
--    Output: clean.customer_match_features, clean.customer_match_score,
--            clean.links_by_threshold, clean.clusters_by_threshold (every threshold of the
--            sweep, read by finalResult.sql),
--            clean.customer_match_results (links between records),
--            clean.customer_clusters (record -> customer: the standardised customer view)
--    Snowflake version of ../fetureEngineer.sql; same features, score and linking rule.
-- ============================================================

USE DATABASE BANK;

-- Pairs scoring at or above this can be linked. The sweep in finalResult.sql gives
-- F1 = 1.0 for thresholds 25-50; 40 sits mid-plateau, away from both edges.
SET match_threshold = 40;


-- One orientation per record pair: Totara first across banks, lower ID first within a bank
CREATE OR REPLACE FUNCTION clean.is_ordered_pair(bank_a VARCHAR, id_a VARCHAR, bank_b VARCHAR, id_b VARCHAR)
RETURNS BOOLEAN
AS $$
    (bank_a = 'T' AND bank_b = 'H') OR (bank_a = bank_b AND id_a < id_b)
$$;


-- Every record is compared with every other record, across banks (300 x 282 = 84,600) and
-- within each bank (44,850 + 39,621): some customers have two records in one bank, e.g.
-- Totara 00401592 and 00404631 are both David Pohatu. 169,071 pairs is small enough to
-- score them all, so no blocking step is needed and no true match is lost before scoring.
CREATE OR REPLACE TABLE clean.customer_match_features AS
WITH phone_pairs AS (
    SELECT DISTINCT a.bank || ':' || a.customer_id AS record_a,
                    b.bank || ':' || b.customer_id AS record_b
    FROM clean.phones a
    JOIN clean.phones b ON a.phone = b.phone
    WHERE clean.is_ordered_pair(a.bank, a.customer_id, b.bank, b.customer_id)
)
SELECT
    a.record_id              AS record_a,
    b.record_id              AS record_b,
    a.bank || '-' || b.bank  AS pair_type,
    a.entity_type,

    -- evidence for display / audit
    COALESCE(a.first_name || ' ' || a.last_name, a.business_name) AS name_a,
    COALESCE(b.first_name || ' ' || b.last_name, b.business_name) AS name_b,
    a.dob AS dob_a,        b.dob AS dob_b,
    a.tax_id AS tax_id_a,  b.tax_id AS tax_id_b,
    a.street AS street_a,  b.street AS street_b,

    -- identifiers: 1 = both present and equal, conflict = both present and different
    (a.tax_id = b.tax_id)::INT                       AS tax_match,
    -- one typo / transposed digit pair (e.g. 109443176 vs 109443716) is near, not a conflict
    (clean.damerau_levenshtein(a.tax_id, b.tax_id) = 1)::INT AS tax_near,
    (clean.damerau_levenshtein(a.tax_id, b.tax_id) > 1)::INT AS tax_conflict,
    (a.nzbn = b.nzbn)::INT                           AS nzbn_match,
    (a.nzbn <> b.nzbn)::INT                          AS nzbn_conflict,
    (a.dob = b.dob)::INT                             AS dob_match,
    (a.dob <> b.dob)::INT                            AS dob_conflict,
    (p.record_a IS NOT NULL)::INT                    AS phone_match,
    (a.postcode = b.postcode)::INT                   AS postcode_match,
    (a.entity_type <> b.entity_type)::INT            AS type_conflict,

    -- fuzzy similarities (0..1; JAROWINKLER_SIMILARITY returns 0..100); first + last only,
    -- since Totara keeps just a middle initial
    CASE
        WHEN a.entity_type = 'PERSON' AND b.entity_type = 'PERSON'
            THEN JAROWINKLER_SIMILARITY(a.first_name || ' ' || a.last_name,
                                        b.first_name || ' ' || b.last_name) / 100
        -- Totara sometimes holds the Harbourside trading name ("Kowhai Physio" vs "Kōwhai Physiotherapy Limited")
        WHEN a.entity_type = 'BUSINESS' AND b.entity_type = 'BUSINESS'
            THEN GREATEST(COALESCE(JAROWINKLER_SIMILARITY(a.business_name, b.business_name), 0),
                          COALESCE(JAROWINKLER_SIMILARITY(a.business_name, b.trading_name), 0),
                          COALESCE(JAROWINKLER_SIMILARITY(a.trading_name, b.business_name), 0)) / 100
    END                                              AS name_similarity,
    JAROWINKLER_SIMILARITY(a.street, b.street) / 100 AS address_similarity

FROM clean.records a
JOIN clean.records b ON clean.is_ordered_pair(a.bank, a.customer_id, b.bank, b.customer_id)
LEFT JOIN phone_pairs p
       ON p.record_a = a.record_id AND p.record_b = b.record_id;


-- Additive, explainable score. Missing values contribute 0 (COALESCE);
-- conflicting identifiers subtract. Unrelated names score ~0.5-0.6 JW,
-- so name points only start above 0.7.
CREATE OR REPLACE TABLE clean.customer_match_score AS
SELECT
    *,
      50 * COALESCE(tax_match, 0)     - 40 * COALESCE(tax_conflict, 0)
    + 30 * COALESCE(tax_near, 0)
    + 50 * COALESCE(nzbn_match, 0)    - 40 * COALESCE(nzbn_conflict, 0)
    + 20 * COALESCE(dob_match, 0)     - 25 * COALESCE(dob_conflict, 0)
    + 20 * phone_match
    + 30 * GREATEST(0, (COALESCE(name_similarity, 0) - 0.7) / 0.3)
    + 10 * (COALESCE(address_similarity, 0) >= 0.9)::INT
    +  5 * COALESCE(postcode_match, 0)
    - 50 * COALESCE(type_conflict, 0)
    AS match_score
FROM clean.customer_match_features;


-- The thresholds to link at: the chosen one, plus 10-150 in steps of 5 for the sweep in
-- finalResult.sql, so the sweep uses exactly the same linking and clustering as the result
CREATE OR REPLACE TABLE clean.thresholds AS
SELECT DISTINCT threshold
FROM (
    SELECT 5 * (ROW_NUMBER() OVER (ORDER BY SEQ4()) + 1) AS threshold
    FROM TABLE(GENERATOR(ROWCOUNT => 29))
    UNION ALL
    SELECT $match_threshold
);


-- A pair is linked when it scores at or above the threshold AND it is the best-scoring pair
-- of at least one of its two records. "Either" rather than "both": a customer with two
-- records in one bank has both of them linked to the same third record.
CREATE OR REPLACE TABLE clean.links_by_threshold AS
WITH candidates AS (
    SELECT t.threshold, s.*
    FROM clean.customer_match_score s
    JOIN clean.thresholds t ON s.match_score >= t.threshold
),
best AS (
    SELECT threshold, record_id, MAX(match_score) AS best_score
    FROM (SELECT threshold, record_a AS record_id, match_score FROM candidates
          UNION ALL
          SELECT threshold, record_b, match_score FROM candidates)
    GROUP BY threshold, record_id
)
SELECT c.*
FROM candidates c
JOIN best ba ON ba.threshold = c.threshold AND ba.record_id = c.record_a
JOIN best bb ON bb.threshold = c.threshold AND bb.record_id = c.record_b
WHERE c.match_score = ba.best_score OR c.match_score = bb.best_score;


-- Records joined by links, directly or through other records, are one customer
-- (connected components). cluster_id is the smallest record_id in the group.
-- Snowflake recursion is UNION ALL only, so each walk carries the records it has visited
-- and never returns to one of them; that is what makes it stop.
CREATE OR REPLACE TABLE clean.clusters_by_threshold AS
WITH RECURSIVE
edges AS (
    SELECT threshold, record_a AS src, record_b AS dst FROM clean.links_by_threshold
    UNION ALL
    SELECT threshold, record_b, record_a FROM clean.links_by_threshold
),
reach (threshold, record_id, linked, visited) AS (
    SELECT t.threshold, r.record_id, r.record_id, ARRAY_CONSTRUCT(r.record_id)
    FROM clean.thresholds t
    CROSS JOIN clean.records r
    UNION ALL
    SELECT reach.threshold, reach.record_id, edges.dst, ARRAY_APPEND(reach.visited, edges.dst)
    FROM reach
    JOIN edges ON edges.threshold = reach.threshold AND edges.src = reach.linked
    WHERE NOT ARRAY_CONTAINS(edges.dst::VARIANT, reach.visited)
)
SELECT reach.threshold, r.record_id, r.bank, r.customer_id, r.entity_type,
       MIN(reach.linked) AS cluster_id
FROM reach
JOIN clean.records r ON r.record_id = reach.record_id
GROUP BY reach.threshold, r.record_id, r.bank, r.customer_id, r.entity_type;


-- Links at the chosen threshold: the evidence behind every merge
CREATE OR REPLACE TABLE clean.customer_match_results AS
SELECT * EXCLUDE (threshold), 'MATCH' AS match_decision
FROM clean.links_by_threshold
WHERE threshold = $match_threshold;

-- The standardised customer view: one cluster_id per real customer, covering every record
-- of that customer in either bank
CREATE OR REPLACE TABLE clean.customer_clusters AS
SELECT * EXCLUDE (threshold)
FROM clean.clusters_by_threshold
WHERE threshold = $match_threshold;
