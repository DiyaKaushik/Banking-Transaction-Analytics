"""
day1_diff_details.py
--------------------
Read-only follow-up to day1_crosscheck_versions.py. It shows exactly HOW the
'financial' download (data/raw) and the 'Financial_ijs' download
(data/archive_ijs) differ in the columns the cross-check flagged:

  trans     k_symbol, bank, account
  district  A10, A12, A13
  order     amount

It also profiles blanks, whitespace-only values and zeros in the 'financial'
version of the affected trans columns. Values are printed with repr() so that
a blank string, a single space and a missing value look different.

Usage (from the project root, with the conda environment active):
    python scripts/day1_diff_details.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
NEW_DIR = ROOT / "data" / "raw"
OLD_DIR = ROOT / "data" / "archive_ijs"


def differs(a: pd.Series, b: pd.Series) -> pd.Series:
    """True where two aligned columns differ (two missing values count as equal)."""
    both_blank = a.isna() & b.isna()
    if pd.api.types.is_numeric_dtype(a) and pd.api.types.is_numeric_dtype(b):
        equal = pd.Series(np.isclose(a.astype("float64"), b.astype("float64")), index=a.index)
    else:
        equal = a.astype(str) == b.astype(str)
    return ~(equal | both_blank)


def aligned(new_file: str, old_file: str, key: str, cols: list[str]) -> pd.DataFrame:
    """Join the two versions on the key, reading only the columns we need."""
    new = pd.read_csv(NEW_DIR / new_file, usecols=[key] + cols, low_memory=False)
    old = pd.read_csv(OLD_DIR / old_file, usecols=["id"] + cols, low_memory=False)
    old = old.rename(columns={"id": key})
    return new.merge(old, on=key, suffixes=("_fin", "_ijs"))


def pair_summary(m: pd.DataFrame, col: str, top: int = 12) -> None:
    mask = differs(m[f"{col}_fin"], m[f"{col}_ijs"])
    d = m.loc[mask, [f"{col}_fin", f"{col}_ijs"]]
    print(f"\n{col}: {len(d):,} differing rows")
    if d.empty:
        return
    pairs = d.groupby([f"{col}_fin", f"{col}_ijs"], dropna=False).size().sort_values(ascending=False)
    print(f"   {len(pairs):,} distinct (financial, Financial_ijs) value pairs; top {min(top, len(pairs))}:")
    for (fin, ijs), n in pairs.head(top).items():
        print(f"   financial={fin!r:<16} Financial_ijs={ijs!r:<16} rows={n:,}")


def blank_profile(df: pd.DataFrame, col: str) -> None:
    s = df[col]
    n_missing = int(s.isna().sum())
    if pd.api.types.is_numeric_dtype(s):
        print(f"   {col}: missing={n_missing:,}, zeros={int((s == 0).sum()):,}")
        return
    whitespace_only = int(s.dropna().astype(str).str.strip().eq("").sum())
    print(f"   {col}: missing={n_missing:,}, blank or whitespace-only={whitespace_only:,}")
    counts = s.value_counts(dropna=False)
    if len(counts) <= 15:
        for value, n in counts.items():
            print(f"        {value!r}: {n:,}")


def numeric_diff(new_file: str, old_file: str, key: str, table: str, cols: list[str]) -> None:
    m = aligned(new_file, old_file, key, cols)
    for col in cols:
        mask = differs(m[f"{col}_fin"], m[f"{col}_ijs"])
        d = m.loc[mask, [key, f"{col}_fin", f"{col}_ijs"]]
        print(f"\n{table}.{col}: {len(d):,} differing rows of {len(m):,}")
        if d.empty:
            continue
        diff = (d[f"{col}_fin"] - d[f"{col}_ijs"]).abs()
        print(
            f"   absolute difference: min={diff.min():.3f}, "
            f"median={diff.median():.3f}, max={diff.max():.3f}"
        )
        fin, ijs = d[f"{col}_fin"], d[f"{col}_ijs"]
        rounded = np.isclose(ijs, np.round(fin)) | np.isclose(ijs, np.floor(fin + 0.5))
        print(
            f"   Financial_ijs equals the financial value rounded to a whole number "
            f"in {int(rounded.sum()):,} of these rows"
        )
        print(d.head(6).to_string(index=False))


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    if not OLD_DIR.exists():
        sys.exit(f"{OLD_DIR} not found. Move the old Financial_ijs CSV files there first.")

    print("=" * 72)
    print("trans: how k_symbol, bank and account differ")
    print("=" * 72)
    m = aligned("trans.csv", "trans.csv", "trans_id", ["k_symbol", "bank", "account"])
    for col in ["k_symbol", "bank", "account"]:
        pair_summary(m, col)

    bank_rows = m[differs(m["bank_fin"], m["bank_ijs"])]
    combos = bank_rows.groupby(
        ["bank_fin", "account_fin", "bank_ijs", "account_ijs"], dropna=False
    ).size().sort_values(ascending=False)
    print(f"\nRows where bank differs: {len(bank_rows):,} ({len(combos):,} distinct bank/account combinations)")
    for (bank_f, acc_f, bank_i, acc_i), n in combos.head(8).items():
        print(
            f"   financial: bank={bank_f!r}, account={acc_f!r}   |   "
            f"Financial_ijs: bank={bank_i!r}, account={acc_i!r}   rows={n:,}"
        )
    del m, bank_rows, combos

    print("\n" + "=" * 72)
    print("trans (financial version only): blanks, whitespace-only values and zeros")
    print("=" * 72)
    trans = pd.read_csv(
        NEW_DIR / "trans.csv",
        usecols=["trans_id", "type", "operation", "k_symbol", "bank", "account"],
        low_memory=False,
    )
    for col in ["type", "operation", "k_symbol", "bank", "account"]:
        blank_profile(trans, col)

    print("\n" + "=" * 72)
    print("district and order: numeric differences")
    print("=" * 72)
    numeric_diff("district.csv", "districts.csv", "district_id", "district", ["A10", "A12", "A13"])
    numeric_diff("order.csv", "orders.csv", "order_id", "order", ["amount"])


if __name__ == "__main__":
    main()
