-- ============================================================
-- 2. Features -> score -> links -> customers (DuckDB, runs locally)
--    Input : clean.records, clean.phones (clean.sql)
--    Output: clean.customer_match_features, clean.customer_match_score,
--            clean.customer_match_results (links between records),
--            clean.customer_clusters (record -> customer: the standardised customer view)
-- ============================================================

-- Pairs scoring at or above this can be linked. The sweep in finalResult.sql gives
-- F1 = 1.0 for thresholds 25-50; 40 sits mid-plateau, away from both edges.
SET VARIABLE match_threshold = 40;


-- One orientation per record pair: Totara first across banks, lower ID first within a bank
CREATE OR REPLACE MACRO clean.is_ordered_pair(bank_a, id_a, bank_b, id_b) AS
    (bank_a = 'T' AND bank_b = 'H') OR (bank_a = bank_b AND id_a < id_b);


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
    (damerau_levenshtein(a.tax_id, b.tax_id) = 1)::INT AS tax_near,
    (damerau_levenshtein(a.tax_id, b.tax_id) > 1)::INT AS tax_conflict,
    (a.nzbn = b.nzbn)::INT                           AS nzbn_match,
    (a.nzbn <> b.nzbn)::INT                          AS nzbn_conflict,
    (a.dob = b.dob)::INT                             AS dob_match,
    (a.dob <> b.dob)::INT                            AS dob_conflict,
    (p.record_a IS NOT NULL)::INT                    AS phone_match,
    (a.postcode = b.postcode)::INT                   AS postcode_match,
    (a.entity_type <> b.entity_type)::INT            AS type_conflict,

    -- fuzzy similarities (0..1); first + last only, since Totara keeps just a middle initial
    CASE
        WHEN a.entity_type = 'PERSON' AND b.entity_type = 'PERSON'
            THEN jaro_winkler_similarity(a.first_name || ' ' || a.last_name,
                                         b.first_name || ' ' || b.last_name)
        -- Totara sometimes holds the Harbourside trading name ("Kowhai Physio" vs "Kōwhai Physiotherapy Limited")
        WHEN a.entity_type = 'BUSINESS' AND b.entity_type = 'BUSINESS'
            THEN GREATEST(jaro_winkler_similarity(a.business_name, b.business_name),
                          COALESCE(jaro_winkler_similarity(a.business_name, b.trading_name), 0),
                          COALESCE(jaro_winkler_similarity(a.trading_name, b.business_name), 0))
    END                                              AS name_similarity,
    jaro_winkler_similarity(a.street, b.street)      AS address_similarity

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


-- A pair is linked when it scores at or above the threshold AND it is the best-scoring pair
-- of at least one of its two records. "Either" rather than "both": a customer with two
-- records in one bank has both of them linked to the same third record.
-- Takes a list of thresholds so finalResult.sql can sweep with the same rule.
CREATE OR REPLACE MACRO clean.links_at(thresholds) AS TABLE
WITH candidates AS (
    SELECT t.threshold, s.*
    FROM clean.customer_match_score s
    JOIN (SELECT unnest(thresholds) AS threshold) t ON s.match_score >= t.threshold
),
best AS (
    SELECT threshold, record_id, max(match_score) AS best_score
    FROM (SELECT threshold, record_a AS record_id, match_score FROM candidates
          UNION ALL
          SELECT threshold, record_b, match_score FROM candidates)
    GROUP BY ALL
)
SELECT c.*
FROM candidates c
JOIN best ba ON ba.threshold = c.threshold AND ba.record_id = c.record_a
JOIN best bb ON bb.threshold = c.threshold AND bb.record_id = c.record_b
WHERE c.match_score = ba.best_score OR c.match_score = bb.best_score;


-- Records joined by links, directly or through other records, are one customer
-- (connected components). cluster_id is the smallest record_id in the group.
CREATE OR REPLACE MACRO clean.clusters_at(thresholds) AS TABLE
WITH RECURSIVE
links AS (FROM clean.links_at(thresholds)),
edges AS (
    SELECT threshold, record_a AS src, record_b AS dst FROM links
    UNION ALL
    SELECT threshold, record_b, record_a FROM links
),
reach(threshold, record_id, linked) AS (
    SELECT t.threshold, r.record_id, r.record_id
    FROM (SELECT unnest(thresholds) AS threshold) t, clean.records r
    UNION
    SELECT reach.threshold, reach.record_id, edges.dst
    FROM reach
    JOIN edges ON edges.threshold = reach.threshold AND edges.src = reach.linked
)
SELECT reach.threshold, r.record_id, r.bank, r.customer_id, r.entity_type,
       min(reach.linked) AS cluster_id
FROM reach
JOIN clean.records r USING (record_id)
GROUP BY ALL;


-- Links at the chosen threshold: the evidence behind every merge
CREATE OR REPLACE TABLE clean.customer_match_results AS
SELECT * EXCLUDE (threshold), 'MATCH' AS match_decision
FROM clean.links_at([getvariable('match_threshold')]);

-- The standardised customer view: one cluster_id per real customer, covering every record
-- of that customer in either bank
CREATE OR REPLACE TABLE clean.customer_clusters AS
SELECT * EXCLUDE (threshold)
FROM clean.clusters_at([getvariable('match_threshold')]);
