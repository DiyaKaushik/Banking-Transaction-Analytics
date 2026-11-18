"""
validate_sql.py
---------------
Runs the named queries in a SQL file (queries start with a line "-- @query NAME")
and checks MySQL against numbers calculated independently with pandas from the
RAW csv files. This is how we prove the SQL results are right.

Usage (project root, conda environment active, MySQL loaded):
    python scripts/validate_sql.py                      # compare the 'scoreboard' query with pandas
    python scripts/validate_sql.py --show NAME          # print the result of one named query
    python scripts/validate_sql.py --smoke              # run every query, report rows and timing
    python scripts/validate_sql.py --file sql/02_transaction_kpis.sql   (or 01_..., 03_..., 04_...)

Connection settings come from .env (see load_to_mysql.py). Writes
reports/sql_validation_<file>.csv (counts only).
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sqlalchemy import text

sys.path.insert(0, str(Path(__file__).resolve().parent))
from load_to_mysql import DATABASE, ROOT, load_env_file, make_engine  # noqa: E402

MARKER = "-- @query "
DEFAULT_FILE = ROOT / "sql" / "01_data_quality_checks.sql"
RAW = ROOT / "data" / "raw"
PROCESSED = ROOT / "data" / "processed"
REPORTS = ROOT / "reports"


# ----------------------------------------------------------------------------
# Reading and running the named queries
# ----------------------------------------------------------------------------
def read_queries(path: Path) -> dict[str, str]:
    """Return {name: sql} for every block that starts with '-- @query NAME'."""
    queries: dict[str, str] = {}
    name, lines = None, []

    def finish():
        if name is not None:
            kept = [ln for ln in lines if not ln.strip().startswith("--")]
            queries[name] = "\n".join(kept).strip().rstrip(";").strip()

    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(MARKER):
            finish()
            name, lines = line[len(MARKER):].strip(), []
        elif name is not None:
            lines.append(line)
    finish()
    return queries


def run_query(engine, sql: str) -> pd.DataFrame:
    with engine.connect() as conn:
        return pd.read_sql(text(sql), conn)


# ----------------------------------------------------------------------------
# Independent expectations, calculated from the RAW files with pandas
# ----------------------------------------------------------------------------
def expected_data_quality() -> dict[str, float]:
    def read(name: str) -> pd.DataFrame:
        return pd.read_csv(RAW / f"{name}.csv", low_memory=False)

    trans, account, disp = read("trans"), read("account"), read("disp")
    client, district, card = read("client"), read("district"), read("card")
    loan, order = read("loan"), read("order")

    exp: dict[str, float] = {}
    exp["rows_transactions"] = len(trans)
    exp["zero_amount_rows"] = int((trans["amount"] == 0).sum())
    exp["zero_amount_flag_rows"] = exp["zero_amount_rows"]
    exp["negative_balance_rows"] = int((trans["balance"] < 0).sum())
    exp["negative_balance_flag_rows"] = exp["negative_balance_rows"]
    exp["negative_balance_accounts"] = int(trans.loc[trans["balance"] < 0, "account_id"].nunique())
    exp["blank_operation_rows"] = int(trans["operation"].isna().sum())
    exp["interest_rows"] = int((trans["k_symbol"] == "UROK").sum())
    exp["k_symbol_missing_rows"] = int(trans["k_symbol"].isna().sum())
    exp["k_symbol_space_rows"] = int((trans["k_symbol"] == " ").sum())
    exp["partner_account_zero_rows"] = int((trans["account"] == 0).sum())
    exp["rows_with_bank_and_account"] = int((trans["bank"].notna() & trans["account"].notna() & (trans["account"] != 0)).sum())
    no_account = trans["account"].isna() | (trans["account"] == 0)
    exp["transfers_without_counterparty"] = int(((trans["operation"] == "PREVOD NA UCET") & trans["bank"].isna() & no_account).sum())

    dup_cols = ["account_id", "date", "type", "operation", "amount", "k_symbol", "bank", "account"]
    sizes = trans.groupby(dup_cols, dropna=False).size()
    repeated_groups = sizes[sizes > 1]
    exp["identical_groups_by_grouping"] = len(repeated_groups)
    exp["identical_rows_by_grouping"] = int(repeated_groups.sum())
    exp["identical_rows_by_flag"] = exp["identical_rows_by_grouping"]

    repeated = trans[trans.duplicated(dup_cols, keep=False)]
    same_balance = repeated.groupby(dup_cols + ["balance"], dropna=False)["trans_id"].transform("size") > 1
    exp["phantom_rows_by_grouping"] = int((same_balance & (repeated["amount"] > 0)).sum())
    exp["phantom_rows_by_flag"] = exp["phantom_rows_by_grouping"]

    # The balance_check column was computed in notebook 02 (day-by-day algorithm), so read it from the clean file.
    checks = pd.read_csv(PROCESSED / "trans_clean.csv", usecols=["balance_check"])["balance_check"].value_counts()
    for label in ["exact", "rounding", "review"]:
        exp[f"balance_check_{label}_rows"] = int(checks.get(label, 0))
    exp["account_days"] = int(trans.groupby(["account_id", "date"]).ngroups)

    owners = disp[disp["type"] == "OWNER"]
    unmatched = [
        ~account["district_id"].isin(district["district_id"]),
        ~client["district_id"].isin(district["district_id"]),
        ~owners["client_id"].isin(client["client_id"]),
        ~disp["client_id"].isin(client["client_id"]),
        ~disp["account_id"].isin(account["account_id"]),
        ~card["disp_id"].isin(disp["disp_id"]),
        ~loan["account_id"].isin(account["account_id"]),
        ~order["account_id"].isin(account["account_id"]),
        ~trans["account_id"].isin(account["account_id"]),
    ]
    exp["orphan_rows_total"] = int(sum(int(mask.sum()) for mask in unmatched))

    owner_counts = owners.groupby("account_id").size().reindex(account["account_id"], fill_value=0)
    exp["accounts_without_exactly_one_owner"] = int((owner_counts != 1).sum())
    exp["accounts_without_transactions"] = int((~account["account_id"].isin(trans["account_id"])).sum())
    opened = pd.to_datetime(account.set_index("account_id")["date"])
    exp["postings_before_account_opened"] = int((pd.to_datetime(trans["date"]) < trans["account_id"].map(opened)).sum())

    for status in "ABCD":
        exp[f"loan_status_{status}"] = int((loan["status"] == status).sum())
    min_balance = trans.groupby("account_id")["balance"].min()
    ever_negative = loan["account_id"].map(min_balance) < 0
    exp["loan_status_vs_negative_balance_exceptions"] = int((loan["status"].isin(["B", "D"]) != ever_negative).sum())
    return exp


# Category labels are rebuilt here from the RAW columns, independently of notebook 02.
K_MEANING = {
    "UROK": "Interest credited",
    "SANKC. UROK": "Penalty interest",
    "SLUZBY": "Service fees",
    "SIPO": "Household payment",
    "DUCHOD": "Pension credit",
    "POJISTNE": "Insurance payment",
    "UVER": "Loan payment",
}
OP_MEANING = {
    "VKLAD": "Cash deposit",
    "PREVOD Z UCTU": "Incoming transfer",
    "PREVOD NA UCET": "Outgoing transfer",
    "VYBER": "Cash withdrawal",
    "VYBER KARTOU": "Card withdrawal",
}
BAND_LABELS = ["0 zero", "1 to 999", "1,000 to 4,999", "5,000 to 9,999", "10,000 to 24,999", "25,000 and over"]


def nearest_rank(values, pct: int) -> float:
    """Value at position CEIL(pct/100 * n) of the ascending sort (integer arithmetic, no float error)."""
    ordered = np.sort(values)
    n = len(ordered)
    return float(ordered[(pct * n + 99) // 100 - 1])


def expected_transaction_kpis() -> dict[str, float]:
    trans = pd.read_csv(RAW / "trans.csv", low_memory=False)
    amount, balance = trans["amount"], trans["balance"]
    credit = trans["type"] == "PRIJEM"
    signed = amount.where(credit, -amount)

    k = trans["k_symbol"]
    k_clean = k.where(k.fillna("").str.strip() != "", "NONE")  # blank and single space both mean "no symbol"
    category = k_clean.map(K_MEANING).fillna(trans["operation"].map(OP_MEANING)).fillna("Other")
    channel = pd.Series(
        np.select(
            [
                category.isin(["Interest credited", "Penalty interest", "Service fees"]),
                category.isin(["Cash deposit", "Cash withdrawal"]),
                category.eq("Card withdrawal"),
            ],
            ["Bank-generated", "Cash", "Card"],
            default="Transfers and payments",
        ),
        index=trans.index,
    )
    band = pd.cut(amount, [-1, 0, 999, 4999, 9999, 24999, np.inf], labels=BAND_LABELS).astype(str)
    trigger = ((balance - signed) >= 0) & (balance < 0)

    exp: dict[str, float] = {
        "total_postings": len(trans),
        "total_value": int(amount.sum()),
        "credit_postings": int(credit.sum()),
        "credit_value": int(amount[credit].sum()),
        "debit_postings": int((~credit).sum()),
        "debit_value": int(amount[~credit].sum()),
        "net_flow": int(signed.sum()),
        "avg_posting_value": round(float(amount.mean()), 2),
        "accounts_with_postings": int(trans["account_id"].nunique()),
        "avg_postings_per_account": round(len(trans) / trans["account_id"].nunique(), 2),
        "overdraft_trigger_postings": int(trigger.sum()),
    }
    for name, group in amount.groupby(trans["type"]):
        exp[f"type_postings|{name}"] = len(group)
        exp[f"type_value|{name}"] = int(group.sum())
    for name, group in amount.groupby(category):
        exp[f"category_postings|{name}"] = len(group)
        exp[f"category_value|{name}"] = int(group.sum())
        exp[f"category_overdraft_triggers|{name}"] = int(trigger[group.index].sum())
        exp[f"category_median|{name}"] = nearest_rank(group.to_numpy(), 50)
        exp[f"category_p90|{name}"] = nearest_rank(group.to_numpy(), 90)
    for name, group in amount.groupby(channel):
        exp[f"channel_postings|{name}"] = len(group)
        exp[f"channel_value|{name}"] = int(group.sum())
    for name, group in amount.groupby(band):
        exp[f"band_postings|{name}"] = len(group)
        exp[f"band_value|{name}"] = int(group.sum())
    return exp


def expected_monthly_trends() -> dict[str, float]:
    trans = pd.read_csv(RAW / "trans.csv", low_memory=False)
    account = pd.read_csv(RAW / "account.csv")
    amount, balance = trans["amount"], trans["balance"]
    signed = amount.where(trans["type"] == "PRIJEM", -amount)
    trigger = ((balance - signed) >= 0) & (balance < 0)
    period = trans["date"].str[:7]
    periods = pd.period_range("1993-01", "1998-12", freq="M").astype(str)  # the calendar table covers every month

    k = trans["k_symbol"]
    k_clean = k.where(k.fillna("").str.strip() != "", "NONE")
    category = k_clean.map(K_MEANING).fillna(trans["operation"].map(OP_MEANING)).fillna("Other")

    postings = period.groupby(period).size().reindex(periods, fill_value=0)
    active = trans.groupby(period)["account_id"].nunique().reindex(periods, fill_value=0)
    value = amount.groupby(period).sum().reindex(periods, fill_value=0)
    net_flow = signed.groupby(period).sum().reindex(periods, fill_value=0)
    triggers = trigger.groupby(period).sum().reindex(periods, fill_value=0)
    open_accounts = account["date"].str[:7].value_counts().reindex(periods, fill_value=0).cumsum()
    mom = (value.pct_change() * 100).replace([np.inf, -np.inf], np.nan).round(2)
    yoy = (value.pct_change(12) * 100).replace([np.inf, -np.inf], np.nan).round(2)

    exp: dict[str, float] = {}
    for p in periods:
        exp[f"monthly_postings|{p}"] = int(postings[p])
        exp[f"monthly_active_accounts|{p}"] = int(active[p])
        exp[f"monthly_value|{p}"] = int(value[p])
        exp[f"monthly_net_flow|{p}"] = int(net_flow[p])
        exp[f"monthly_overdraft_triggers|{p}"] = int(triggers[p])
        exp[f"open_accounts|{p}"] = int(open_accounts[p])
        if pd.notna(mom[p]):
            exp[f"value_mom_pct|{p}"] = float(mom[p])
        if pd.notna(yoy[p]):
            exp[f"value_yoy_pct|{p}"] = float(yoy[p])

    year = trans["date"].str[:4]
    for name, group in amount.groupby(year):
        exp[f"yearly_postings|{name}"] = len(group)
        exp[f"yearly_value|{name}"] = int(group.sum())
        exp[f"yearly_active_accounts|{name}"] = int(trans.loc[group.index, "account_id"].nunique())

    dates = pd.to_datetime(trans["date"])
    for name, count in dates.dt.dayofweek.add(1).value_counts().items():  # 1 = Monday, like iso_weekday
        exp[f"weekday_postings|{name}"] = int(count)
    for name, count in dates.dt.is_month_end.groupby(category).sum().items():
        exp[f"month_end_postings|{name}"] = int(count)
    return exp


BANK_GENERATED = ["Interest credited", "Penalty interest", "Service fees"]
AGE_BINS = [-1, 17, 24, 34, 44, 54, 64, 200]
AGE_LABELS = ["under 18", "18-24", "25-34", "35-44", "45-54", "55-64", "65+"]
FREQUENCY_LABELS = {"POPLATEK MESICNE": "Monthly", "POPLATEK TYDNE": "Weekly", "POPLATEK PO OBRATU": "After each transaction"}


def ntile_labels(n_rows: int, k: int) -> np.ndarray:
    """Tile numbers 1..k for n_rows sorted rows, as SQL NTILE() assigns them (earlier tiles get the extra rows)."""
    base, extra = divmod(n_rows, k)
    return np.repeat(np.arange(1, k + 1), [base + 1] * extra + [base] * (k - extra))


def age_on(dob: pd.Series, ref: pd.Series) -> pd.Series:
    """Completed years on the reference date."""
    had_birthday = (ref.dt.month > dob.dt.month) | ((ref.dt.month == dob.dt.month) & (ref.dt.day >= dob.dt.day))
    return ref.dt.year - dob.dt.year - (~had_birthday).astype(int)


def expected_customer_analysis() -> dict[str, float]:
    trans = pd.read_csv(RAW / "trans.csv", low_memory=False)
    account, disp, client = (pd.read_csv(RAW / f"{n}.csv") for n in ("account", "disp", "client"))
    district, loan, card = (pd.read_csv(RAW / f"{n}.csv") for n in ("district", "loan", "card"))

    k = trans["k_symbol"]
    k_clean = k.where(k.fillna("").str.strip() != "", "NONE")
    category = k_clean.map(K_MEANING).fillna(trans["operation"].map(OP_MEANING)).fillna("Other")
    bank_generated = category.isin(BANK_GENERATED)
    customer = trans[~bank_generated]
    amount, balance = trans["amount"], trans["balance"]
    signed = amount.where(trans["type"] == "PRIJEM", -amount)
    trigger = ((balance - signed) >= 0) & (balance < 0)

    # Owner attributes and products, rebuilt from the raw tables (independently of notebook 02)
    owner = disp[disp["type"] == "OWNER"][["account_id", "client_id"]].merge(
        client[["client_id", "gender", "birth_date"]], on="client_id"
    )
    acct = account.rename(columns={"date": "opened"}).merge(owner, on="account_id")
    acct = acct.merge(district[["district_id", "A3"]], on="district_id")
    acct["opened"] = pd.to_datetime(acct["opened"])
    acct["birth_date"] = pd.to_datetime(acct["birth_date"])
    acct["age_band"] = pd.cut(age_on(acct["birth_date"], acct["opened"]), AGE_BINS, labels=AGE_LABELS).astype(str)
    acct["tenure"] = (1998 - acct["opened"].dt.year) * 12 + (12 - acct["opened"].dt.month) + 1
    acct["has_loan"] = np.where(acct["account_id"].isin(loan["account_id"]), "yes", "no")
    card_accounts = card.merge(disp[["disp_id", "account_id"]], on="disp_id")["account_id"]
    acct["has_card"] = np.where(acct["account_id"].isin(card_accounts), "yes", "no")
    acct["frequency"] = acct["frequency"].map(FREQUENCY_LABELS)
    acct = acct.set_index("account_id")
    acct["postings"] = customer.groupby("account_id").size().reindex(acct.index, fill_value=0)
    acct["value"] = customer.groupby("account_id")["amount"].sum().reindex(acct.index, fill_value=0)
    acct["intensity"] = acct["postings"] / acct["tenure"]

    exp: dict[str, float] = {}
    origin = np.where(bank_generated, "Bank-generated", "Customer-initiated")
    for name, group in amount.groupby(origin):
        exp[f"origin_postings|{name}"] = len(group)
        exp[f"origin_value|{name}"] = int(group.sum())

    periods = pd.period_range("1993-01", "1998-12", freq="M").astype(str)
    active_any = trans.groupby(trans["date"].str[:7])["account_id"].nunique().reindex(periods, fill_value=0)
    active_customer = customer.groupby(customer["date"].str[:7])["account_id"].nunique().reindex(periods, fill_value=0)
    for p in periods:
        exp[f"monthly_active_any|{p}"] = int(active_any[p])
        exp[f"monthly_active_customer|{p}"] = int(active_customer[p])

    by_intensity = acct.reset_index().sort_values(["intensity", "account_id"]).reset_index(drop=True)
    by_intensity["quartile"] = ntile_labels(len(by_intensity), 4)
    for q, group in by_intensity.groupby("quartile"):
        exp[f"quartile_accounts|{q}"] = len(group)
        exp[f"quartile_postings|{q}"] = int(group["postings"].sum())
        exp[f"quartile_value|{q}"] = int(group["value"].sum())

    by_value = acct.reset_index().sort_values(["value", "account_id"], ascending=[False, True]).reset_index(drop=True)
    by_value["decile"] = ntile_labels(len(by_value), 10)
    for d, group in by_value.groupby("decile"):
        exp[f"decile_accounts|{d}"] = len(group)
        exp[f"decile_postings|{d}"] = int(group["postings"].sum())
        exp[f"decile_value|{d}"] = int(group["value"].sum())
    for rank, value in enumerate(by_value["value"].head(10), start=1):
        exp[f"top_account_value|{rank}"] = int(value)

    dimensions = {
        "age band": "age_band", "gender": "gender", "region": "A3",
        "has loan": "has_loan", "has card": "has_card", "statement frequency": "frequency",
    }
    for label, column in dimensions.items():
        for segment, group in acct.groupby(column):
            exp[f"segment_accounts|{label}|{segment}"] = len(group)
            exp[f"segment_postings|{label}|{segment}"] = int(group["postings"].sum())
            exp[f"segment_value|{label}|{segment}"] = int(group["value"].sum())
            exp[f"avg_postings_per_month|{label}|{segment}"] = round(float(group["intensity"].mean()), 2)

    events = trigger.groupby(trans["account_id"]).sum().reindex(acct.index, fill_value=0)
    bands = pd.cut(events, [-1, 0, 1, 3, 9, np.inf], labels=["0", "1", "2 to 3", "4 to 9", "10 or more"]).astype(str)
    for band, group in events.groupby(bands):
        exp[f"overdraft_band_accounts|{band}"] = len(group)
        exp[f"overdraft_band_events|{band}"] = int(group.sum())
    return exp


def expected_transaction_anomalies() -> dict[str, float]:
    trans = pd.read_csv(RAW / "trans.csv", low_memory=False)
    account = pd.read_csv(RAW / "account.csv")
    k = trans["k_symbol"]
    k_clean = k.where(k.fillna("").str.strip() != "", "NONE")
    category = k_clean.map(K_MEANING).fillna(trans["operation"].map(OP_MEANING)).fillna("Other")
    credit = trans["type"] == "PRIJEM"
    signed = trans["amount"].where(credit, -trans["amount"])
    is_customer = ~category.isin(BANK_GENERATED)

    cust = trans[is_customer].copy()
    cust["category"] = category[is_customer]
    cust["balance_before"] = (trans["balance"] - signed)[is_customer]
    cust["credit"] = credit[is_customer]
    exp: dict[str, float] = {"customer_postings_total": len(cust)}

    # R1: far-out fence per category (nearest-rank quartiles, categories with Q3 = Q1 skipped)
    r1_accounts = []
    for name, group in cust.groupby("category"):
        n = len(group)
        ordered = np.sort(group["amount"].to_numpy())
        q1, q3 = ordered[(25 * n + 99) // 100 - 1], ordered[(75 * n + 99) // 100 - 1]
        if q3 <= q1:
            continue
        fence = q3 + 3 * (q3 - q1)
        exp[f"r1_q1|{name}"], exp[f"r1_q3|{name}"], exp[f"r1_fence|{name}"] = float(q1), float(q3), float(fence)
        hit = group[group["amount"] > fence]
        if len(hit):
            exp[f"r1_flagged|{name}"] = len(hit)
            r1_accounts.append(hit["account_id"])
    r1 = pd.concat(r1_accounts) if r1_accounts else pd.Series([], dtype="int64")
    exp["r1_flagged_postings"], exp["r1_accounts"] = len(r1), int(r1.nunique())

    # R2: a debit takes at least 80% of a balance of 10,000 or more
    drain = cust[(~cust["credit"]) & (cust["balance_before"] >= 10000) & (cust["amount"] * 10 >= 8 * cust["balance_before"])]
    exp["r2_flagged_postings"], exp["r2_accounts"] = len(drain), int(drain["account_id"].nunique())
    for name, group in drain.groupby("category"):
        exp[f"r2_flagged|{name}"] = len(group)

    # R3: at least 5 postings in a day and at least 3 times the account's average on its active days
    day = cust.groupby(["account_id", "date"]).size().rename("n_day").reset_index()
    totals = day.groupby("account_id")["n_day"].agg(account_postings="sum", account_active_days="size")
    day = day.join(totals, on="account_id")
    spike = day[(day["n_day"] >= 5) & (day["n_day"] * day["account_active_days"] >= 3 * day["account_postings"])]
    exp["r3_spike_days"], exp["r3_accounts"] = len(spike), int(spike["account_id"].nunique())
    exp["r3_postings_in_spike_days"] = int(spike["n_day"].sum())
    periods = pd.period_range("1993-01", "1998-12", freq="M").astype(str)
    by_period = spike.groupby(spike["date"].str[:7]).size().reindex(periods, fill_value=0)
    for p in periods:
        exp[f"r3_spike_days|{p}"] = int(by_period[p])

    ids = account["account_id"]
    n1 = r1.value_counts().reindex(ids, fill_value=0)
    n2 = drain["account_id"].value_counts().reindex(ids, fill_value=0)
    n3 = spike["account_id"].value_counts().reindex(ids, fill_value=0)
    rules = (n1 > 0).astype(int) + (n2 > 0).astype(int) + (n3 > 0).astype(int)
    for count_of_rules, accounts in rules.value_counts().items():
        exp[f"rules_triggered_accounts|{count_of_rules}"] = int(accounts)

    # Calendar drill-downs for cash and card withdrawals
    withdrawals = trans[category.isin(["Cash withdrawal", "Card withdrawal"])]
    dates = pd.to_datetime(withdrawals["date"])
    frame = pd.DataFrame({"cat": category[withdrawals.index], "year": dates.dt.year, "month": dates.dt.month,
                          "dom": dates.dt.day, "jan": dates.dt.month == 1})
    for (name, year, month), group in frame.groupby(["cat", "year", "month"]):
        exp[f"withdrawals|{name}|{year}|{month}"] = len(group)
    for (name, dom), group in frame.groupby(["cat", "dom"]):
        exp[f"jan_postings|{name}|{dom}"] = int(group["jan"].sum())
        exp[f"other_postings|{name}|{dom}"] = int((~group["jan"]).sum())
    return exp


EXPECTED = {
    "01_data_quality_checks": expected_data_quality,
    "02_transaction_kpis": expected_transaction_kpis,
    "03_monthly_trends": expected_monthly_trends,
    "04_customer_analysis": expected_customer_analysis,
    "05_transaction_anomalies": expected_transaction_anomalies,
}


# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
def compare(engine, queries: dict[str, str], sql_file: Path) -> int:
    builder = EXPECTED.get(sql_file.stem)
    if builder is None:
        sys.exit(f"No pandas expectations are registered for {sql_file.name} yet.")
    if "scoreboard" not in queries:
        sys.exit("The SQL file has no '-- @query scoreboard' block.")

    print("Running the scoreboard query in MySQL ...")
    mysql_values = run_query(engine, queries["scoreboard"]).set_index("metric")["value"].astype(float).to_dict()
    print("Calculating the same numbers with pandas from the raw files ...")
    pandas_values = builder()

    rows = []
    for metric in sorted(set(mysql_values) | set(pandas_values)):
        p, m = pandas_values.get(metric), mysql_values.get(metric)
        if "_pct" in metric:
            tolerance = 0.011  # percentages are rounded to 2 decimals on both sides
        elif metric.startswith("avg_"):
            tolerance = 0.0051  # averages are rounded to 2 decimals
        else:
            tolerance = 1e-6
        ok = p is not None and m is not None and abs(float(p) - float(m)) <= tolerance
        rows.append({"metric": metric, "pandas": p, "mysql": m, "match": ok})
    report = pd.DataFrame(rows)

    REPORTS.mkdir(exist_ok=True)
    out = REPORTS / f"sql_validation_{sql_file.stem}.csv"
    report.to_csv(out, index=False)
    print()
    print(report.to_string(index=False))
    failed = report[~report["match"]]
    if len(failed):
        print(f"\nVALIDATION FAILED for {len(failed)} metric(s). Paste the table above.")
        return 1
    print(f"\nValidation passed: {len(report)} metrics match. Report: {out.relative_to(ROOT)}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Run named SQL queries and validate them against pandas.")
    parser.add_argument("--file", type=Path, default=DEFAULT_FILE, help="SQL file with '-- @query NAME' blocks")
    parser.add_argument("--show", metavar="NAME", help="print the result of one named query")
    parser.add_argument("--smoke", action="store_true", help="run every named query and report rows and timing")
    args = parser.parse_args()

    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 30)

    load_env_file(ROOT / ".env")
    sql_file = args.file if args.file.is_absolute() else ROOT / args.file
    queries = read_queries(sql_file)
    engine = make_engine(DATABASE)

    if args.show:
        if args.show not in queries:
            sys.exit(f"No query named '{args.show}'. Available: {', '.join(queries)}")
        print(run_query(engine, queries[args.show]).to_string(index=False))
    elif args.smoke:
        for name, sql in queries.items():
            start = time.time()
            frame = run_query(engine, sql)
            print(f"{name:<40} {len(frame):>6,} rows  {time.time() - start:6.1f}s")
    else:
        sys.exit(compare(engine, queries, sql_file))


if __name__ == "__main__":
    main()
