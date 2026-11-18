"""
download_berka.py
-----------------
Download every table of one version of the Berka (PKDD'99 Financial) dataset
from the public CTU Prague Relational Learning Repository and save each table
as a CSV file in data/raw/.

By default it downloads the 'financial' database, the version the dataset page
tells readers to export.

What this script does
  1. Connects to the public, read-only MariaDB server (one connection at a time).
  2. Finds the requested database (database names are case sensitive).
  3. Counts the rows in every table, streams each table to CSV in chunks
     (keeps RAM low) and checks that rows written == rows counted.
  4. Writes data/raw/_download_manifest.csv with the counts and a timestamp.

Existing raw files are never overwritten unless you pass --force.

Usage (from the project root, with the conda environment active):
    python scripts/download_berka.py
    python scripts/download_berka.py --database ctu_financial
    python scripts/download_berka.py --force      # re-download and overwrite
"""
from __future__ import annotations

import argparse
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import URL
from sqlalchemy.pool import NullPool

# Connection details come from the repository's public download instructions.
# Override with environment variables if they ever change.
HOST = os.getenv("BERKA_HOST", "relational.fel.cvut.cz")
PORT = int(os.getenv("BERKA_PORT", "3306"))
USER = os.getenv("BERKA_USER", "guest")
PASSWORD = os.getenv("BERKA_PASSWORD", "ctu-relational")
DEFAULT_DATABASE = "financial"

CHUNK_ROWS = 100_000
RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"


def make_engine(database: str | None = None):
    url = URL.create(
        "mysql+pymysql",
        username=USER,
        password=PASSWORD,
        host=HOST,
        port=PORT,
        database=database,
    )
    # NullPool closes each connection as soon as it is released, so only one
    # connection is open at a time on the shared public guest account.
    return create_engine(url, poolclass=NullPool, connect_args={"connect_timeout": 20})


def find_database(requested: str) -> str:
    """Return the exact database name on the server, or exit with a clear message."""
    engine = make_engine()
    try:
        with engine.connect() as conn:
            names = [row[0] for row in conn.execute(text("SHOW DATABASES"))]
    finally:
        engine.dispose()

    if requested in names:  # names are case sensitive: prefer an exact match
        return requested
    matches = [n for n in names if n.lower() == requested.lower()]
    if len(matches) == 1:
        return matches[0]

    candidates = [n for n in names if "fin" in n.lower()]
    print(f"Database '{requested}' was not found on {HOST}.")
    print("Databases containing 'fin':", candidates or "none")
    print("Use --database with one of the names above.")
    sys.exit(1)


def download_table(engine, table: str, database: str) -> dict:
    """Stream one table to data/raw/<table>.csv and validate the row count."""
    quoted = engine.dialect.identifier_preparer.quote(table)
    out_path = RAW_DIR / f"{table}.csv"

    with engine.connect() as meta_conn:  # short-lived connection for metadata
        columns = [c["name"] for c in inspect(meta_conn).get_columns(table)]

    try:
        with engine.connect().execution_options(stream_results=True) as conn:
            expected = conn.execute(text(f"SELECT COUNT(*) FROM {quoted}")).scalar_one()

            # Write the header first so even an empty table produces a valid CSV.
            pd.DataFrame(columns=columns).to_csv(out_path, index=False)

            written = 0
            query = text(f"SELECT * FROM {quoted}")
            for chunk in pd.read_sql(query, conn, chunksize=CHUNK_ROWS):
                chunk.to_csv(out_path, mode="a", header=False, index=False)
                written += len(chunk)

        if written != expected:
            raise RuntimeError(
                f"Row count mismatch for '{table}': server={expected}, written={written}"
            )
    except Exception:
        out_path.unlink(missing_ok=True)  # never leave a half-written raw file
        raise

    return {
        "database": database,
        "table": table,
        "rows_expected": expected,
        "rows_written": written,
        "n_columns": len(columns),
        "columns": ", ".join(columns),
        "downloaded_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download one version of the Berka dataset to data/raw as CSV files."
    )
    parser.add_argument(
        "--database",
        default=DEFAULT_DATABASE,
        help=f"database name on the server (default: {DEFAULT_DATABASE})",
    )
    parser.add_argument("--force", action="store_true", help="overwrite existing CSV files")
    args = parser.parse_args()

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    db_name = find_database(args.database)
    print(f"Using database '{db_name}' on {HOST}")

    engine = make_engine(db_name)
    with engine.connect() as conn:
        tables = sorted(inspect(conn).get_table_names())
    if not tables:
        sys.exit("No tables found - check the database name.")

    existing = [t for t in tables if (RAW_DIR / f"{t}.csv").exists()]
    if existing and not args.force:
        sys.exit(
            f"These files already exist in {RAW_DIR}: {existing}\n"
            "Raw files are not overwritten by default. Move them away or use --force."
        )

    manifest = []
    for table in tables:
        print(f"Downloading {table} ...", end=" ", flush=True)
        info = download_table(engine, table, db_name)
        print(f"{info['rows_written']:,} rows")
        manifest.append(info)

    manifest_df = pd.DataFrame(manifest)
    manifest_df.to_csv(RAW_DIR / "_download_manifest.csv", index=False)

    print("\nSummary")
    print(
        manifest_df[["table", "rows_expected", "rows_written", "n_columns"]].to_string(
            index=False
        )
    )
    print(f"\nFiles saved to {RAW_DIR}")


if __name__ == "__main__":
    main()
