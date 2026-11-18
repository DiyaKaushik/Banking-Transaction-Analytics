-- =====================================================================
-- 02_transaction_kpis.sql
-- Banking Transaction Analytics (MySQL 8.0)
--
-- Business questions
--   1. How big is the activity we are analysing (postings, value, net flow)?
--   2. Which transaction types, categories and channels account for the most activity?
--   3. How are posting sizes distributed?
--   4. Reliability: this data has NO failed or declined status, so a failure rate cannot be
--      calculated. The closest operational signal is "which postings take an account from a
--      non-negative balance below zero" (overdraft_trigger_postings). It is a proxy, not a
--      failure rate, and must be described that way in every report.
--
-- Definitions
--   posting        one row in transactions
--   value          SUM(amount) in Czech koruna (CZK); every posting counts once, whatever its direction
--   net flow       credits minus debits = SUM(signed_amount)
--   credit/debit   direction column (PRIJEM = credit; VYDAJ and VYBER = debit)
--   category       business label built in notebook 02 from k_symbol first, then operation
--                  (labels are to be confirmed against the original documentation)
--   channel group  OUR grouping of categories, not a column in the source data:
--                  Bank-generated (interest, penalty interest, service fees), Cash (deposits and
--                  withdrawals), Card (card withdrawals), Transfers and payments (everything else)
--
-- Run queries one at a time in MySQL Workbench, or use:
--     python scripts/validate_sql.py --file sql/02_transaction_kpis.sql --show NAME
--     python scripts/validate_sql.py --file sql/02_transaction_kpis.sql        (scoreboard vs pandas)
-- "Expected" values quoted in comments were found independently in Python on the full dataset.
-- =====================================================================

USE banking_analytics;


-- @query overall_kpis
-- Question: what are the headline numbers?
-- Expected: 1,056,320 postings; value 6,257,862,197; credits 405,083 / 3,227,482,664;
--           debits 651,237 / 3,030,379,533; net flow 197,103,131; average 5,924.21; 4,500 accounts;
--           1993-01-01 to 1998-12-31.
-- Technique: conditional aggregation, COUNT(DISTINCT), date columns.
SELECT
    COUNT(*)                                                       AS total_postings,
    SUM(amount)                                                    AS total_value_czk,
    SUM(direction = 'credit')                                      AS credit_postings,
    SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END)     AS credit_value_czk,
    SUM(direction = 'debit')                                       AS debit_postings,
    SUM(CASE WHEN direction = 'debit' THEN amount ELSE 0 END)      AS debit_value_czk,
    SUM(signed_amount)                                             AS net_flow_czk,
    ROUND(AVG(amount), 2)                                          AS avg_posting_value_czk,
    COUNT(DISTINCT account_id)                                     AS accounts_with_postings,
    ROUND(COUNT(*) / COUNT(DISTINCT account_id), 2)                AS avg_postings_per_account,
    MIN(trans_date)                                                AS first_posting_date,
    MAX(trans_date)                                                AS last_posting_date,
    ROUND(100 * SUM(is_negative_balance) / COUNT(*), 2)            AS negative_balance_postings_pct
FROM transactions;


-- @query kpis_by_direction
-- Question: how do credits and debits compare in number and in value?
-- Technique: window function over an aggregate (share of the total).
SELECT
    direction,
    COUNT(*)                                                         AS postings,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                 AS share_of_postings_pct,
    SUM(amount)                                                      AS total_value_czk,
    ROUND(100 * SUM(amount) / SUM(SUM(amount)) OVER (), 2)           AS share_of_value_pct,
    ROUND(AVG(amount), 2)                                            AS avg_value_czk
FROM transactions
GROUP BY direction
ORDER BY direction;


-- @query type_performance
-- Question: which transaction types carry the most postings and value?
-- Expected: VYDAJ 634,571 postings; PRIJEM 405,083; VYBER 16,666 (but VYBER has the largest average).
-- Technique: GROUP BY, RANK() window function.
SELECT
    type,
    type_label,
    COUNT(*)                                                         AS postings,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                 AS share_of_postings_pct,
    SUM(amount)                                                      AS total_value_czk,
    ROUND(100 * SUM(amount) / SUM(SUM(amount)) OVER (), 2)           AS share_of_value_pct,
    ROUND(AVG(amount), 2)                                            AS avg_value_czk,
    RANK() OVER (ORDER BY SUM(amount) DESC)                          AS value_rank
FROM transactions
GROUP BY type, type_label
ORDER BY value_rank;


-- @query category_performance
-- Question: which business categories drive activity, and how concentrated is the value?
-- cumulative_value_share_pct shows how many categories make up most of the money (Pareto view).
-- Technique: CTE, window functions (share, running total, RANK), GROUP_CONCAT.
WITH by_category AS (
    SELECT
        transaction_category,
        GROUP_CONCAT(DISTINCT direction ORDER BY direction) AS directions,
        COUNT(*)                                            AS postings,
        SUM(amount)                                         AS total_value,
        ROUND(AVG(amount), 2)                               AS avg_value
    FROM transactions
    GROUP BY transaction_category
)
SELECT
    transaction_category,
    directions,
    postings,
    ROUND(100 * postings / SUM(postings) OVER (), 2)                                  AS share_of_postings_pct,
    total_value                                                                       AS total_value_czk,
    ROUND(100 * total_value / SUM(total_value) OVER (), 2)                            AS share_of_value_pct,
    ROUND(100 * SUM(total_value) OVER (ORDER BY total_value DESC) / SUM(total_value) OVER (), 2)
                                                                                      AS cumulative_value_share_pct,
    avg_value                                                                         AS avg_value_czk,
    RANK() OVER (ORDER BY total_value DESC)                                           AS value_rank
FROM by_category
ORDER BY value_rank;


-- @query operation_vs_category
-- Question: why do we use categories and not the raw operation code as the "channel"?
-- Because service fees, penalty interest and cash withdrawals share operation codes, so the
-- operation alone would mix very different things.
-- Technique: GROUP BY on two columns.
SELECT
    operation_clean,
    transaction_category,
    COUNT(*)      AS postings,
    SUM(amount)   AS total_value_czk
FROM transactions
GROUP BY operation_clean, transaction_category
ORDER BY operation_clean, postings DESC;


-- @query channel_group_performance
-- Question: which channels account for the most activity?
-- The channel group is our own grouping of categories (see the header), not source data.
-- Technique: CTE with CASE WHEN, window functions.
WITH labeled AS (
    SELECT
        amount,
        CASE
            WHEN transaction_category IN ('Interest credited', 'Penalty interest', 'Service fees') THEN 'Bank-generated'
            WHEN transaction_category IN ('Cash deposit', 'Cash withdrawal')                       THEN 'Cash'
            WHEN transaction_category = 'Card withdrawal'                                          THEN 'Card'
            ELSE 'Transfers and payments'
        END AS channel_group
    FROM transactions
)
SELECT
    channel_group,
    COUNT(*)                                                         AS postings,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)                 AS share_of_postings_pct,
    SUM(amount)                                                      AS total_value_czk,
    ROUND(100 * SUM(amount) / SUM(SUM(amount)) OVER (), 2)           AS share_of_value_pct,
    ROUND(AVG(amount), 2)                                            AS avg_value_czk,
    RANK() OVER (ORDER BY COUNT(*) DESC)                             AS postings_rank,
    RANK() OVER (ORDER BY SUM(amount) DESC)                          AS value_rank
FROM labeled
GROUP BY channel_group
ORDER BY value_rank;


-- @query amount_percentiles_by_category
-- Question: what is a typical posting in each category, and how heavy is the upper tail?
-- MySQL has no median function, so percentiles use the nearest-rank method: the value at
-- position CEIL(p * n) when the amounts are sorted ascending.
-- Technique: ROW_NUMBER and COUNT window functions, conditional aggregation.
WITH ranked AS (
    SELECT
        transaction_category,
        amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM transactions
)
SELECT
    transaction_category,
    MAX(n)                                              AS postings,
    MIN(amount)                                         AS min_amount,
    MAX(CASE WHEN rn = CEIL(0.25 * n) THEN amount END)  AS p25,
    MAX(CASE WHEN rn = CEIL(0.50 * n) THEN amount END)  AS median,
    MAX(CASE WHEN rn = CEIL(0.75 * n) THEN amount END)  AS p75,
    MAX(CASE WHEN rn = CEIL(0.90 * n) THEN amount END)  AS p90,
    MAX(amount)                                         AS max_amount
FROM ranked
GROUP BY transaction_category
ORDER BY median DESC;


-- @query posting_size_bands
-- Question: how are posting sizes distributed, for credits and for debits?
-- Technique: CASE WHEN bands in a derived table, window share within each direction.
SELECT
    band,
    direction,
    COUNT(*)                                                                  AS postings,
    ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY direction), 2)    AS share_of_direction_postings_pct,
    SUM(amount)                                                               AS total_value_czk,
    ROUND(100 * SUM(amount) / SUM(SUM(amount)) OVER (PARTITION BY direction), 2) AS share_of_direction_value_pct
FROM (
    SELECT
        direction,
        amount,
        CASE
            WHEN amount = 0     THEN '0 zero'
            WHEN amount <= 999  THEN '1 to 999'
            WHEN amount <= 4999 THEN '1,000 to 4,999'
            WHEN amount <= 9999 THEN '5,000 to 9,999'
            WHEN amount <= 24999 THEN '10,000 to 24,999'
            ELSE '25,000 and over'
        END AS band
    FROM transactions
) AS banded
GROUP BY band, direction
ORDER BY direction, MIN(amount);


-- @query overdraft_trigger_postings
-- Question (reliability proxy): which kinds of postings take an account from a non-negative
-- balance to a negative one? This is NOT a failure rate: there is no failed-transaction status.
-- balance_before = balance - signed_amount is calculated per posting, so no ordering within a day
-- is needed. Amounts and balances are whole numbers rounded separately, so postings that land
-- within 1 of zero can be misclassified.
-- Technique: conditional aggregation, RANK() over an aggregate.
SELECT
    transaction_category,
    COUNT(*)                                                                  AS postings,
    SUM(balance_before >= 0 AND balance < 0)                                  AS overdraft_trigger_postings,
    ROUND(100 * SUM(balance_before >= 0 AND balance < 0) / COUNT(*), 3)       AS trigger_rate_pct,
    SUM(CASE WHEN balance_before >= 0 AND balance < 0 THEN amount ELSE 0 END) AS trigger_value_czk,
    RANK() OVER (ORDER BY SUM(balance_before >= 0 AND balance < 0) DESC)      AS trigger_rank
FROM transactions
GROUP BY transaction_category
ORDER BY trigger_rank, transaction_category;


-- @query scoreboard
-- Question: do MySQL's numbers agree with numbers pandas calculates independently from the raw files?
-- scripts/validate_sql.py compares every metric. Category, channel and band metrics are rebuilt in
-- pandas from the raw k_symbol / operation / amount columns.
WITH kpi AS (
    SELECT
        COUNT(*)                                                       AS total_postings,
        SUM(amount)                                                    AS total_value,
        SUM(direction = 'credit')                                      AS credit_postings,
        SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END)     AS credit_value,
        SUM(direction = 'debit')                                       AS debit_postings,
        SUM(CASE WHEN direction = 'debit' THEN amount ELSE 0 END)      AS debit_value,
        SUM(signed_amount)                                             AS net_flow,
        ROUND(AVG(amount), 2)                                          AS avg_posting_value,
        COUNT(DISTINCT account_id)                                     AS accounts_with_postings,
        ROUND(COUNT(*) / COUNT(DISTINCT account_id), 2)                AS avg_postings_per_account,
        SUM(balance_before >= 0 AND balance < 0)                       AS overdraft_trigger_postings
    FROM transactions
),
ranked AS (
    SELECT
        transaction_category,
        amount,
        ROW_NUMBER() OVER (PARTITION BY transaction_category ORDER BY amount, trans_id) AS rn,
        COUNT(*)     OVER (PARTITION BY transaction_category)                           AS n
    FROM transactions
),
labeled AS (
    SELECT
        amount,
        CASE
            WHEN transaction_category IN ('Interest credited', 'Penalty interest', 'Service fees') THEN 'Bank-generated'
            WHEN transaction_category IN ('Cash deposit', 'Cash withdrawal')                       THEN 'Cash'
            WHEN transaction_category = 'Card withdrawal'                                          THEN 'Card'
            ELSE 'Transfers and payments'
        END AS channel_group,
        CASE
            WHEN amount = 0     THEN '0 zero'
            WHEN amount <= 999  THEN '1 to 999'
            WHEN amount <= 4999 THEN '1,000 to 4,999'
            WHEN amount <= 9999 THEN '5,000 to 9,999'
            WHEN amount <= 24999 THEN '10,000 to 24,999'
            ELSE '25,000 and over'
        END AS band
    FROM transactions
)
SELECT 'total_postings' AS metric, total_postings AS value FROM kpi
UNION ALL SELECT 'total_value',                total_value                FROM kpi
UNION ALL SELECT 'credit_postings',            credit_postings            FROM kpi
UNION ALL SELECT 'credit_value',               credit_value               FROM kpi
UNION ALL SELECT 'debit_postings',             debit_postings             FROM kpi
UNION ALL SELECT 'debit_value',                debit_value                FROM kpi
UNION ALL SELECT 'net_flow',                   net_flow                   FROM kpi
UNION ALL SELECT 'avg_posting_value',          avg_posting_value          FROM kpi
UNION ALL SELECT 'accounts_with_postings',     accounts_with_postings     FROM kpi
UNION ALL SELECT 'avg_postings_per_account',   avg_postings_per_account   FROM kpi
UNION ALL SELECT 'overdraft_trigger_postings', overdraft_trigger_postings FROM kpi
UNION ALL SELECT CONCAT('type_postings|', type), COUNT(*)    FROM transactions GROUP BY type
UNION ALL SELECT CONCAT('type_value|', type),    SUM(amount) FROM transactions GROUP BY type
UNION ALL SELECT CONCAT('category_postings|', transaction_category), COUNT(*)    FROM transactions GROUP BY transaction_category
UNION ALL SELECT CONCAT('category_value|', transaction_category),    SUM(amount) FROM transactions GROUP BY transaction_category
UNION ALL SELECT CONCAT('category_overdraft_triggers|', transaction_category),
                 SUM(balance_before >= 0 AND balance < 0)
          FROM transactions GROUP BY transaction_category
UNION ALL SELECT CONCAT('category_median|', transaction_category),
                 MAX(CASE WHEN rn = CEIL(0.50 * n) THEN amount END)
          FROM ranked GROUP BY transaction_category
UNION ALL SELECT CONCAT('category_p90|', transaction_category),
                 MAX(CASE WHEN rn = CEIL(0.90 * n) THEN amount END)
          FROM ranked GROUP BY transaction_category
UNION ALL SELECT CONCAT('channel_postings|', channel_group), COUNT(*)    FROM labeled GROUP BY channel_group
UNION ALL SELECT CONCAT('channel_value|', channel_group),    SUM(amount) FROM labeled GROUP BY channel_group
UNION ALL SELECT CONCAT('band_postings|', band), COUNT(*)    FROM labeled GROUP BY band
UNION ALL SELECT CONCAT('band_value|', band),    SUM(amount) FROM labeled GROUP BY band;
