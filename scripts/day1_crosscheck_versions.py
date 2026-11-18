"""
day1_crosscheck_versions.py
---------------------------
Read-only cross-check of two downloads of the Berka data:

  data/raw/           the 'financial' version (the one we will analyse)
  data/archive_ijs/   the 'Financial_ijs' version downloaded earlier

For every table the two versions share, it checks that the same keys exist and
that every shared column holds the same values. For the client table it also
decodes the old raw birth_number (YYMMDD, month + 50 for women) and checks that
it reproduces the birth_date and gender columns of the 'financial' version.

Nothing is modified. Usage (project root, conda environment active):
    python scripts/day1_crosscheck_versions.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
NEW_DIR = ROOT / "data" / "raw"
OLD_DIR = ROOT / "data" / "archive_ijs"

# (table in 'financial', table in 'Financial_ijs', key column in 'financial').
# In 'Financial_ijs' every key column is called 'id'.
PAIRS = [
    ("account", "accounts", "account_id"),
    ("card", "cards", "card_id"),
    ("client", "clients", "client_id"),
    ("disp", "disps", "disp_id"),
    ("district", "districts", "district_id"),
    ("loan", "loans", "loan_id"),
    ("order", "orders", "order_id"),
    ("trans", "trans", "trans_id"),
]


def mismatches(a: pd.Series, b: pd.Series) -> int:
    """Count positions where two aligned columns differ (two blanks count as equal)."""
    both_blank = a.isna() & b.isna()
    if pd.api.types.is_numeric_dtype(a) and pd.api.types.is_numeric_dtype(b):
        equal = np.isclose(a.astype("float64"), b.astype("float64"))
    else:
        equal = a.astype(str) == b.astype(str)
    return int((~(equal | both_blank)).sum())


def check_birth_split(new: pd.DataFrame, old: pd.DataFrame) -> int:
    """Decode the old birth_number and compare with birth_date and gender. Returns problems found."""
    number = old["birth_number"].astype("int64")
    year, month_code, day = number // 10_000, (number // 100) % 100, number % 100
    female = month_code > 50
    month = month_code.where(~female, month_code - 50)
    decoded_date = pd.to_datetime(
        pd.DataFrame({"year": 1900 + year, "month": month, "day": day}), errors="coerce"
    )
    decoded_gender = pd.Series(np.where(female, "F", "M"), index=old.index)

    date_bad = int((decoded_date != pd.to_datetime(new["birth_date"])).sum())
    gender_bad = int((decoded_gender != new["gender"].astype(str)).sum())
    print(f"   birth_number decoded to birth_date: {date_bad:,} mismatches of {len(new):,}")
    print(f"   birth_number decoded to gender:     {gender_bad:,} mismatches of {len(new):,}")
    return date_bad + gender_bad


def compare_table(new_name: str, old_name: str, key: str) -> bool:
    new = pd.read_csv(NEW_DIR / f"{new_name}.csv", low_memory=False)
    old = pd.read_csv(OLD_DIR / f"{old_name}.csv", low_memory=False).rename(columns={"id": key})
    print(f"\n{new_name} (financial) vs {old_name} (Financial_ijs): {len(new):,} vs {len(old):,} rows")

    ok = len(new) == len(old)
    if not (new[key].is_unique and old[key].is_unique) or set(new[key]) != set(old[key]):
        print("   PROBLEM: the key values differ or are not unique")
        return False

    new = new.sort_values(key).reset_index(drop=True)
    old = old.sort_values(key).reset_index(drop=True)

    shared = [c for c in new.columns if c in old.columns]
    only_new = [c for c in new.columns if c not in old.columns]
    only_old = [c for c in old.columns if c not in new.columns]
    problems = {c: n for c in shared if (n := mismatches(new[c], old[c]))}

    print(f"   compared columns: {', '.join(shared)}")
    if only_new:
        print(f"   only in financial:     {', '.join(only_new)}")
    if only_old:
        print(f"   only in Financial_ijs: {', '.join(only_old)}")
    print(f"   columns with differing values: {problems if problems else 'none'}")

    if new_name == "client":
        ok = check_birth_split(new, old) == 0 and ok
    return ok and not problems


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass

    if not OLD_DIR.exists():
        sys.exit(f"{OLD_DIR} not found. Move the old Financial_ijs CSV files there first.")

    results = {new_name: compare_table(new_name, old_name, key) for new_name, old_name, key in PAIRS}

    print("\nSummary")
    for name, ok in results.items():
        print(f"   {name}: {'identical' if ok else 'DIFFERENCES FOUND'}")
    verdict = "all shared data is identical" if all(results.values()) else "differences found, see above"
    print(f"\nVerdict: {verdict}")


if __name__ == "__main__":
    main()
