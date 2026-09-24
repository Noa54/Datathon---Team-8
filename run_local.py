"""Run the Kendrix entity-resolution pipeline locally with DuckDB.

Usage:
    .venv/bin/python run_local.py [path/to/bank_merger_answer_key.csv]

The answer key defaults to bank_merger_answer_key.csv in the repo root (an export of
PUBLIC.BANK_MERGER_ANSWER_KEY). Without it, the pipeline still runs and writes
the matches, but evaluation is skipped.
"""

import sys
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "output"


def run_sql(con, name):
    con.execute((ROOT / name).read_text())


def show(con, title, query):
    print(f"\n== {title}")
    con.sql(query).show(max_rows=100, max_width=200)


def main():
    answer_key = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / "bank_merger_answer_key.csv"
    OUTPUT.mkdir(exist_ok=True)

    con = duckdb.connect()
    # The SQL files read the source CSVs by relative path
    con.execute(f"SET file_search_path = '{ROOT}'")

    run_sql(con, "clean.sql")
    run_sql(con, "fetureEngineer.sql")
    run_sql(con, "goldenRecord.sql")

    show(con, "Row counts", """
        SELECT 'clean.totara' AS tbl, count(*) AS n FROM clean.totara
        UNION ALL SELECT 'clean.harbourside', count(*) FROM clean.harbourside
        UNION ALL SELECT 'clean.customer_match_features (pairs scored)', count(*) FROM clean.customer_match_features
        UNION ALL SELECT 'clean.customer_match_results (links)', count(*) FROM clean.customer_match_results
        UNION ALL SELECT 'customers (clusters)', count(DISTINCT cluster_id) FROM clean.customer_clusters
        UNION ALL SELECT 'clean.golden_record', count(*) FROM clean.golden_record
    """)
    show(con, "Sanity checks (all should be 0)", """
        SELECT 'Totara DOB present but unparsed' AS check_name, count(*) AS n
        FROM clean.raw_totara r JOIN clean.totara t ON t.customer_id = r.CUST_NO
        WHERE r.DOB IS NOT NULL AND t.dob IS NULL
        UNION ALL
        SELECT 'Harbourside DOB present but unparsed', count(*)
        FROM clean.raw_harbourside r JOIN clean.harbourside h USING (customer_id)
        WHERE r.date_of_birth IS NOT NULL AND h.dob IS NULL
        UNION ALL
        SELECT 'phones not 0 + 8-9 digits', count(*)
        FROM clean.phones WHERE NOT regexp_full_match(phone, '0\\d{8,9}')
    """)
    show(con, "Links by pair type (T-H across banks, T-T / H-H duplicates in one bank)", """
        SELECT pair_type, entity_type, count(*) AS links
        FROM clean.customer_match_results GROUP BY ALL ORDER BY ALL
    """)
    show(con, "Customers by number of records", """
        SELECT n_records, count(*) AS customers
        FROM (SELECT cluster_id, count(*) AS n_records FROM clean.customer_clusters GROUP BY 1)
        GROUP BY ALL ORDER BY ALL
    """)
    con.execute(f"COPY (FROM clean.customer_match_results ORDER BY pair_type, match_score DESC) "
                f"TO '{OUTPUT / 'matches.csv'}' (HEADER)")
    show(con, "Golden records needing review", """
        SELECT reason, count(*) AS customers
        FROM (SELECT unnest(string_split(review_reasons, '; ')) AS reason
              FROM clean.golden_record WHERE review_reasons IS NOT NULL)
        GROUP BY ALL ORDER BY customers DESC
    """)
    con.execute(f"COPY (FROM clean.customer_clusters ORDER BY cluster_id, record_id) "
                f"TO '{OUTPUT / 'customers.csv'}' (HEADER)")
    con.execute(f"COPY clean.golden_record TO '{OUTPUT / 'golden_records.csv'}' (HEADER)")
    con.execute(f"COPY clean.golden_review TO '{OUTPUT / 'golden_review.csv'}' (HEADER)")
    print(f"\nWrote matches.csv, customers.csv, golden_records.csv, golden_review.csv to {OUTPUT}")

    if not answer_key.exists():
        print(f"\n{answer_key.name} not found - skipping evaluation. "
              "Export PUBLIC.BANK_MERGER_ANSWER_KEY to that path to get precision / recall / F1.")
        return

    con.execute("SET VARIABLE answer_key_path = ?", [str(answer_key)])
    run_sql(con, "finalResult.sql")

    threshold = con.sql("SELECT getvariable('match_threshold')").fetchone()[0]
    show(con, "Answer key coverage (ID checks should be 0)", "FROM clean.key_coverage")
    show(con, f"Pair metrics at threshold {threshold}", "FROM clean.match_metrics")
    show(con, f"Customer view at threshold {threshold}", "FROM clean.customer_metrics")
    show(con, "Threshold sweep", "FROM clean.threshold_sweep")
    show(con, "Best F1", "FROM clean.threshold_sweep ORDER BY f1 DESC, threshold LIMIT 1")

    con.execute(f"COPY clean.match_metrics TO '{OUTPUT / 'metrics.csv'}' (HEADER)")
    con.execute(f"COPY clean.threshold_sweep TO '{OUTPUT / 'threshold_sweep.csv'}' (HEADER)")
    con.execute(f"COPY (FROM clean.match_evaluation WHERE outcome <> 'TP' ORDER BY outcome, match_score DESC) "
                f"TO '{OUTPUT / 'errors.csv'}' (HEADER)")
    con.execute(f"COPY clean.same_bank_duplicates TO '{OUTPUT / 'same_bank_duplicates.csv'}' (HEADER)")
    print(f"\nWrote metrics.csv, threshold_sweep.csv, errors.csv, same_bank_duplicates.csv to {OUTPUT}")


if __name__ == "__main__":
    main()
