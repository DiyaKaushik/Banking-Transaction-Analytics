-- =====================================================================
-- 01_data_quality_checks.sql
-- Banking Transaction Analytics (MySQL 8.0)
--
-- Business question: can we trust the data in MySQL before we build KPIs on it?
-- Each query below answers one question. Run them in MySQL Workbench one at
-- a time (select a query, then Ctrl+Enter), or use scripts/validate_sql.py:
--     python scripts/validate_sql.py --show NAME   print one query's result
--     python scripts/validate_sql.py               compare the scoreboard with pandas
--
-- Currency: Czech koruna (CZK). Data: public Berka dataset, 1993-1998.
-- "Expected" values quoted in comments were found independently in Python
-- (notebooks 01 and 02) on the full dataset.
-- Queries marked @query are picked up by validate_sql.py by name.
-- =====================================================================

USE banking_analytics;


-- @query row_counts
-- Question: does every table hold the number of rows the cleaning step produced?
-- Technique: CTEs, UNION ALL, INNER JOIN, CASE WHEN.
WITH expected AS (
    SELECT 'district' AS table_name, 77 AS expected_rows UNION ALL
    SELECT 'client',          5369    UNION ALL
    SELECT 'account',         4500    UNION ALL
    SELECT 'disp',            5369    UNION ALL
    SELECT 'card',            892     UNION ALL
    SELECT 'loan',            682     UNION ALL
    SELECT 'standing_order',  6471    UNION ALL
    SELECT 'transactions',    1056320 UNION ALL
    SELECT 'dim_date',        2191
),
actual AS (
    SELECT 'district' AS table_name, COUNT(*) AS actual_rows FROM district UNION ALL
    SELECT 'client',          COUNT(*) FROM client          UNION ALL
    SELECT 'account',         COUNT(*) FROM account         UNION ALL
    SELECT 'disp',            COUNT(*) FROM disp            UNION ALL
    SELECT 'card',            COUNT(*) FROM card            UNION ALL
    SELECT 'loan',            COUNT(*) FROM loan            UNION ALL
    SELECT 'standing_order',  COUNT(*) FROM standing_order  UNION ALL
    SELECT 'transactions',    COUNT(*) FROM transactions    UNION ALL
    SELECT 'dim_date',        COUNT(*) FROM dim_date
)
SELECT
    a.table_name,
    e.expected_rows,
    a.actual_rows,
    CASE WHEN a.actual_rows = e.expected_rows THEN 'PASS' ELSE 'FAIL' END AS status
FROM actual AS a
INNER JOIN expected AS e ON e.table_name = a.table_name
ORDER BY a.table_name;


-- @query totals_by_type
-- Question: how many postings and how much money (CZK) are there per transaction type?
-- Expected: PRIJEM 405,083 / 3,227,482,664; VYBER 16,666 / 208,603,758;
--           VYDAJ 634,571 / 2,821,775,775; ALL 1,056,320 / 6,257,862,197; net 197,103,131.
-- Technique: GROUP BY ... WITH ROLLUP, GROUPING().
SELECT
    CASE WHEN GROUPING(type) = 1 THEN 'ALL' ELSE type END AS type,
    COUNT(*)           AS postings,
    SUM(amount)        AS total_amount_czk,
    SUM(signed_amount) AS net_amount_czk
FROM transactions
GROUP BY type WITH ROLLUP;


-- @query foreign_key_orphans
-- Question: does any row point to a parent row that does not exist?
-- (InnoDB already enforces the foreign keys; this proves it and shows the LEFT JOIN anti-join pattern.)
-- Expected: 0 for every relationship.
SELECT 'account.district_id -> district' AS relationship, COUNT(*) AS orphan_rows
FROM account AS a LEFT JOIN district AS p ON p.district_id = a.district_id WHERE p.district_id IS NULL
UNION ALL
SELECT 'client.district_id -> district', COUNT(*)
FROM client AS c LEFT JOIN district AS p ON p.district_id = c.district_id WHERE p.district_id IS NULL
UNION ALL
SELECT 'account.owner_client_id -> client', COUNT(*)
FROM account AS a LEFT JOIN client AS p ON p.client_id = a.owner_client_id WHERE p.client_id IS NULL
UNION ALL
SELECT 'disp.client_id -> client', COUNT(*)
FROM disp AS d LEFT JOIN client AS p ON p.client_id = d.client_id WHERE p.client_id IS NULL
UNION ALL
SELECT 'disp.account_id -> account', COUNT(*)
FROM disp AS d LEFT JOIN account AS p ON p.account_id = d.account_id WHERE p.account_id IS NULL
UNION ALL
SELECT 'card.disp_id -> disp', COUNT(*)
FROM card AS c LEFT JOIN disp AS p ON p.disp_id = c.disp_id WHERE p.disp_id IS NULL
UNION ALL
SELECT 'loan.account_id -> account', COUNT(*)
FROM loan AS l LEFT JOIN account AS p ON p.account_id = l.account_id WHERE p.account_id IS NULL
UNION ALL
SELECT 'standing_order.account_id -> account', COUNT(*)
FROM standing_order AS o LEFT JOIN account AS p ON p.account_id = o.account_id WHERE p.account_id IS NULL
UNION ALL
SELECT 'transactions.account_id -> account', COUNT(*)
FROM transactions AS t LEFT JOIN account AS p ON p.account_id = t.account_id WHERE p.account_id IS NULL
UNION ALL
SELECT 'transactions.trans_date -> dim_date', COUNT(*)
FROM transactions AS t LEFT JOIN dim_date AS p ON p.date_key = t.trans_date WHERE p.date_key IS NULL;


-- @query ownership_structure
-- Question: does every account have exactly one OWNER?
-- Expected: one row, n_owners = 1, 4,500 accounts.
-- Technique: LEFT JOIN with the condition in ON (keeps accounts without an owner), CTE, GROUP BY.
WITH owners AS (
    SELECT a.account_id, COUNT(d.disp_id) AS n_owners
    FROM account AS a
    LEFT JOIN disp AS d ON d.account_id = a.account_id AND d.type = 'OWNER'
    GROUP BY a.account_id
)
SELECT n_owners, COUNT(*) AS accounts
FROM owners
GROUP BY n_owners
ORDER BY n_owners;


-- @query clients_without_one_disposition
-- Question: which clients are linked to zero or several accounts? (Expected: no rows.)
-- Technique: HAVING, LIMIT.
SELECT c.client_id, COUNT(d.disp_id) AS dispositions
FROM client AS c
LEFT JOIN disp AS d ON d.client_id = c.client_id
GROUP BY c.client_id
HAVING COUNT(d.disp_id) <> 1
ORDER BY c.client_id
LIMIT 20;


-- @query accounts_without_transactions
-- Question: are there accounts that never posted a transaction? (Expected: 0.)
SELECT COUNT(*) AS accounts_without_transactions
FROM account AS a
WHERE NOT EXISTS (SELECT 1 FROM transactions AS t WHERE t.account_id = a.account_id);


-- @query postings_before_opening
-- Question: is any posting dated before its account was opened? (Expected: 0.)
-- Technique: INNER JOIN, date comparison.
SELECT COUNT(*) AS postings_before_account_opened
FROM transactions AS t
INNER JOIN account AS a ON a.account_id = t.account_id
WHERE t.trans_date < a.opened_date;


-- @query missing_values_transactions
-- Question: how many values are missing in the transaction code columns, and why?
-- Expected: operation 183,114 (17.34%); k_symbol 481,881 (45.62%) plus 53,433 single spaces;
--           partner_bank 782,812 (74.11%); partner_account 782,812; partner account 0 on 21,881.
-- Technique: conditional aggregation, NULL handling.
SELECT
    COUNT(*)                                                         AS postings,
    SUM(operation IS NULL)                                           AS operation_null,
    ROUND(100 * SUM(operation IS NULL) / COUNT(*), 2)                AS operation_null_pct,
    SUM(k_symbol IS NULL)                                            AS k_symbol_null,
    ROUND(100 * SUM(k_symbol IS NULL) / COUNT(*), 2)                 AS k_symbol_null_pct,
    SUM(k_symbol IS NOT NULL AND TRIM(k_symbol) = '')                AS k_symbol_single_space,
    SUM(partner_bank IS NULL)                                        AS partner_bank_null,
    ROUND(100 * SUM(partner_bank IS NULL) / COUNT(*), 2)             AS partner_bank_null_pct,
    SUM(partner_account IS NULL)                                     AS partner_account_null,
    SUM(partner_account_was_zero)                                    AS partner_account_was_zero
FROM transactions;


-- @query blank_operation_vs_interest
-- Question: is a blank operation exactly the interest credits?
-- Expected: only two rows: (1, 1) with 183,114 postings and (0, 0) with 873,206.
-- Technique: NULL handling. k_symbol = 'UROK' is NULL (not 0) when k_symbol is NULL, which would
-- create a third group. The NULL-safe operator <=> returns 0 or 1, never NULL.
SELECT
    (operation IS NULL)       AS operation_is_null,
    (k_symbol <=> 'UROK')     AS is_interest_credit,
    COUNT(*)                  AS postings
FROM transactions
GROUP BY operation IS NULL, k_symbol <=> 'UROK'
ORDER BY operation_is_null DESC, is_interest_credit DESC;


-- @query k_symbol_kinds_by_type
-- Question: where do the three kinds of k_symbol (value / missing / single space) occur?
-- Expected: PRIJEM 213,452 / 191,631 / 0; VYBER 0 / 16,666 / 0; VYDAJ 307,554 / 273,584 / 53,433.
SELECT
    type,
    SUM(k_symbol_kind = 'value')   AS has_value,
    SUM(k_symbol_kind = 'missing') AS missing_symbol,
    SUM(k_symbol_kind = 'space')   AS single_space
FROM transactions
GROUP BY type
ORDER BY type;


-- @query counterparty_patterns
-- Question: which combinations of partner bank and partner account exist?
-- Expected: no bank + no account 760,931; bank + real account 273,508; no bank + account 0 21,881;
--           other combination 0.
-- Technique: CASE WHEN as a classifier, GROUP BY alias.
SELECT
    CASE
        WHEN partner_bank IS NOT NULL AND partner_account IS NOT NULL THEN 'bank and real account'
        WHEN partner_bank IS NULL AND partner_account_was_zero = 1    THEN 'no bank, account = 0'
        WHEN partner_bank IS NULL AND partner_account IS NULL         THEN 'no bank, no account'
        ELSE 'other combination'
    END AS counterparty_pattern,
    COUNT(*) AS postings
FROM transactions
GROUP BY counterparty_pattern
ORDER BY postings DESC;


-- @query flag_summary
-- Question: how many postings carry each data quality flag?
-- Expected: zero amount 162; negative balance 2,999 (in 288 accounts); identical-looking 3,448;
--           possible phantom copies 8.
SELECT
    COUNT(*)                                                                   AS postings,
    SUM(is_zero_amount)                                                        AS zero_amount_postings,
    SUM(is_negative_balance)                                                   AS negative_balance_postings,
    COUNT(DISTINCT CASE WHEN is_negative_balance = 1 THEN account_id END)      AS accounts_ever_negative,
    SUM(is_repeated_posting)                                                   AS identical_looking_postings,
    SUM(possible_phantom_copy)                                                 AS possible_phantom_copies
FROM transactions;


-- @query identical_posting_groups
-- Question: how many groups of identical-looking postings exist, and how large are they?
-- Postings that match in every column except trans_id are kept (most are separate postings).
-- Expected: group size 2 -> 1,721 groups; size 3 -> 2 groups; 3,448 postings in total.
-- Technique: nested GROUP BY ... HAVING. NULLs group together.
SELECT group_size, COUNT(*) AS identical_groups, SUM(group_size) AS postings
FROM (
    SELECT COUNT(*) AS group_size
    FROM transactions
    GROUP BY account_id, trans_date, type, operation, amount, k_symbol,
             partner_bank, partner_account, partner_account_was_zero
    HAVING COUNT(*) > 1
) AS identical_groups
GROUP BY group_size
ORDER BY group_size;


-- @query identical_postings_by_category
-- Question: which kinds of postings repeat?
-- Expected (profiling): interest credits about 2,772 postings, cash and card withdrawals about 345,
--           penalty interest about 325, deposits 6.
-- Technique: CTE, window function over an aggregate (share of total).
WITH identical_groups AS (
    SELECT transaction_category, COUNT(*) AS group_size
    FROM transactions
    GROUP BY account_id, trans_date, type, operation, amount, k_symbol,
             partner_bank, partner_account, partner_account_was_zero, transaction_category
    HAVING COUNT(*) > 1
)
SELECT
    transaction_category,
    COUNT(*)                                                              AS identical_groups,
    SUM(group_size)                                                       AS postings,
    ROUND(100 * SUM(group_size) / SUM(SUM(group_size)) OVER (), 1)        AS share_of_repeated_pct
FROM identical_groups
GROUP BY transaction_category
ORDER BY postings DESC;


-- @query identical_postings_balance_spacing
-- Question: do identical-looking postings each move the balance, or are some phantom copies?
-- If both are genuine postings, their balances are spaced by the amount. A phantom copy would
-- leave both postings with the same balance.
-- Expected (profiling): 1,723 groups; about 74% spaced exactly, about 94.5% within 1;
--           about 0.23% (4 groups) with identical balances.
-- Technique: named window, COUNT / MIN / LAG window functions, CTE chain.
WITH keyed AS (
    SELECT
        t.trans_id, t.amount, t.balance,
        MIN(t.trans_id) OVER w AS group_key,
        COUNT(*)        OVER w AS group_size
    FROM transactions AS t
    WINDOW w AS (
        PARTITION BY t.account_id, t.trans_date, t.type, t.operation, t.amount, t.k_symbol,
                     t.partner_bank, t.partner_account, t.partner_account_was_zero
    )
),
repeated AS (
    SELECT * FROM keyed WHERE group_size > 1
),
stepped AS (
    SELECT
        group_key, amount,
        balance - LAG(balance) OVER (PARTITION BY group_key ORDER BY balance) AS step
    FROM repeated
),
per_group AS (
    SELECT
        group_key,
        MIN(step IS NULL OR ABS(step - amount) <= 0.01) AS spaced_exactly,
        MIN(step IS NULL OR ABS(step - amount) <= 1)    AS spaced_within_1,
        MAX(step = 0 AND amount > 0)                    AS same_balance
    FROM stepped
    GROUP BY group_key
)
SELECT
    COUNT(*)                                                AS identical_groups,
    SUM(spaced_exactly)                                     AS spaced_exactly,
    ROUND(100 * SUM(spaced_exactly) / COUNT(*), 2)          AS spaced_exactly_pct,
    SUM(spaced_within_1)                                    AS spaced_within_1,
    ROUND(100 * SUM(spaced_within_1) / COUNT(*), 2)         AS spaced_within_1_pct,
    COALESCE(SUM(same_balance), 0)                          AS groups_with_same_balance
FROM per_group;


-- @query balance_check_distribution
-- Question: how well does the balance column hold together, day by day?
-- balance_check was computed in notebook 02 per account-day: exact (up to 0.01), rounding (up to 2),
-- review (above 2). amount and balance are whole numbers, so differences of 1 or 2 are rounding.
-- Expected: account-days exact 750,640; rounding 64,127; review 1 (7 postings).
SELECT
    balance_check,
    COUNT(*)                                AS postings,
    COUNT(DISTINCT account_id, trans_date)  AS account_days,
    MAX(account_day_residual)               AS largest_difference
FROM transactions
GROUP BY balance_check
ORDER BY FIELD(balance_check, 'exact', 'rounding', 'review');


-- @query exceptions_to_review
-- Question: which individual postings need a human look? (Kept in the data, never deleted.)
-- Expected: 8 possible phantom copies, 1 outgoing transfer without a counterparty,
--           7 postings on the one account-day with a balance difference above 2.
-- Technique: UNION ALL, ORDER BY over the whole union.
SELECT 'possible phantom copy' AS issue, trans_id, account_id, trans_date, type, amount, balance
FROM transactions WHERE possible_phantom_copy = 1
UNION ALL
SELECT 'outgoing transfer without a counterparty', trans_id, account_id, trans_date, type, amount, balance
FROM transactions
WHERE operation = 'PREVOD NA UCET' AND partner_bank IS NULL AND partner_account IS NULL
UNION ALL
SELECT 'balance difference above 2', trans_id, account_id, trans_date, type, amount, balance
FROM transactions WHERE balance_check = 'review'
ORDER BY issue, account_id, trans_date, trans_id;


-- @query closing_balance_drift
-- Question (informational): does the last balance of an account equal the sum of all its postings?
-- Amounts and balances are rounded to whole numbers separately, so small differences can add up
-- over the life of an account. This query MEASURES that drift; it is not expected to be zero.
-- Technique: CTEs, ROW_NUMBER to pick the closest balance on the last day, conditional aggregation.
WITH account_net AS (
    SELECT account_id, SUM(signed_amount) AS net_movement, MAX(trans_date) AS last_date
    FROM transactions
    GROUP BY account_id
),
last_day AS (
    SELECT
        n.account_id, n.net_movement, t.balance,
        ROW_NUMBER() OVER (
            PARTITION BY n.account_id
            ORDER BY ABS(t.balance - n.net_movement), t.trans_id
        ) AS closest
    FROM account_net AS n
    INNER JOIN transactions AS t ON t.account_id = n.account_id AND t.trans_date = n.last_date
)
SELECT
    COUNT(*)                                                                         AS accounts,
    SUM(ABS(balance - net_movement) <= 2)                                            AS drift_up_to_2,
    SUM(ABS(balance - net_movement) > 2 AND ABS(balance - net_movement) <= 10)      AS drift_3_to_10,
    SUM(ABS(balance - net_movement) > 10)                                            AS drift_above_10,
    MAX(ABS(balance - net_movement))                                                 AS largest_drift,
    SUM(net_movement)                                                                AS total_net_movement,
    SUM(balance)                                                                     AS total_closing_balance
FROM last_day
WHERE closest = 1;


-- @query scoreboard
-- Question: do the numbers MySQL gives agree with the numbers Python calculates from the raw files?
-- scripts/validate_sql.py runs this query and compares every metric with pandas.
-- Technique: CTEs referenced several times, conditional aggregation, scalar subqueries, UNION ALL.
WITH t AS (
    SELECT
        COUNT(*)                                                                     AS rows_transactions,
        SUM(amount = 0)                                                              AS zero_amount_rows,
        SUM(is_zero_amount)                                                          AS zero_amount_flag_rows,
        SUM(balance < 0)                                                             AS negative_balance_rows,
        SUM(is_negative_balance)                                                     AS negative_balance_flag_rows,
        COUNT(DISTINCT CASE WHEN balance < 0 THEN account_id END)                    AS negative_balance_accounts,
        SUM(operation IS NULL)                                                       AS blank_operation_rows,
        SUM(k_symbol = 'UROK')                                                       AS interest_rows,
        SUM(k_symbol IS NULL)                                                        AS k_symbol_missing_rows,
        SUM(k_symbol IS NOT NULL AND TRIM(k_symbol) = '')                            AS k_symbol_space_rows,
        SUM(partner_account_was_zero)                                                AS partner_account_zero_rows,
        SUM(partner_bank IS NOT NULL AND partner_account IS NOT NULL)                AS rows_with_bank_and_account,
        SUM(operation = 'PREVOD NA UCET' AND partner_bank IS NULL
            AND partner_account IS NULL)                                             AS transfers_without_counterparty,
        SUM(is_repeated_posting)                                                     AS identical_rows_by_flag,
        SUM(possible_phantom_copy)                                                   AS phantom_rows_by_flag,
        SUM(balance_check = 'exact')                                                 AS balance_check_exact_rows,
        SUM(balance_check = 'rounding')                                              AS balance_check_rounding_rows,
        SUM(balance_check = 'review')                                                AS balance_check_review_rows,
        COUNT(DISTINCT account_id, trans_date)                                       AS account_days
    FROM transactions
),
identical AS (
    SELECT COUNT(*) AS n_groups, COALESCE(SUM(group_size), 0) AS n_rows
    FROM (
        SELECT COUNT(*) AS group_size
        FROM transactions
        GROUP BY account_id, trans_date, type, operation, amount, k_symbol,
                 partner_bank, partner_account, partner_account_was_zero
        HAVING COUNT(*) > 1
    ) AS g
),
phantom AS (
    SELECT COALESCE(SUM(n), 0) AS n_rows
    FROM (
        SELECT COUNT(*) AS n
        FROM transactions
        WHERE amount > 0
        GROUP BY account_id, trans_date, type, operation, amount, k_symbol,
                 partner_bank, partner_account, partner_account_was_zero, balance
        HAVING COUNT(*) > 1
    ) AS p
)
SELECT 'rows_transactions' AS metric, rows_transactions AS value FROM t
UNION ALL SELECT 'zero_amount_rows',               zero_amount_rows               FROM t
UNION ALL SELECT 'zero_amount_flag_rows',          zero_amount_flag_rows          FROM t
UNION ALL SELECT 'negative_balance_rows',          negative_balance_rows          FROM t
UNION ALL SELECT 'negative_balance_flag_rows',     negative_balance_flag_rows     FROM t
UNION ALL SELECT 'negative_balance_accounts',      negative_balance_accounts      FROM t
UNION ALL SELECT 'blank_operation_rows',           blank_operation_rows           FROM t
UNION ALL SELECT 'interest_rows',                  interest_rows                  FROM t
UNION ALL SELECT 'k_symbol_missing_rows',          k_symbol_missing_rows          FROM t
UNION ALL SELECT 'k_symbol_space_rows',            k_symbol_space_rows            FROM t
UNION ALL SELECT 'partner_account_zero_rows',      partner_account_zero_rows      FROM t
UNION ALL SELECT 'rows_with_bank_and_account',     rows_with_bank_and_account     FROM t
UNION ALL SELECT 'transfers_without_counterparty', transfers_without_counterparty FROM t
UNION ALL SELECT 'identical_rows_by_flag',         identical_rows_by_flag         FROM t
UNION ALL SELECT 'phantom_rows_by_flag',           phantom_rows_by_flag           FROM t
UNION ALL SELECT 'balance_check_exact_rows',       balance_check_exact_rows       FROM t
UNION ALL SELECT 'balance_check_rounding_rows',    balance_check_rounding_rows    FROM t
UNION ALL SELECT 'balance_check_review_rows',      balance_check_review_rows      FROM t
UNION ALL SELECT 'account_days',                   account_days                   FROM t
UNION ALL SELECT 'identical_groups_by_grouping',   n_groups                       FROM identical
UNION ALL SELECT 'identical_rows_by_grouping',     n_rows                         FROM identical
UNION ALL SELECT 'phantom_rows_by_grouping',       n_rows                         FROM phantom
UNION ALL SELECT 'orphan_rows_total',
    (SELECT COUNT(*) FROM account AS a LEFT JOIN district AS p ON p.district_id = a.district_id WHERE p.district_id IS NULL)
  + (SELECT COUNT(*) FROM client AS c LEFT JOIN district AS p ON p.district_id = c.district_id WHERE p.district_id IS NULL)
  + (SELECT COUNT(*) FROM account AS a LEFT JOIN client AS p ON p.client_id = a.owner_client_id WHERE p.client_id IS NULL)
  + (SELECT COUNT(*) FROM disp AS d LEFT JOIN client AS p ON p.client_id = d.client_id WHERE p.client_id IS NULL)
  + (SELECT COUNT(*) FROM disp AS d LEFT JOIN account AS p ON p.account_id = d.account_id WHERE p.account_id IS NULL)
  + (SELECT COUNT(*) FROM card AS c LEFT JOIN disp AS p ON p.disp_id = c.disp_id WHERE p.disp_id IS NULL)
  + (SELECT COUNT(*) FROM loan AS l LEFT JOIN account AS p ON p.account_id = l.account_id WHERE p.account_id IS NULL)
  + (SELECT COUNT(*) FROM standing_order AS o LEFT JOIN account AS p ON p.account_id = o.account_id WHERE p.account_id IS NULL)
  + (SELECT COUNT(*) FROM transactions AS x LEFT JOIN account AS p ON p.account_id = x.account_id WHERE p.account_id IS NULL)
UNION ALL SELECT 'accounts_without_exactly_one_owner',
    (SELECT COUNT(*) FROM (
        SELECT a.account_id
        FROM account AS a
        LEFT JOIN disp AS d ON d.account_id = a.account_id AND d.type = 'OWNER'
        GROUP BY a.account_id
        HAVING COUNT(d.disp_id) <> 1
     ) AS bad_owner)
UNION ALL SELECT 'accounts_without_transactions',
    (SELECT COUNT(*) FROM account AS a WHERE NOT EXISTS (SELECT 1 FROM transactions AS x WHERE x.account_id = a.account_id))
UNION ALL SELECT 'postings_before_account_opened',
    (SELECT COUNT(*) FROM transactions AS x INNER JOIN account AS a ON a.account_id = x.account_id WHERE x.trans_date < a.opened_date)
UNION ALL SELECT 'loan_status_A', (SELECT COUNT(*) FROM loan WHERE status = 'A')
UNION ALL SELECT 'loan_status_B', (SELECT COUNT(*) FROM loan WHERE status = 'B')
UNION ALL SELECT 'loan_status_C', (SELECT COUNT(*) FROM loan WHERE status = 'C')
UNION ALL SELECT 'loan_status_D', (SELECT COUNT(*) FROM loan WHERE status = 'D')
UNION ALL SELECT 'loan_status_vs_negative_balance_exceptions',
    (SELECT COUNT(*)
     FROM loan AS l
     WHERE (l.status IN ('B', 'D')) <>
           EXISTS (SELECT 1 FROM transactions AS x WHERE x.account_id = l.account_id AND x.balance < 0));
