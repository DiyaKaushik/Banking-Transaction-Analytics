-- =====================================================================
-- 03_monthly_trends.sql
-- Banking Transaction Analytics (MySQL 8.0)
--
-- Business questions
--   1. How do transaction volume and value change over time (month by month and year by year)?
--   2. How much of that change is simply a growing account base? Accounts were opened between
--      1993 and 1997 and none after 1997-12-29, so raw growth in 1993-1997 is partly "more accounts".
--      1998 is the first year with a fixed account base.
--   3. Are there seasonal, weekday or month-end patterns?
--   4. Reliability over time: there is no failed-transaction status, so the proxy is the monthly
--      number of postings that take an account from non-negative to negative (overdraft triggers).
--
-- Notes
--   * Monthly series are built from dim_date with a LEFT JOIN, so a month without postings would still
--     appear (with zeros). In this data every day has at least one posting.
--   * period is the 'YYYY-MM' label (YEAR_MONTH is a reserved word in MySQL).
--   * Currency: Czech koruna (CZK). Percent changes are rounded to 2 decimals.
--   * "Expected" values quoted in comments were found independently in Python on the full dataset.
--
-- Run queries one at a time in MySQL Workbench, or use:
--     python scripts/validate_sql.py --file sql/03_monthly_trends.sql --show NAME
--     python scripts/validate_sql.py --file sql/03_monthly_trends.sql        (scoreboard vs pandas)
-- =====================================================================

USE banking_analytics;


-- @query monthly_summary
-- Question: what does each month look like in postings, value and active accounts?
-- Expected: 72 rows (1993-01 to 1998-12); the monthly net flows add up to 197,103,131.
-- Technique: LEFT JOIN from the calendar (complete series), conditional aggregation, COALESCE.
SELECT
    d.period,
    COUNT(t.trans_id)                                                       AS postings,
    COUNT(DISTINCT t.account_id)                                            AS active_accounts,
    COALESCE(SUM(t.amount), 0)                                              AS total_value_czk,
    COALESCE(SUM(CASE WHEN t.direction = 'credit' THEN t.amount END), 0)    AS credit_value_czk,
    COALESCE(SUM(CASE WHEN t.direction = 'debit'  THEN t.amount END), 0)    AS debit_value_czk,
    COALESCE(SUM(t.signed_amount), 0)                                       AS net_flow_czk,
    ROUND(AVG(t.amount), 2)                                                 AS avg_posting_value_czk
FROM dim_date AS d
LEFT JOIN transactions AS t ON t.trans_date = d.date_key
GROUP BY d.period
ORDER BY d.period;


-- @query month_over_month
-- Question: how fast do volume and value change from month to month and from year to year?
-- value_mom_pct compares with the previous month, value_yoy_pct with the same month a year earlier
-- (LAG 12). The 3-month moving average smooths month-end and calendar effects.
-- Technique: named window, LAG(), moving-average frame, NULLIF to avoid dividing by zero.
WITH monthly AS (
    SELECT
        d.period,
        COUNT(t.trans_id)            AS postings,
        COALESCE(SUM(t.amount), 0)   AS total_value
    FROM dim_date AS d
    LEFT JOIN transactions AS t ON t.trans_date = d.date_key
    GROUP BY d.period
)
SELECT
    period,
    postings,
    ROUND(100 * (postings - LAG(postings) OVER w) / NULLIF(LAG(postings) OVER w, 0), 2)         AS postings_mom_pct,
    total_value                                                                                 AS total_value_czk,
    ROUND(100 * (total_value - LAG(total_value) OVER w) / NULLIF(LAG(total_value) OVER w, 0), 2) AS value_mom_pct,
    ROUND(100 * (total_value - LAG(total_value, 12) OVER w) / NULLIF(LAG(total_value, 12) OVER w, 0), 2)
                                                                                                AS value_yoy_pct,
    ROUND(AVG(total_value) OVER (ORDER BY period ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 0)  AS value_3m_moving_avg_czk
FROM monthly
WINDOW w AS (ORDER BY period)
ORDER BY period;


-- @query yearly_summary
-- Question: how did each year compare, and how much is explained by the number of accounts?
-- accounts_opened_by_year_end is the account base at the end of the year.
-- Technique: CTEs, LEFT JOIN, LAG over years, per-account ratios.
WITH yearly AS (
    SELECT
        d.cal_year,
        COUNT(t.trans_id)            AS postings,
        COUNT(DISTINCT t.account_id) AS active_accounts,
        COALESCE(SUM(t.amount), 0)   AS total_value
    FROM dim_date AS d
    LEFT JOIN transactions AS t ON t.trans_date = d.date_key
    GROUP BY d.cal_year
),
base AS (
    SELECT y.cal_year, COUNT(a.account_id) AS accounts_opened_by_year_end
    FROM (SELECT DISTINCT cal_year FROM dim_date) AS y
    LEFT JOIN account AS a ON a.opened_year <= y.cal_year
    GROUP BY y.cal_year
)
SELECT
    yearly.cal_year,
    yearly.postings,
    ROUND(100 * (yearly.postings - LAG(yearly.postings) OVER (ORDER BY yearly.cal_year))
          / NULLIF(LAG(yearly.postings) OVER (ORDER BY yearly.cal_year), 0), 2)       AS postings_yoy_pct,
    yearly.total_value                                                                AS total_value_czk,
    ROUND(100 * (yearly.total_value - LAG(yearly.total_value) OVER (ORDER BY yearly.cal_year))
          / NULLIF(LAG(yearly.total_value) OVER (ORDER BY yearly.cal_year), 0), 2)    AS value_yoy_pct,
    yearly.active_accounts,
    base.accounts_opened_by_year_end,
    ROUND(yearly.postings / NULLIF(base.accounts_opened_by_year_end, 0), 1)           AS postings_per_open_account,
    ROUND(yearly.total_value / NULLIF(base.accounts_opened_by_year_end, 0), 0)        AS value_per_open_account_czk
FROM yearly
INNER JOIN base ON base.cal_year = yearly.cal_year
ORDER BY yearly.cal_year;


-- @query account_base_growth
-- Question: how many accounts are open each month, and how active are they?
-- postings_per_open_account removes the effect of a growing account base.
-- Technique: two CTEs joined on period, cumulative SUM() OVER, ratios with NULLIF.
WITH opened AS (
    SELECT d.period, COUNT(a.account_id) AS accounts_opened
    FROM dim_date AS d
    LEFT JOIN account AS a ON a.opened_date = d.date_key
    GROUP BY d.period
),
activity AS (
    SELECT d.period, COUNT(t.trans_id) AS postings, COUNT(DISTINCT t.account_id) AS active_accounts
    FROM dim_date AS d
    LEFT JOIN transactions AS t ON t.trans_date = d.date_key
    GROUP BY d.period
)
SELECT
    o.period,
    o.accounts_opened,
    SUM(o.accounts_opened) OVER (ORDER BY o.period)                                                  AS open_accounts_at_month_end,
    a.postings,
    a.active_accounts,
    ROUND(a.postings / NULLIF(SUM(o.accounts_opened) OVER (ORDER BY o.period), 0), 2)                AS postings_per_open_account,
    ROUND(100 * a.active_accounts / NULLIF(SUM(o.accounts_opened) OVER (ORDER BY o.period), 0), 1)   AS active_share_pct
FROM opened AS o
INNER JOIN activity AS a ON a.period = o.period
ORDER BY o.period;


-- @query seasonality_by_calendar_month
-- Question: are some calendar months busier than others once the account base is accounted for?
-- seasonality_index is the month's average postings per open account divided by the average of all
-- twelve months (1.000 = average). Months before the first account opens are skipped.
-- Technique: CTEs, AVG over AVG with a window, grouping by calendar month.
WITH opened AS (
    SELECT d.period, d.cal_month, d.month_name, COUNT(a.account_id) AS accounts_opened
    FROM dim_date AS d
    LEFT JOIN account AS a ON a.opened_date = d.date_key
    GROUP BY d.period, d.cal_month, d.month_name
),
activity AS (
    SELECT d.period, COUNT(t.trans_id) AS postings
    FROM dim_date AS d
    LEFT JOIN transactions AS t ON t.trans_date = d.date_key
    GROUP BY d.period
),
rate AS (
    SELECT
        o.cal_month,
        o.month_name,
        a.postings / NULLIF(SUM(o.accounts_opened) OVER (ORDER BY o.period), 0) AS postings_per_open_account
    FROM opened AS o
    INNER JOIN activity AS a ON a.period = o.period
)
SELECT
    cal_month,
    month_name,
    ROUND(AVG(postings_per_open_account), 2)                                            AS avg_postings_per_open_account,
    ROUND(AVG(postings_per_open_account) / AVG(AVG(postings_per_open_account)) OVER (), 3) AS seasonality_index
FROM rate
WHERE postings_per_open_account IS NOT NULL
GROUP BY cal_month, month_name
ORDER BY cal_month;


-- @query weekday_pattern
-- Question: on which weekdays do postings happen, and how much on weekends?
-- Technique: calendar LEFT JOIN, window share, COUNT(DISTINCT) of calendar days.
SELECT
    d.iso_weekday,
    d.day_name,
    COUNT(t.trans_id)                                                              AS postings,
    ROUND(100 * COUNT(t.trans_id) / SUM(COUNT(t.trans_id)) OVER (), 2)             AS share_of_postings_pct,
    COALESCE(SUM(t.amount), 0)                                                     AS total_value_czk,
    COUNT(DISTINCT d.date_key)                                                     AS calendar_days,
    ROUND(COUNT(t.trans_id) / COUNT(DISTINCT d.date_key), 1)                       AS postings_per_calendar_day
FROM dim_date AS d
LEFT JOIN transactions AS t ON t.trans_date = d.date_key
GROUP BY d.iso_weekday, d.day_name
ORDER BY d.iso_weekday;


-- @query month_end_pattern
-- Question: which kinds of postings cluster on the last day of the month?
-- Technique: INNER JOIN to the calendar, conditional aggregation, ORDER BY a ratio.
SELECT
    t.transaction_category,
    COUNT(*)                                          AS postings,
    SUM(d.is_month_end)                               AS postings_on_month_end,
    ROUND(100 * SUM(d.is_month_end) / COUNT(*), 1)    AS month_end_share_pct
FROM transactions AS t
INNER JOIN dim_date AS d ON d.date_key = t.trans_date
GROUP BY t.transaction_category
ORDER BY month_end_share_pct DESC, t.transaction_category;


-- @query overdraft_trend
-- Question (reliability proxy): how does the number of postings that push an account below zero
-- change over time? This is NOT a failure rate (no failed-transaction status exists).
-- balance_before = balance - signed_amount per posting, so no order within a day is needed.
-- Technique: conditional aggregation per month, rate per 1,000 postings.
SELECT
    t.period,
    COUNT(*)                                                                    AS postings,
    SUM(t.balance_before >= 0 AND t.balance < 0)                                AS overdraft_trigger_postings,
    ROUND(1000 * SUM(t.balance_before >= 0 AND t.balance < 0) / COUNT(*), 2)    AS triggers_per_1000_postings,
    SUM(t.is_negative_balance)                                                  AS negative_balance_postings,
    SUM(t.transaction_category = 'Penalty interest')                            AS penalty_interest_postings
FROM transactions AS t
GROUP BY t.period
ORDER BY t.period;


-- @query top_and_bottom_months
-- Question: which five months had the most and the least value? (Early months are low mainly
-- because few accounts existed yet; compare with account_base_growth before drawing conclusions.)
-- Technique: two ROW_NUMBER() rankings in one CTE.
WITH monthly AS (
    SELECT period, COUNT(*) AS postings, SUM(amount) AS total_value
    FROM transactions
    GROUP BY period
),
ranked AS (
    SELECT
        period, postings, total_value,
        ROW_NUMBER() OVER (ORDER BY total_value DESC) AS rn_top,
        ROW_NUMBER() OVER (ORDER BY total_value ASC)  AS rn_bottom
    FROM monthly
)
SELECT
    CASE WHEN rn_top <= 5 THEN 'top 5' ELSE 'bottom 5' END AS ranking,
    period,
    postings,
    total_value AS total_value_czk
FROM ranked
WHERE rn_top <= 5 OR rn_bottom <= 5
ORDER BY CASE WHEN rn_top <= 5 THEN 0 ELSE 1 END, total_value DESC;


-- @query category_seasonality
-- Question: which categories drive the busy and quiet calendar months (for example the January spike)?
-- index_vs_category_average = postings in that calendar month / the category's average over the 12 months
-- (1.00 = average). Only months at least 25% above or below average are listed.
-- Each calendar month is counted six times (1993-1998). The account base grew during 1993-1997,
-- which slightly favours later months, so treat small differences with care.
-- Technique: two CTEs, AVG() OVER (PARTITION BY ...), filtering on a window result.
WITH by_month AS (
    SELECT t.transaction_category, d.cal_month, d.month_name, COUNT(*) AS postings
    FROM transactions AS t
    INNER JOIN dim_date AS d ON d.date_key = t.trans_date
    GROUP BY t.transaction_category, d.cal_month, d.month_name
),
indexed AS (
    SELECT
        transaction_category, cal_month, month_name, postings,
        ROUND(postings / AVG(postings) OVER (PARTITION BY transaction_category), 2) AS index_vs_category_average
    FROM by_month
)
SELECT transaction_category, cal_month, month_name, postings, index_vs_category_average
FROM indexed
WHERE index_vs_category_average >= 1.25 OR index_vs_category_average <= 0.75
ORDER BY transaction_category, cal_month;


-- @query scoreboard
-- Question: do MySQL's monthly, yearly and calendar numbers agree with pandas on the raw files?
-- scripts/validate_sql.py compares every metric. Percent changes are compared with a tolerance of
-- 0.011 because both sides round to 2 decimals.
WITH monthly AS (
    SELECT
        d.period,
        COUNT(t.trans_id)                                                   AS postings,
        COUNT(DISTINCT t.account_id)                                        AS active_accounts,
        COALESCE(SUM(t.amount), 0)                                          AS total_value,
        COALESCE(SUM(t.signed_amount), 0)                                   AS net_flow,
        COALESCE(SUM(t.balance_before >= 0 AND t.balance < 0), 0)           AS overdraft_triggers
    FROM dim_date AS d
    LEFT JOIN transactions AS t ON t.trans_date = d.date_key
    GROUP BY d.period
),
opened AS (
    SELECT d.period, COUNT(a.account_id) AS accounts_opened
    FROM dim_date AS d
    LEFT JOIN account AS a ON a.opened_date = d.date_key
    GROUP BY d.period
),
changes AS (
    SELECT
        period,
        ROUND(100 * (total_value - LAG(total_value) OVER w) / NULLIF(LAG(total_value) OVER w, 0), 2)     AS value_mom_pct,
        ROUND(100 * (total_value - LAG(total_value, 12) OVER w) / NULLIF(LAG(total_value, 12) OVER w, 0), 2) AS value_yoy_pct
    FROM monthly
    WINDOW w AS (ORDER BY period)
)
SELECT CONCAT('monthly_postings|', period) AS metric, postings AS value FROM monthly
UNION ALL SELECT CONCAT('monthly_active_accounts|', period),     active_accounts    FROM monthly
UNION ALL SELECT CONCAT('monthly_value|', period),               total_value        FROM monthly
UNION ALL SELECT CONCAT('monthly_net_flow|', period),            net_flow           FROM monthly
UNION ALL SELECT CONCAT('monthly_overdraft_triggers|', period),  overdraft_triggers FROM monthly
UNION ALL SELECT CONCAT('open_accounts|', period), SUM(accounts_opened) OVER (ORDER BY period) FROM opened
UNION ALL SELECT CONCAT('value_mom_pct|', period), value_mom_pct FROM changes WHERE value_mom_pct IS NOT NULL
UNION ALL SELECT CONCAT('value_yoy_pct|', period), value_yoy_pct FROM changes WHERE value_yoy_pct IS NOT NULL
UNION ALL SELECT CONCAT('yearly_postings|', trans_year),  COUNT(*)                     FROM transactions GROUP BY trans_year
UNION ALL SELECT CONCAT('yearly_value|', trans_year),     SUM(amount)                  FROM transactions GROUP BY trans_year
UNION ALL SELECT CONCAT('yearly_active_accounts|', trans_year), COUNT(DISTINCT account_id) FROM transactions GROUP BY trans_year
UNION ALL SELECT CONCAT('weekday_postings|', d.iso_weekday), COUNT(*)
          FROM transactions AS t INNER JOIN dim_date AS d ON d.date_key = t.trans_date GROUP BY d.iso_weekday
UNION ALL SELECT CONCAT('month_end_postings|', t.transaction_category), SUM(d.is_month_end)
          FROM transactions AS t INNER JOIN dim_date AS d ON d.date_key = t.trans_date GROUP BY t.transaction_category;
