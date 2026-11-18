-- =====================================================================
-- 05_transaction_anomalies.sql
-- Banking Transaction Analytics (MySQL 8.0)
--
-- Business question: which postings, days and accounts deserve a closer look?
--
-- IMPORTANT: everything below finds UNUSUAL activity, not fraud.
--   * The data has no fraud label, so no rule can be tested against known fraud.
--   * A flag means "unusual compared with similar postings or with the account's own history".
--     Many flagged items will have an ordinary explanation. They are candidates for review only.
--   * The thresholds are parameters chosen for explainability, not tuned values.
--
-- Rules (customer-initiated postings only; bank-generated interest, fees and penalty interest are
-- calculated by the bank and are excluded)
--   R1 Large amount   posting amount is above the "far-out" fence of its own category:
--                     Q3 + 3 x (Q3 - Q1), with quartiles by the nearest-rank method. Categories whose
--                     middle half has no spread (Q3 = Q1) are skipped.
--   R2 Balance drain  a debit takes at least 80% of the balance just before it, and that balance was
--                     10,000 CZK or more (so tiny balances do not trigger it).
--                     Test: amount * 10 >= 8 * balance_before. balance_before = balance - signed_amount.
--   R3 Frequency spike an account-day with at least 5 customer-initiated postings AND at least 3 times
--                     the account's average on its active days.
--                     Test: n_day * active_days >= 3 * account_postings (integer arithmetic, exact).
--
-- Also: calendar drill-downs for the January and December peaks in cash and card withdrawals.
--
-- Run queries one at a time in MySQL Workbench, or use:
--     python scripts/validate_sql.py --file sql/05_transaction_anomalies.sql --show NAME
--     python scripts/validate_sql.py --file sql/05_transaction_anomalies.sql        (scoreboard vs pandas)
-- =====================================================================

USE banking_analytics;


-- @query rule_summary
-- Question: how many items does each rule flag, and how many accounts are involved?
-- Technique: CTE chain, window functions for quartiles, UNION ALL of the three rules.
WITH customer AS (
    SELECT trans_id, account_id, trans_date, period, transaction_category, direction, amount, balance_before
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
),
ranked AS (
    SELECT
        transaction_category, amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM customer
),
fences AS (
    SELECT
        transaction_category,
        MAX(CASE WHEN rn = CEIL(0.25 * n) THEN amount END) AS q1,
        MAX(CASE WHEN rn = CEIL(0.75 * n) THEN amount END) AS q3
    FROM ranked
    GROUP BY transaction_category
),
upper_fences AS (
    SELECT transaction_category, q3 + 3 * (q3 - q1) AS upper_fence
    FROM fences
    WHERE q3 > q1
),
large AS (
    SELECT c.account_id
    FROM customer AS c
    INNER JOIN upper_fences AS f ON f.transaction_category = c.transaction_category
    WHERE c.amount > f.upper_fence
),
drain AS (
    SELECT account_id
    FROM customer
    WHERE direction = 'debit' AND balance_before >= 10000 AND amount * 10 >= 8 * balance_before
),
day_counts AS (
    SELECT account_id, trans_date, COUNT(*) AS postings_that_day
    FROM customer
    GROUP BY account_id, trans_date
),
with_totals AS (
    SELECT
        account_id, trans_date, postings_that_day,
        SUM(postings_that_day) OVER (PARTITION BY account_id) AS account_postings,
        COUNT(*)               OVER (PARTITION BY account_id) AS account_active_days
    FROM day_counts
),
spike_days AS (
    SELECT account_id, postings_that_day
    FROM with_totals
    WHERE postings_that_day >= 5 AND postings_that_day * account_active_days >= 3 * account_postings
),
totals AS (
    SELECT COUNT(*) AS customer_postings FROM customer
)
SELECT
    'R1 large amount (3 x IQR fence)'      AS rule_name,
    'postings'                             AS unit,
    COUNT(*)                               AS flagged_items,
    COUNT(DISTINCT account_id)             AS accounts_affected,
    ROUND(100 * COUNT(*) / (SELECT customer_postings FROM totals), 3) AS share_of_customer_postings_pct
FROM large
UNION ALL
SELECT
    'R2 balance drain (80% of a balance of 10,000 or more)',
    'postings',
    COUNT(*),
    COUNT(DISTINCT account_id),
    ROUND(100 * COUNT(*) / (SELECT customer_postings FROM totals), 3)
FROM drain
UNION ALL
SELECT
    'R3 frequency spike (5 or more a day and 3 x the account average)',
    'account-days',
    COUNT(*),
    COUNT(DISTINCT account_id),
    ROUND(100 * COALESCE(SUM(postings_that_day), 0) / (SELECT customer_postings FROM totals), 3)
FROM spike_days;


-- @query amount_outlier_fences
-- Question (R1): what does "unusually large" mean in each category, and how many postings exceed it?
-- Technique: nearest-rank quartiles with ROW_NUMBER and COUNT windows, LEFT JOIN to keep categories
-- with no flagged posting.
WITH customer AS (
    SELECT trans_id, transaction_category, amount
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
),
ranked AS (
    SELECT
        transaction_category, amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM customer
),
quartiles AS (
    SELECT
        transaction_category,
        MAX(n)                                              AS postings,
        MAX(CASE WHEN rn = CEIL(0.25 * n) THEN amount END)  AS q1,
        MAX(CASE WHEN rn = CEIL(0.50 * n) THEN amount END)  AS median,
        MAX(CASE WHEN rn = CEIL(0.75 * n) THEN amount END)  AS q3
    FROM ranked
    GROUP BY transaction_category
),
fences AS (
    SELECT transaction_category, postings, q1, median, q3, q3 + 3 * (q3 - q1) AS upper_fence
    FROM quartiles
    WHERE q3 > q1
),
flagged AS (
    SELECT c.transaction_category, COUNT(*) AS flagged_postings, MAX(c.amount) AS max_amount
    FROM customer AS c
    INNER JOIN fences AS f ON f.transaction_category = c.transaction_category
    WHERE c.amount > f.upper_fence
    GROUP BY c.transaction_category
)
SELECT
    f.transaction_category,
    f.postings,
    f.q1,
    f.median,
    f.q3,
    f.upper_fence,
    COALESCE(g.flagged_postings, 0)                                       AS flagged_postings,
    ROUND(100 * COALESCE(g.flagged_postings, 0) / f.postings, 3)          AS flagged_pct,
    g.max_amount
FROM fences AS f
LEFT JOIN flagged AS g ON g.transaction_category = f.transaction_category
ORDER BY flagged_postings DESC, f.transaction_category;


-- @query amount_outliers_top
-- Question (R1): which are the 20 most extreme postings relative to their category's fence?
-- Technique: CTE chain, JOIN on a derived threshold, ORDER BY a ratio, LIMIT.
WITH customer AS (
    SELECT trans_id, account_id, trans_date, transaction_category, amount
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
),
ranked AS (
    SELECT
        transaction_category, amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM customer
),
fences AS (
    SELECT
        transaction_category,
        MAX(CASE WHEN rn = CEIL(0.25 * n) THEN amount END) AS q1,
        MAX(CASE WHEN rn = CEIL(0.75 * n) THEN amount END) AS q3
    FROM ranked
    GROUP BY transaction_category
),
upper_fences AS (
    SELECT transaction_category, q3 + 3 * (q3 - q1) AS upper_fence
    FROM fences
    WHERE q3 > q1
)
SELECT
    c.trans_id, c.account_id, c.trans_date, c.transaction_category, c.amount, f.upper_fence,
    ROUND(c.amount / f.upper_fence, 2) AS times_the_fence
FROM customer AS c
INNER JOIN upper_fences AS f ON f.transaction_category = c.transaction_category
WHERE c.amount > f.upper_fence
ORDER BY times_the_fence DESC, c.amount DESC, c.trans_id
LIMIT 20;


-- @query balance_drain_by_category
-- Question (R2): which debit categories most often take 80% or more of an account's balance at once?
-- Technique: conditional aggregation and AVG over a CASE.
SELECT
    transaction_category,
    COUNT(*)                                                                         AS debit_postings,
    SUM(balance_before >= 10000 AND amount * 10 >= 8 * balance_before)               AS drain_postings,
    ROUND(100 * SUM(balance_before >= 10000 AND amount * 10 >= 8 * balance_before) / COUNT(*), 3)
                                                                                     AS drain_pct_of_debits,
    ROUND(AVG(CASE WHEN balance_before >= 10000 AND amount * 10 >= 8 * balance_before
                   THEN 100.0 * amount / balance_before END), 1)                     AS avg_pct_of_balance_taken
FROM transactions
WHERE direction = 'debit'
  AND transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
GROUP BY transaction_category
ORDER BY drain_postings DESC, transaction_category;


-- @query balance_drain_top
-- Question (R2): which are the 20 largest balance drains? (largest amounts first)
-- Technique: filter on a derived condition, computed percentage, ORDER BY with a tie-breaker, LIMIT.
SELECT
    trans_id, account_id, trans_date, transaction_category, amount, balance_before,
    ROUND(100 * amount / balance_before, 1) AS pct_of_balance_taken
FROM transactions
WHERE direction = 'debit'
  AND transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
  AND balance_before >= 10000
  AND amount * 10 >= 8 * balance_before
ORDER BY amount DESC, trans_id
LIMIT 20;


-- @query frequency_spike_days_by_month
-- Question (R3): in which months do unusually busy account-days cluster?
-- Technique: calendar LEFT JOIN so months without spikes still appear, CTE chain with window totals.
WITH day_counts AS (
    SELECT account_id, trans_date, COUNT(*) AS postings_that_day
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
    GROUP BY account_id, trans_date
),
with_totals AS (
    SELECT
        account_id, trans_date, postings_that_day,
        SUM(postings_that_day) OVER (PARTITION BY account_id) AS account_postings,
        COUNT(*)               OVER (PARTITION BY account_id) AS account_active_days
    FROM day_counts
),
spike_days AS (
    SELECT account_id, trans_date, postings_that_day
    FROM with_totals
    WHERE postings_that_day >= 5 AND postings_that_day * account_active_days >= 3 * account_postings
)
SELECT
    d.period,
    COUNT(s.account_id)                  AS spike_account_days,
    COUNT(DISTINCT s.account_id)         AS accounts_with_spike,
    COALESCE(SUM(s.postings_that_day), 0) AS postings_in_spike_days
FROM dim_date AS d
LEFT JOIN spike_days AS s ON s.trans_date = d.date_key
GROUP BY d.period
ORDER BY d.period;


-- @query frequency_spike_top_days
-- Question (R3): which 20 account-days are the busiest relative to the account's own habit?
-- times_account_average = the day's postings divided by the account's average on its active days.
WITH day_counts AS (
    SELECT account_id, trans_date, COUNT(*) AS postings_that_day
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
    GROUP BY account_id, trans_date
),
with_totals AS (
    SELECT
        account_id, trans_date, postings_that_day,
        SUM(postings_that_day) OVER (PARTITION BY account_id) AS account_postings,
        COUNT(*)               OVER (PARTITION BY account_id) AS account_active_days
    FROM day_counts
)
SELECT
    account_id, trans_date, postings_that_day, account_active_days,
    ROUND(postings_that_day * account_active_days / account_postings, 1) AS times_account_average
FROM with_totals
WHERE postings_that_day >= 5 AND postings_that_day * account_active_days >= 3 * account_postings
ORDER BY times_account_average DESC, postings_that_day DESC, account_id, trans_date
LIMIT 20;


-- @query rules_triggered_distribution
-- Question: how many accounts trigger none, one, two or all three rules?
-- Technique: LEFT JOINs of three aggregated subqueries onto account, boolean arithmetic.
WITH customer AS (
    SELECT trans_id, account_id, trans_date, transaction_category, direction, amount, balance_before
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
),
ranked AS (
    SELECT
        transaction_category, amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM customer
),
fences AS (
    SELECT
        transaction_category,
        MAX(CASE WHEN rn = CEIL(0.25 * n) THEN amount END) AS q1,
        MAX(CASE WHEN rn = CEIL(0.75 * n) THEN amount END) AS q3
    FROM ranked
    GROUP BY transaction_category
),
upper_fences AS (
    SELECT transaction_category, q3 + 3 * (q3 - q1) AS upper_fence
    FROM fences
    WHERE q3 > q1
),
day_counts AS (
    SELECT account_id, trans_date, COUNT(*) AS postings_that_day
    FROM customer
    GROUP BY account_id, trans_date
),
with_totals AS (
    SELECT
        account_id, trans_date, postings_that_day,
        SUM(postings_that_day) OVER (PARTITION BY account_id) AS account_postings,
        COUNT(*)               OVER (PARTITION BY account_id) AS account_active_days
    FROM day_counts
),
account_flags AS (
    SELECT
        a.account_id,
        COALESCE(l.n, 0) AS large_amount_postings,
        COALESCE(r.n, 0) AS balance_drain_postings,
        COALESCE(s.n, 0) AS spike_days
    FROM account AS a
    LEFT JOIN (
        SELECT c.account_id, COUNT(*) AS n
        FROM customer AS c
        INNER JOIN upper_fences AS f ON f.transaction_category = c.transaction_category
        WHERE c.amount > f.upper_fence
        GROUP BY c.account_id
    ) AS l ON l.account_id = a.account_id
    LEFT JOIN (
        SELECT account_id, COUNT(*) AS n
        FROM customer
        WHERE direction = 'debit' AND balance_before >= 10000 AND amount * 10 >= 8 * balance_before
        GROUP BY account_id
    ) AS r ON r.account_id = a.account_id
    LEFT JOIN (
        SELECT account_id, COUNT(*) AS n
        FROM with_totals
        WHERE postings_that_day >= 5 AND postings_that_day * account_active_days >= 3 * account_postings
        GROUP BY account_id
    ) AS s ON s.account_id = a.account_id
)
SELECT
    (large_amount_postings > 0) + (balance_drain_postings > 0) + (spike_days > 0) AS rules_triggered,
    COUNT(*)                                                                       AS accounts,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                               AS share_of_accounts_pct
FROM account_flags
GROUP BY rules_triggered
ORDER BY rules_triggered;


-- @query withdrawals_by_year_and_month
-- Question: are the January and December peaks in cash and card withdrawals present in every year?
-- Postings per calendar month, one row per category and year.
-- Technique: pivot with conditional aggregation (columns m01 to m12 avoid reserved words such as DEC).
SELECT
    transaction_category,
    trans_year,
    SUM(trans_month = 1)  AS m01, SUM(trans_month = 2)  AS m02, SUM(trans_month = 3)  AS m03,
    SUM(trans_month = 4)  AS m04, SUM(trans_month = 5)  AS m05, SUM(trans_month = 6)  AS m06,
    SUM(trans_month = 7)  AS m07, SUM(trans_month = 8)  AS m08, SUM(trans_month = 9)  AS m09,
    SUM(trans_month = 10) AS m10, SUM(trans_month = 11) AS m11, SUM(trans_month = 12) AS m12,
    COUNT(*)              AS year_total
FROM transactions
WHERE transaction_category IN ('Cash withdrawal', 'Card withdrawal')
GROUP BY transaction_category, trans_year
ORDER BY transaction_category, trans_year;


-- @query january_day_of_month_profile
-- Question: on which days of the month does the January excess happen?
-- january_postings covers the six Januaries; avg_postings_other_month is the average over the other
-- eleven calendar months (also six years each). Days 29 to 31 exist in fewer months, so read their
-- ratios with care.
-- Technique: CTE with a boolean flag, conditional sums, NULLIF for the ratio.
WITH withdrawals AS (
    SELECT t.transaction_category, d.day_of_month, (d.cal_month = 1) AS is_january
    FROM transactions AS t
    INNER JOIN dim_date AS d ON d.date_key = t.trans_date
    WHERE t.transaction_category IN ('Cash withdrawal', 'Card withdrawal')
)
SELECT
    transaction_category,
    day_of_month,
    SUM(is_january)                                                          AS january_postings,
    ROUND(SUM(1 - is_january) / 11, 1)                                       AS avg_postings_other_month,
    ROUND(SUM(is_january) / NULLIF(SUM(1 - is_january) / 11, 0), 2)          AS january_vs_other_ratio
FROM withdrawals
GROUP BY transaction_category, day_of_month
ORDER BY transaction_category, day_of_month;


-- @query scoreboard
-- Question: do MySQL's rule results agree with pandas, rebuilt from the raw files?
-- scripts/validate_sql.py recreates the categories, the nearest-rank quartiles, the three rules, the
-- account-level rule counts and the calendar tables independently.
WITH customer AS (
    SELECT trans_id, account_id, trans_date, period, transaction_category, direction, amount, balance_before
    FROM transactions
    WHERE transaction_category NOT IN ('Interest credited', 'Penalty interest', 'Service fees')
),
ranked AS (
    SELECT
        transaction_category, amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM customer
),
fences AS (
    SELECT
        transaction_category,
        MAX(CASE WHEN rn = CEIL(0.25 * n) THEN amount END) AS q1,
        MAX(CASE WHEN rn = CEIL(0.75 * n) THEN amount END) AS q3
    FROM ranked
    GROUP BY transaction_category
),
upper_fences AS (
    SELECT transaction_category, q1, q3, q3 + 3 * (q3 - q1) AS upper_fence
    FROM fences
    WHERE q3 > q1
),
large AS (
    SELECT c.account_id, c.transaction_category
    FROM customer AS c
    INNER JOIN upper_fences AS f ON f.transaction_category = c.transaction_category
    WHERE c.amount > f.upper_fence
),
drain AS (
    SELECT account_id, transaction_category
    FROM customer
    WHERE direction = 'debit' AND balance_before >= 10000 AND amount * 10 >= 8 * balance_before
),
day_counts AS (
    SELECT account_id, trans_date, period, COUNT(*) AS postings_that_day
    FROM customer
    GROUP BY account_id, trans_date, period
),
with_totals AS (
    SELECT
        account_id, trans_date, period, postings_that_day,
        SUM(postings_that_day) OVER (PARTITION BY account_id) AS account_postings,
        COUNT(*)               OVER (PARTITION BY account_id) AS account_active_days
    FROM day_counts
),
spike_days AS (
    SELECT account_id, trans_date, period, postings_that_day
    FROM with_totals
    WHERE postings_that_day >= 5 AND postings_that_day * account_active_days >= 3 * account_postings
),
account_flags AS (
    SELECT
        a.account_id,
        COALESCE(l.n, 0) AS large_amount_postings,
        COALESCE(r.n, 0) AS balance_drain_postings,
        COALESCE(s.n, 0) AS spike_days
    FROM account AS a
    LEFT JOIN (SELECT account_id, COUNT(*) AS n FROM large GROUP BY account_id) AS l ON l.account_id = a.account_id
    LEFT JOIN (SELECT account_id, COUNT(*) AS n FROM drain GROUP BY account_id) AS r ON r.account_id = a.account_id
    LEFT JOIN (SELECT account_id, COUNT(*) AS n FROM spike_days GROUP BY account_id) AS s ON s.account_id = a.account_id
),
rules_per_account AS (
    SELECT (large_amount_postings > 0) + (balance_drain_postings > 0) + (spike_days > 0) AS rules_triggered
    FROM account_flags
),
january AS (
    SELECT t.transaction_category, d.day_of_month, (d.cal_month = 1) AS is_january
    FROM transactions AS t
    INNER JOIN dim_date AS d ON d.date_key = t.trans_date
    WHERE t.transaction_category IN ('Cash withdrawal', 'Card withdrawal')
),
monthly_spikes AS (
    SELECT d.period, COUNT(s.account_id) AS spike_account_days
    FROM dim_date AS d
    LEFT JOIN spike_days AS s ON s.trans_date = d.date_key
    GROUP BY d.period
)
SELECT 'customer_postings_total' AS metric, COUNT(*) AS value FROM customer
UNION ALL SELECT 'r1_flagged_postings',          COUNT(*)                   FROM large
UNION ALL SELECT 'r1_accounts',                  COUNT(DISTINCT account_id) FROM large
UNION ALL SELECT 'r2_flagged_postings',          COUNT(*)                   FROM drain
UNION ALL SELECT 'r2_accounts',                  COUNT(DISTINCT account_id) FROM drain
UNION ALL SELECT 'r3_spike_days',                COUNT(*)                   FROM spike_days
UNION ALL SELECT 'r3_accounts',                  COUNT(DISTINCT account_id) FROM spike_days
UNION ALL SELECT 'r3_postings_in_spike_days',    COALESCE(SUM(postings_that_day), 0) FROM spike_days
UNION ALL SELECT CONCAT('r1_q1|', transaction_category),         q1          FROM upper_fences
UNION ALL SELECT CONCAT('r1_q3|', transaction_category),         q3          FROM upper_fences
UNION ALL SELECT CONCAT('r1_fence|', transaction_category),      upper_fence FROM upper_fences
UNION ALL SELECT CONCAT('r1_flagged|', transaction_category),    COUNT(*)    FROM large GROUP BY transaction_category
UNION ALL SELECT CONCAT('r2_flagged|', transaction_category),    COUNT(*)    FROM drain GROUP BY transaction_category
UNION ALL SELECT CONCAT('r3_spike_days|', period), spike_account_days FROM monthly_spikes
UNION ALL SELECT CONCAT('rules_triggered_accounts|', rules_triggered), COUNT(*) FROM rules_per_account GROUP BY rules_triggered
UNION ALL SELECT CONCAT('withdrawals|', transaction_category, '|', trans_year, '|', trans_month), COUNT(*)
          FROM transactions
          WHERE transaction_category IN ('Cash withdrawal', 'Card withdrawal')
          GROUP BY transaction_category, trans_year, trans_month
UNION ALL SELECT CONCAT('jan_postings|', transaction_category, '|', day_of_month),   SUM(is_january)     FROM january GROUP BY transaction_category, day_of_month
UNION ALL SELECT CONCAT('other_postings|', transaction_category, '|', day_of_month), SUM(1 - is_january) FROM january GROUP BY transaction_category, day_of_month;
