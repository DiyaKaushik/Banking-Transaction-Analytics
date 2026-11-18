"""
day1_relationships.py
---------------------
Read-only check of the key relationships and a few integrity rules in the raw
'financial' tables (account, card, client, disp, district, loan, order, trans).

Usage (from the project root, with the conda environment active):
    python scripts/day1_relationships.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"

# (child table, foreign-key column, parent table). The parent key is '<parent>_id'.
RELATIONSHIPS = [
    ("account", "district_id", "district"),
    ("client", "district_id", "district"),
    ("disp", "client_id", "client"),
    ("disp", "account_id", "account"),
    ("card", "disp_id", "disp"),
    ("loan", "account_id", "account"),
    ("order", "account_id", "account"),
    ("trans", "account_id", "account"),
]


def load(name: str, usecols: list[str] | None = None) -> pd.DataFrame:
    path = RAW_DIR / f"{name}.csv"
    if not path.exists():
        sys.exit(f"Missing {path}. Run scripts/download_berka.py first.")
    return pd.read_csv(path, usecols=usecols, low_memory=False)


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass

    names = ["account", "card", "client", "disp", "district", "loan", "order"]
    tables = {name: load(name) for name in names}
    tables["trans"] = load("trans", usecols=["trans_id", "account_id", "date"])  # keep RAM low

    # 1. Foreign keys -------------------------------------------------------
    print("1. Foreign keys (rows whose key has no parent row; blank keys are skipped)")
    for child, col, parent in RELATIONSHIPS:
        series = tables[child][col]
        values = series.dropna()
        unmatched = int((~values.isin(tables[parent][f"{parent}_id"])).sum())
        print(
            f"   {child}.{col} -> {parent}.{parent}_id: "
            f"{unmatched:,} unmatched of {len(values):,} (blank: {int(series.isna().sum()):,})"
        )

    # 2. Ownership structure -----------------------------------------------
    account = tables["account"]
    disp = tables["disp"]
    owners = disp[disp["type"] == "OWNER"].groupby("account_id").size()
    print("\n2. OWNER dispositions per account (expected: exactly 1 for every account)")
    print(owners.value_counts().rename_axis("owners_per_account").to_string())
    print(f"   accounts without an owner: {int((~account['account_id'].isin(owners.index)).sum()):,}")
    print(f"   max dispositions for a single client: {int(disp.groupby('client_id').size().max())}")

    # 3. Accounts with no transactions -------------------------------------
    trans = tables["trans"]
    no_trans = int((~account["account_id"].isin(trans["account_id"])).sum())
    print(f"\n3. Accounts with no transactions: {no_trans:,}")

    # 4. Transactions dated before the account was opened -------------------
    opened = pd.to_datetime(account.set_index("account_id")["date"])
    before = pd.to_datetime(trans["date"]) < trans["account_id"].map(opened)
    print(f"\n4. Transactions dated before their account was opened: {int(before.sum()):,}")

    # 5. Client demographics (already split into gender and birth_date) ------
    client = tables["client"]
    birth = pd.to_datetime(client["birth_date"], errors="coerce")
    unparseable = int(birth.isna().sum() - client["birth_date"].isna().sum())
    print("\n5. Client gender and birth_date")
    print(client["gender"].value_counts(dropna=False).to_string())
    print(f"   birth_date range: {birth.min().date()} to {birth.max().date()} (unparseable: {unparseable:,})")


if __name__ == "__main__":
    main()
