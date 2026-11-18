"""
compare_versions.py
-------------------
Read-only comparison of the Financial (Berka) dataset versions on the public
CTU server.

The repository lists several versions of this dataset. Day 1 used
Financial_ijs, while the dataset page tells readers to export the "financial"
database. This script lists the tables, columns, row counts and declared
foreign keys of each version so we can decide which one to build on. It
downloads no data. It writes only reports/version_comparison.txt.

Connection handling: the public guest account is shared, so this script keeps
only ONE connection open at a time and retries a database once if the server
drops the connection.

Usage (from the project root, with the conda environment active):
    python scripts/compare_versions.py
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

from sqlalchemy import create_engine, inspect, text
from sqlalchemy.engine import URL
from sqlalchemy.pool import NullPool

HOST = os.getenv("BERKA_HOST", "relational.fel.cvut.cz")
PORT = int(os.getenv("BERKA_PORT", "3306"))
USER = os.getenv("BERKA_USER", "guest")
PASSWORD = os.getenv("BERKA_PASSWORD", "ctu-relational")

CANDIDATES = ["financial", "Financial_ijs", "Financial_std", "ctu_financial"]
REPORT_PATH = Path(__file__).resolve().parents[1] / "reports" / "version_comparison.txt"

lines: list[str] = []


def out(message: object = "") -> None:
    """Print to the console and keep a copy for the report file."""
    print(message)
    lines.append(str(message))


def make_engine(database: str | None = None):
    url = URL.create(
        "mysql+pymysql",
        username=USER,
        password=PASSWORD,
        host=HOST,
        port=PORT,
        database=database,
    )
    # NullPool closes each connection as soon as it is released, so we never
    # keep idle connections open on the shared guest account.
    return create_engine(url, poolclass=NullPool, connect_args={"connect_timeout": 20})


def describe(db_name: str) -> list[str]:
    """Return report lines for one database. Uses a single connection throughout."""
    report = ["", "=" * 72, db_name, "=" * 72]
    engine = make_engine(db_name)
    try:
        with engine.connect() as conn:
            inspector = inspect(conn)  # reuse the same connection for metadata
            total_rows = 0
            for table in sorted(inspector.get_table_names()):
                quoted = engine.dialect.identifier_preparer.quote(table)
                n_rows = conn.execute(text(f"SELECT COUNT(*) FROM {quoted}")).scalar_one()
                total_rows += n_rows
                columns = ", ".join(c["name"] for c in inspector.get_columns(table))
                n_fk = len(inspector.get_foreign_keys(table))
                report.append(f"{table}: {n_rows:,} rows, {n_fk} declared foreign keys")
                report.append(f"    columns: {columns}")
            report.append(f"TOTAL rows in {db_name}: {total_rows:,}")
    finally:
        engine.dispose()
    return report


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass

    engine = make_engine()
    try:
        with engine.connect() as conn:
            names = [row[0] for row in conn.execute(text("SHOW DATABASES"))]
    finally:
        engine.dispose()

    out("Databases on the server whose name contains 'financ' (names are case sensitive):")
    out("    " + (", ".join(n for n in names if "financ" in n.lower()) or "none"))

    for candidate in CANDIDATES:
        if candidate not in names:  # exact match: names are case sensitive
            out(f"\n'{candidate}' was not found on the server.")
            continue
        for attempt in (1, 2):
            try:
                for line in describe(candidate):
                    out(line)
                break
            except Exception as exc:  # keep going so one failure does not lose the report
                message = f"{type(exc).__name__}: {str(exc)[:200]}"
                if attempt == 1:
                    print(f"  '{candidate}' failed ({message}); retrying in 3 seconds...")
                    time.sleep(3)
                else:
                    out(f"\nCould not read '{candidate}' after 2 attempts: {message}")
        time.sleep(1)  # be gentle with the shared server

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"\nReport saved to {REPORT_PATH}")


if __name__ == "__main__":
    main()
