"""
load_to_mysql.py
----------------
Create the MySQL schema (sql/00_create_schema.sql), load the clean CSV files
from data/processed/ and validate the database against totals calculated
independently with pandas.

Connection settings are read from environment variables or from a .env file
in the project root (the .env file is git-ignored; copy .env.example):

    MYSQL_HOST       default 127.0.0.1
    MYSQL_PORT       default 3306
    MYSQL_USER       required
    MYSQL_PASSWORD   required

Usage (from the project root, with the conda environment active):
    python scripts/load_to_mysql.py                 # rebuild the schema, load everything, validate
    python scripts/load_to_mysql.py --skip-schema   # only re-run the validation on a loaded database

Loading always starts from empty tables (the schema script drops and recreates them).
Writes reports/mysql_load_validation.csv (counts and totals only).
"""
from __future__ import annotations

import argparse
import datetime
import os
import sys
import time
from pathlib import Path

import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.engine import URL

ROOT = Path(__file__).resolve().parents[1]
PROCESSED = ROOT / "data" / "processed"
REPORTS = ROOT / "reports"
SCHEMA_FILE = ROOT / "sql" / "00_create_schema.sql"
DATABASE = "banking_analytics"

# (MySQL table, CSV file, columns renamed on load, CSV date columns). Parents come before children.
TABLES = [
    ("district", "district_clean", {}, []),
    ("client", "client_clean", {}, []),
    ("account", "account_clean", {}, ["opened_date"]),
    ("disp", "disp_clean", {}, []),
    ("card", "card_clean", {}, ["issued"]),
    ("loan", "loan_clean", {"date": "loan_date"}, ["date", "end_date", "first_negative_date"]),
    ("standing_order", "order_clean", {}, []),
    (
        "transactions",
        "trans_clean",
        {"date": "trans_date", "year": "trans_year", "month": "trans_month", "year_month": "period"},
        ["date", "month_start"],
    ),
]


def load_env_file(path: Path) -> None:
    """Read KEY=VALUE lines into the environment (existing variables win)."""
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def make_engine(database: str | None):
    user = os.getenv("MYSQL_USER")
    if not user:
        sys.exit("MYSQL_USER is not set. Copy .env.example to .env and fill it in.")
    url = URL.create(
        "mysql+pymysql",
        username=user,
        password=os.getenv("MYSQL_PASSWORD", ""),
        host=os.getenv("MYSQL_HOST", "127.0.0.1"),
        port=int(os.getenv("MYSQL_PORT", "3306")),
        database=database,
    )
    return create_engine(url, connect_args={"connect_timeout": 20})


def read_statements(path: Path) -> list[str]:
    """Split a SQL file into statements (full-line comments are dropped)."""
    lines = [ln for ln in path.read_text(encoding="utf-8").splitlines() if not ln.strip().startswith("--")]
    return [s.strip() for s in "\n".join(lines).split(";") if s.strip()]


def run_schema() -> None:
    boot = make_engine(None)
    with boot.connect() as conn:  # make sure the database exists before connecting to it
        conn.execute(text(f"CREATE DATABASE IF NOT EXISTS {DATABASE} DEFAULT CHARACTER SET utf8mb4"))
        conn.commit()
    boot.dispose()

    engine = make_engine(DATABASE)
    statements = read_statements(SCHEMA_FILE)
    with engine.connect() as conn:  # one connection: SET SESSION must apply to the INSERT that follows
        for statement in statements:
            conn.execute(text(statement))
        conn.commit()
    engine.dispose()
    print(f"Schema created from {SCHEMA_FILE.name} ({len(statements)} statements).")


def read_csv(csv_name: str, date_cols: list[str], rename: dict[str, str]) -> pd.DataFrame:
    path = PROCESSED / f"{csv_name}.csv"
    if not path.exists():
        sys.exit(f"Missing {path}. Run notebooks/02_data_cleaning.ipynb first.")
    # Only empty cells are NULL; a single space stays a space.
    df = pd.read_csv(path, keep_default_na=False, na_values=[""], parse_dates=date_cols, low_memory=False)
    for col in date_cols:
        df[col] = df[col].dt.date
    if csv_name == "trans_clean":
        df["partner_account"] = df["partner_account"].astype("Int64")
    return df.rename(columns=rename)


def check_columns(engine, table: str, df: pd.DataFrame) -> None:
    query = text("SELECT column_name FROM information_schema.columns WHERE table_schema = :db AND table_name = :t")
    with engine.connect() as conn:
        table_cols = {row[0].lower() for row in conn.execute(query, {"db": DATABASE, "t": table})}
    csv_cols = {c.lower() for c in df.columns}
    if table_cols != csv_cols:
        sys.exit(
            f"Column mismatch for {table}:\n  only in the CSV:   {sorted(csv_cols - table_cols)}"
            f"\n  only in the table: {sorted(table_cols - csv_cols)}"
        )


def insert_frame(engine, table: str, df: pd.DataFrame, chunk: int = 50_000) -> None:
    start_time = time.time()
    for start in range(0, len(df), chunk):
        df.iloc[start:start + chunk].to_sql(table, engine, if_exists="append", index=False)
        done = min(start + chunk, len(df))
        print(f"   {table}: {done:,} / {len(df):,} rows ({time.time() - start_time:,.0f}s)", end="\r", flush=True)
    print(f"   {table}: {len(df):,} rows loaded in {time.time() - start_time:,.0f}s" + " " * 20)


def validate(engine, frames: dict[str, pd.DataFrame]) -> pd.DataFrame:
    """Compare MySQL with totals calculated independently from the CSV data in pandas."""
    results = []

    def add(metric, python_value, mysql_value):
        if isinstance(python_value, (str, datetime.date)) or isinstance(mysql_value, (str, datetime.date)):
            ok = str(python_value) == str(mysql_value)
        else:
            ok = abs(float(python_value) - float(mysql_value)) < 1e-6
        results.append({"metric": metric, "pandas": python_value, "mysql": mysql_value, "match": ok})

    with engine.connect() as conn:
        for table, df in frames.items():
            add(f"{table}: row count", len(df), conn.execute(text(f"SELECT COUNT(*) FROM {table}")).scalar_one())

        trans = frames["transactions"]
        by_type = conn.execute(text("SELECT type, COUNT(*), SUM(amount) FROM transactions GROUP BY type")).all()
        expected = trans.groupby("type")["amount"].agg(["size", "sum"])
        for type_code, rows, total in by_type:
            add(f"transactions type {type_code}: row count", expected.loc[type_code, "size"], rows)
            add(f"transactions type {type_code}: sum of amount", expected.loc[type_code, "sum"], total)

        add("transactions: sum of signed_amount", trans["signed_amount"].sum(),
            conn.execute(text("SELECT SUM(signed_amount) FROM transactions")).scalar_one())
        add("transactions: distinct accounts", trans["account_id"].nunique(),
            conn.execute(text("SELECT COUNT(DISTINCT account_id) FROM transactions")).scalar_one())
        add("transactions: negative-balance rows", int(trans["is_negative_balance"].sum()),
            conn.execute(text("SELECT SUM(is_negative_balance) FROM transactions")).scalar_one())
        first_last = conn.execute(text("SELECT MIN(trans_date), MAX(trans_date) FROM transactions")).one()
        add("transactions: first date", trans["trans_date"].min(), first_last[0])
        add("transactions: last date", trans["trans_date"].max(), first_last[1])

        categories = dict(conn.execute(text("SELECT transaction_category, COUNT(*) FROM transactions GROUP BY 1")).all())
        for category, rows in trans["transaction_category"].value_counts().items():
            add(f"transactions category {category}: row count", rows, categories.get(category, 0))

        add("dim_date: days", 2191, conn.execute(text("SELECT COUNT(*) FROM dim_date")).scalar_one())
        add("loan: sum of amount", frames["loan"]["amount"].sum(),
            conn.execute(text("SELECT SUM(amount) FROM loan")).scalar_one())

    return pd.DataFrame(results)


def main() -> None:
    parser = argparse.ArgumentParser(description="Create the MySQL schema, load the clean data and validate it.")
    parser.add_argument("--skip-schema", action="store_true", help="do not rebuild or reload anything; only re-run the validation")
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    load_env_file(ROOT / ".env")

    frames = {table: read_csv(csv, dates, rename) for table, csv, rename, dates in TABLES}

    if not args.skip_schema:
        run_schema()
    engine = make_engine(DATABASE)

    if not args.skip_schema:
        for table, _, _, _ in TABLES:
            check_columns(engine, table, frames[table])
            insert_frame(engine, table, frames[table])

    report = validate(engine, frames)
    REPORTS.mkdir(exist_ok=True)
    report.to_csv(REPORTS / "mysql_load_validation.csv", index=False)
    print()
    print(report.to_string(index=False))
    if not report["match"].all():
        sys.exit("\nVALIDATION FAILED: MySQL does not match the pandas totals (see the table above).")
    print(f"\nValidation passed: {len(report)} comparisons match. Report: reports/mysql_load_validation.csv")


if __name__ == "__main__":
    main()
