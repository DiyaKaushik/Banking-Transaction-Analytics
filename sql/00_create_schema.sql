-- =====================================================================
-- 00_create_schema.sql
-- Banking Transaction Analytics: MySQL 8.0 schema for the cleaned data.
--
-- Run it with scripts/load_to_mysql.py (recommended) or manually in
-- MySQL Workbench. Safe to re-run: it drops and recreates every table.
--
-- Data: public Berka dataset (Czech bank, 1993-1998). Amounts are in Czech
-- koruna (CZK). Whole-number amounts and balances.
-- Note: YEAR_MONTH is a reserved word in MySQL, so the 'YYYY-MM' label is
-- stored in a column called period.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS banking_analytics DEFAULT CHARACTER SET utf8mb4;
USE banking_analytics;

-- Drop in reverse dependency order.
DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS standing_order;
DROP TABLE IF EXISTS loan;
DROP TABLE IF EXISTS card;
DROP TABLE IF EXISTS disp;
DROP TABLE IF EXISTS account;
DROP TABLE IF EXISTS client;
DROP TABLE IF EXISTS district;
DROP TABLE IF EXISTS dim_date;

-- ---------------------------------------------------------------------
-- Calendar (one row per day, filled at the end of this script)
-- ---------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key       DATE        NOT NULL,
    cal_year       SMALLINT    NOT NULL,
    cal_quarter    TINYINT     NOT NULL,
    cal_month      TINYINT     NOT NULL,
    month_name     VARCHAR(10) NOT NULL,
    period         CHAR(7)     NOT NULL COMMENT 'YYYY-MM',
    month_start    DATE        NOT NULL,
    day_of_month   TINYINT     NOT NULL,
    iso_weekday    TINYINT     NOT NULL COMMENT '1 = Monday ... 7 = Sunday',
    day_name       VARCHAR(10) NOT NULL,
    is_weekend     TINYINT(1)  NOT NULL,
    is_month_end   TINYINT(1)  NOT NULL,
    PRIMARY KEY (date_key)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- District: regional demographics (columns renamed from A2..A16)
-- ---------------------------------------------------------------------
CREATE TABLE district (
    district_id                 INT           NOT NULL,
    district_name               VARCHAR(60)   NOT NULL,
    region                      VARCHAR(30)   NOT NULL,
    population                  INT           NOT NULL,
    municipalities_under_500    INT           NOT NULL,
    municipalities_500_1999     INT           NOT NULL,
    municipalities_2000_9999    INT           NOT NULL,
    municipalities_10000_plus   INT           NOT NULL,
    cities                      INT           NOT NULL,
    urban_share_pct             DECIMAL(5,1)  NOT NULL,
    average_salary              INT           NOT NULL,
    unemployment_rate_1995      DECIMAL(5,2)  NULL,
    unemployment_rate_1996      DECIMAL(5,2)  NOT NULL,
    entrepreneurs_per_1000      INT           NOT NULL,
    crimes_1995                 INT           NULL,
    crimes_1996                 INT           NOT NULL,
    PRIMARY KEY (district_id)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Client: no exact birth date (privacy); birth year, age and age band only
-- ---------------------------------------------------------------------
CREATE TABLE client (
    client_id          INT              NOT NULL,
    gender             CHAR(1)          NOT NULL,
    birth_year         SMALLINT         NOT NULL,
    age_end_1998       TINYINT UNSIGNED NOT NULL,
    age_band_end_1998  VARCHAR(10)      NOT NULL,
    district_id        INT              NOT NULL,
    PRIMARY KEY (client_id),
    CONSTRAINT fk_client_district FOREIGN KEY (district_id) REFERENCES district (district_id),
    CONSTRAINT chk_client_gender CHECK (gender IN ('M', 'F'))
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Account: one row per account, with its owner's attributes
-- ---------------------------------------------------------------------
CREATE TABLE account (
    account_id            INT              NOT NULL,
    district_id           INT              NOT NULL,
    frequency_code        VARCHAR(30)      NOT NULL,
    frequency_label       VARCHAR(30)      NOT NULL,
    opened_date           DATE             NOT NULL,
    opened_year           SMALLINT         NOT NULL,
    owner_client_id       INT              NOT NULL,
    owner_gender          CHAR(1)          NOT NULL,
    owner_age_at_opening  TINYINT UNSIGNED NOT NULL,
    owner_age_band        VARCHAR(10)      NOT NULL,
    n_disponents          TINYINT UNSIGNED NOT NULL,
    has_loan              TINYINT(1)       NOT NULL,
    has_card              TINYINT(1)       NOT NULL,
    PRIMARY KEY (account_id),
    CONSTRAINT fk_account_district FOREIGN KEY (district_id) REFERENCES district (district_id),
    CONSTRAINT fk_account_owner FOREIGN KEY (owner_client_id) REFERENCES client (client_id)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Disp: links clients to accounts (OWNER or DISPONENT)
-- ---------------------------------------------------------------------
CREATE TABLE disp (
    disp_id     INT         NOT NULL,
    client_id   INT         NOT NULL,
    account_id  INT         NOT NULL,
    type        VARCHAR(10) NOT NULL,
    PRIMARY KEY (disp_id),
    CONSTRAINT fk_disp_client FOREIGN KEY (client_id) REFERENCES client (client_id),
    CONSTRAINT fk_disp_account FOREIGN KEY (account_id) REFERENCES account (account_id),
    CONSTRAINT chk_disp_type CHECK (type IN ('OWNER', 'DISPONENT'))
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Card
-- ---------------------------------------------------------------------
CREATE TABLE card (
    card_id     INT         NOT NULL,
    disp_id     INT         NOT NULL,
    account_id  INT         NOT NULL,
    client_id   INT         NOT NULL,
    type        VARCHAR(10) NOT NULL,
    issued      DATE        NOT NULL,
    PRIMARY KEY (card_id),
    CONSTRAINT fk_card_disp FOREIGN KEY (disp_id) REFERENCES disp (disp_id),
    CONSTRAINT fk_card_account FOREIGN KEY (account_id) REFERENCES account (account_id),
    CONSTRAINT fk_card_client FOREIGN KEY (client_id) REFERENCES client (client_id)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Loan: status is fully determined by 'balance ever negative' and 'end date
-- reaches 1999' in this data, so it is not an independent outcome.
-- ---------------------------------------------------------------------
CREATE TABLE loan (
    loan_id                        INT           NOT NULL,
    account_id                     INT           NOT NULL,
    loan_date                      DATE          NOT NULL,
    amount                         DECIMAL(12,2) NOT NULL,
    duration                       TINYINT UNSIGNED NOT NULL,
    payments                       DECIMAL(10,2) NOT NULL,
    status                         CHAR(1)       NOT NULL,
    end_date                       DATE          NOT NULL,
    status_label                   VARCHAR(20)   NOT NULL,
    is_finished                    TINYINT(1)    NOT NULL,
    first_negative_date            DATE          NULL,
    account_ever_negative_balance  TINYINT(1)    NOT NULL,
    PRIMARY KEY (loan_id),
    UNIQUE KEY uq_loan_account (account_id),
    CONSTRAINT fk_loan_account FOREIGN KEY (account_id) REFERENCES account (account_id),
    CONSTRAINT chk_loan_status CHECK (status IN ('A', 'B', 'C', 'D'))
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Standing orders (ORDER is a reserved word, so the table is standing_order)
-- ---------------------------------------------------------------------
CREATE TABLE standing_order (
    order_id        INT           NOT NULL,
    account_id      INT           NOT NULL,
    bank_to         CHAR(2)       NOT NULL,
    account_to      BIGINT        NOT NULL,
    amount          DECIMAL(10,2) NOT NULL,
    k_symbol        VARCHAR(20)   NULL,
    k_symbol_clean  VARCHAR(20)   NOT NULL,
    PRIMARY KEY (order_id),
    CONSTRAINT fk_order_account FOREIGN KEY (account_id) REFERENCES account (account_id)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Transactions: one row per posting. Raw values are kept; derived columns
-- and flags were added during cleaning (see reports/data_quality_report.md).
-- The order of postings within one day is unknown (trans_id is not
-- chronological); balance_before = balance - signed_amount works per row.
-- ---------------------------------------------------------------------
CREATE TABLE transactions (
    trans_id                  INT           NOT NULL,
    account_id                INT           NOT NULL,
    trans_date                DATE          NOT NULL,
    trans_year                SMALLINT      NOT NULL,
    trans_month               TINYINT       NOT NULL,
    period                    CHAR(7)       NOT NULL COMMENT 'YYYY-MM',
    month_start               DATE          NOT NULL,
    type                      VARCHAR(10)   NOT NULL,
    type_label                VARCHAR(20)   NOT NULL,
    direction                 VARCHAR(6)    NOT NULL,
    operation                 VARCHAR(20)   NULL,
    operation_clean           VARCHAR(20)   NOT NULL,
    k_symbol                  VARCHAR(20)   NULL,
    k_symbol_clean            VARCHAR(20)   NOT NULL,
    k_symbol_kind             VARCHAR(10)   NOT NULL COMMENT 'value, missing or space',
    transaction_category      VARCHAR(30)   NOT NULL,
    amount                    INT           NOT NULL,
    signed_amount             INT           NOT NULL,
    balance                   INT           NOT NULL,
    balance_before            INT           NOT NULL,
    partner_bank              CHAR(2)       NULL,
    partner_account           BIGINT        NULL,
    partner_account_was_zero  TINYINT(1)    NOT NULL,
    is_zero_amount            TINYINT(1)    NOT NULL,
    is_negative_balance       TINYINT(1)    NOT NULL,
    is_repeated_posting       TINYINT(1)    NOT NULL,
    repeat_group_size         SMALLINT      NOT NULL,
    possible_phantom_copy     TINYINT(1)    NOT NULL,
    account_day_rows          SMALLINT      NOT NULL,
    account_day_residual      DECIMAL(8,2)  NOT NULL,
    balance_check             VARCHAR(10)   NOT NULL,
    PRIMARY KEY (trans_id),
    KEY idx_trans_account_date (account_id, trans_date),
    KEY idx_trans_date (trans_date),
    KEY idx_trans_period (period),
    KEY idx_trans_category (transaction_category),
    CONSTRAINT fk_trans_account FOREIGN KEY (account_id) REFERENCES account (account_id),
    CONSTRAINT fk_trans_date FOREIGN KEY (trans_date) REFERENCES dim_date (date_key),
    CONSTRAINT chk_trans_amount CHECK (amount >= 0),
    CONSTRAINT chk_trans_direction CHECK (direction IN ('credit', 'debit')),
    CONSTRAINT chk_trans_balance_check CHECK (balance_check IN ('exact', 'rounding', 'review'))
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Fill the calendar for the whole data range (1993-01-01 to 1998-12-31).
-- The recursion depth must exceed the 2,191 days.
-- ---------------------------------------------------------------------
SET SESSION cte_max_recursion_depth = 5000;

INSERT INTO dim_date (
    date_key, cal_year, cal_quarter, cal_month, month_name, period, month_start,
    day_of_month, iso_weekday, day_name, is_weekend, is_month_end
)
WITH RECURSIVE days AS (
    SELECT DATE('1993-01-01') AS d
    UNION ALL
    SELECT d + INTERVAL 1 DAY FROM days WHERE d < DATE('1998-12-31')
)
SELECT
    d,
    YEAR(d),
    QUARTER(d),
    MONTH(d),
    MONTHNAME(d),
    DATE_FORMAT(d, '%Y-%m'),
    DATE_SUB(d, INTERVAL DAYOFMONTH(d) - 1 DAY),
    DAYOFMONTH(d),
    WEEKDAY(d) + 1,
    DAYNAME(d),
    WEEKDAY(d) >= 5,
    d = LAST_DAY(d)
FROM days;
