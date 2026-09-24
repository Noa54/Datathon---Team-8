"""Run the Kendrix entity-resolution pipeline on Snowflake.

Usage:
    .venv/bin/pip install -r snowflake/requirements.txt
    .venv/bin/python snowflake/run_snowflake.py [connection_name]

connection_name is a section of ~/.snowflake/connections.toml (default: "default"). The
connection needs a warehouse and a role that can read BANK.PUBLIC and create the CLEAN schema.

Runs the four SQL files in this folder, prints the same checks as run_local.py and
downloads the result tables to output/snowflake/, next to the local results in output/.
"""

import csv
import sys
from pathlib import Path

import snowflake.connector

HERE = Path(__file__).resolve().parent
OUTPUT = HERE.parent / "output" / "snowflake"

EXPORTS = {
    "matches.csv": "SELECT * FROM clean.customer_match_results ORDER BY pair_type, match_score DESC, record_a, record_b",
    "customers.csv": "SELECT * FROM clean.customer_clusters ORDER BY cluster_id, record_id",
    "golden_records.csv": "SELECT * FROM clean.golden_record ORDER BY customer_key",
    "golden_review.csv": "SELECT * FROM clean.golden_review "
                         "ORDER BY review_reasons, customer_key, used_for NULLS LAST, record_id",
    "metrics.csv": "SELECT * FROM clean.match_metrics",
    "threshold_sweep.csv": "SELECT * FROM clean.threshold_sweep ORDER BY threshold",
    "errors.csv": "SELECT * FROM clean.match_evaluation WHERE outcome <> 'TP' ORDER BY outcome, match_score DESC",
    "same_bank_duplicates.csv": "SELECT * FROM clean.same_bank_duplicates "
                                "ORDER BY bank DESC, true_entity_id, customer_id",
}


def run_sql(con, name):
    print(f"-- running snowflake/{name}")
    for cur in con.execute_string((HERE / name).read_text(), remove_comments=True):
        cur.close()


def fmt(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


def show(con, title, query):
    cur = con.cursor().execute(query)
    header = [c[0].lower() for c in cur.description]
    rows = [[fmt(v) for v in row] for row in cur.fetchall()]
    widths = [max(len(x) for x in col) for col in zip(header, *rows)]
    print(f"\n== {title}")
    for row in [header, *rows]:
        print("  ".join(x.ljust(w) for x, w in zip(row, widths)))


def export(con, filename, query):
    cur = con.cursor().execute(query)
    with open(OUTPUT / filename, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(c[0].lower() for c in cur.description)
        writer.writerows([fmt(v) for v in row] for row in cur)


def main():
    connection_name = sys.argv[1] if len(sys.argv) > 1 else "default"
    OUTPUT.mkdir(parents=True, exist_ok=True)

    with snowflake.connector.connect(connection_name=connection_name) as con:
        for name in ["clean.sql", "fetureEngineer.sql", "goldenRecord.sql", "finalResult.sql"]:
            run_sql(con, name)

        threshold = con.cursor().execute("SELECT $match_threshold").fetchone()[0]
        show(con, "Row counts", """
            SELECT 'clean.totara' AS tbl, COUNT(*) AS n FROM clean.totara
            UNION ALL SELECT 'clean.harbourside', COUNT(*) FROM clean.harbourside
            UNION ALL SELECT 'clean.customer_match_features (pairs scored)', COUNT(*) FROM clean.customer_match_features
            UNION ALL SELECT 'clean.customer_match_results (links)', COUNT(*) FROM clean.customer_match_results
            UNION ALL SELECT 'customers (clusters)', COUNT(DISTINCT cluster_id) FROM clean.customer_clusters
            UNION ALL SELECT 'clean.golden_record', COUNT(*) FROM clean.golden_record
        """)
        show(con, "Sanity checks (all should be 0)", r"""
            SELECT 'Totara DOB present but unparsed' AS check_name, COUNT(*) AS n
            FROM clean.raw_totara r JOIN clean.totara t ON t.customer_id = r.CUST_NO
            WHERE r.DOB IS NOT NULL AND t.dob IS NULL
            UNION ALL
            SELECT 'Harbourside DOB present but unparsed', COUNT(*)
            FROM clean.raw_harbourside r JOIN clean.harbourside h ON h.customer_id = r.customer_id
            WHERE r.date_of_birth IS NOT NULL AND h.dob IS NULL
            UNION ALL
            SELECT 'phones not 0 + 8-9 digits', COUNT(*)
            FROM clean.phones WHERE NOT RLIKE(phone, '0[0-9]{8,9}')
        """)
        show(con, "Links by pair type (T-H across banks, T-T / H-H duplicates in one bank)", """
            SELECT pair_type, entity_type, COUNT(*) AS links
            FROM clean.customer_match_results GROUP BY 1, 2 ORDER BY 1, 2
        """)
        show(con, "Golden records needing review", """
            SELECT TRIM(f.value::VARCHAR) AS reason, COUNT(*) AS customers
            FROM clean.golden_record g, LATERAL FLATTEN(input => SPLIT(g.review_reasons, ';')) f
            GROUP BY 1 ORDER BY 2 DESC
        """)
        show(con, "Answer key coverage (ID checks should be 0)", "SELECT * FROM clean.key_coverage")
        show(con, f"Pair metrics at threshold {threshold}", "SELECT * FROM clean.match_metrics")
        show(con, f"Customer view at threshold {threshold}", "SELECT * FROM clean.customer_metrics")
        show(con, "Threshold sweep", "SELECT * FROM clean.threshold_sweep ORDER BY threshold")

        for filename, query in EXPORTS.items():
            export(con, filename, query)
        print(f"\nWrote {', '.join(EXPORTS)} to {OUTPUT}")


if __name__ == "__main__":
    main()
