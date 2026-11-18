"""
day1_inspect.py
---------------
Read-only inspection of the raw Berka CSV files for the Day 1 checkpoint.

For every table it reports: shape, column types, null and distinct counts,
a 3-row sample, date ranges, duplicate checks, small categorical value counts
and numeric summaries. It then checks key relationships between tables.
Nothing in data/raw is modified.

The full report is also saved to reports/day1_inspection.txt. Keep that file
local: it contains sample rows from the dataset, so it is git-ignored.

Usage (from the project root, with the conda environment active):
    python scripts/day1_inspect.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "data" / "raw"
REPORT_PATH = PROJECT_ROOT / "reports" / "day1_inspection.txt"

pd.set_option("display.width", 200)
pd.set_option("display.max_columns", 30)

lines: list[str] = []


def out(text: object = "") -> None:
    """Print to the console and keep a copy for the report file."""
    print(text)
    lines.append(str(text))


def section(title: str) -> None:
    out("\n" + "=" * 72)
    out(title)
    out("=" * 72)


def profile_table(name: str, df: pd.DataFrame) -> None:
    section(f"{name}: {df.shape[0]:,} rows x {df.shape[1]} columns")

    summary = pd.DataFrame(
        {
            "dtype": df.dtypes.astype(str),
            "nulls": df.isna().sum(),
            "distinct": df.nunique(),
        }
    )
    out(summary.to_string())

    out("\nSample (first 3 rows):")
    out(df.head(3).to_string(index=False))

    # The first column is assumed to be the table's own ID. We only report
    # whether it is unique; we do not drop or change anything.
    first_col = df.columns[0]
    out(f"\nFirst column '{first_col}' is unique: {df[first_col].is_unique}")
    out(f"Fully duplicated rows: {int(df.duplicated().sum()):,}")

    # Date-like columns: report the range and how many values cannot be parsed.
    for col in df.columns:
        if "date" in col.lower() or col.lower() == "issued":
            if pd.api.types.is_numeric_dtype(df[col]):
                out(f"\n'{col}' is numeric (raw min={df[col].min()}, max={df[col].max()}); check its format.")
                continue
            parsed = pd.to_datetime(df[col], errors="coerce")
            unparseable = int(parsed.isna().sum() - df[col].isna().sum())
            out(
                f"\nDate range for '{col}': {parsed.min()} to {parsed.max()} "
                f"(unparseable values: {unparseable:,})"
            )

    # Small categorical columns: show every value with its count.
    for col in df.select_dtypes(include=["object", "string"]).columns:
        if df[col].nunique(dropna=True) <= 15:
            out(f"\nValues in '{col}':")
            out(df[col].value_counts(dropna=False).to_string())

    numeric = df.select_dtypes(include="number")
    numeric = numeric.drop(columns=[c for c in numeric.columns if c.lower().endswith("_id")])
    if not numeric.empty:
        out("\nNumeric summary (ID columns excluded):")
        out(numeric.describe().T.to_string())


def check_relationships(tables: dict[str, pd.DataFrame]) -> None:
    """For each '*_id' column that is the first (key) column of some table,
    count how many rows in other tables point to a key that does not exist."""
    section("Key relationships (matched on column names ending in '_id')")

    parents = {
        df.columns[0]: name
        for name, df in tables.items()
        if df.columns[0].lower().endswith("_id") and df[df.columns[0]].is_unique
    }

    for child_name, child in tables.items():
        for col in child.columns:
            parent_name = parents.get(col)
            if parent_name is None or parent_name == child_name:
                continue
            parent_keys = set(tables[parent_name][col].dropna())
            values = child[col].dropna()
            orphans = int((~values.isin(parent_keys)).sum())
            out(
                f"{child_name}.{col} -> {parent_name}.{col}: "
                f"{orphans:,} of {len(values):,} rows with no match"
            )


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # safe printing of any non-ASCII text
    except AttributeError:
        pass

    files = sorted(p for p in RAW_DIR.glob("*.csv") if not p.name.startswith("_"))
    if not files:
        sys.exit(f"No CSV files found in {RAW_DIR}. Run scripts/download_berka.py first.")

    tables = {path.stem: pd.read_csv(path, low_memory=False) for path in files}

    for name, df in tables.items():
        profile_table(name, df)
    check_relationships(tables)

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"\nReport saved to {REPORT_PATH}")


if __name__ == "__main__":
    main()
