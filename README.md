
# Banking Transaction Analytics Platform

A data analytics project using **MySQL, SQL, and Python** to explore historical banking transactions, analyze financial activity, and perform data-quality validation on over one million transaction records.

## Project Overview

This project uses the historical Berka (PKDD'99) banking dataset to build a relational database and analyze transaction activity. It focuses on financial KPIs, monthly trends, data consistency, and identifying records that require further investigation.

## Technologies Used

- **Database:** MySQL
- **Programming:** Python
- **Data Analysis:** Pandas
- **Query Language:** SQL
- **Tools:** MySQL Workbench, Jupyter Notebook, Git

## Key Features

- Designed and populated a relational database with 8 interconnected tables.
- Loaded and analyzed over 1 million historical transaction records.
- Developed SQL queries to calculate transaction KPIs and examine monthly trends.
- Implemented data-quality checks and validation queries.
- Identified duplicate transaction records and investigated data inconsistencies.
- Compared transaction movements with account balance information to identify discrepancies requiring review.
- Used Python to support data validation and analytical checks.

## Data Quality & Validation

The project includes structured SQL validation across multiple stages:

| Validation Area | Checks |
|---|---:|
| Data Quality Metrics | 31 |
| Transaction KPI Checks | 84 |
| Monthly Trend Checks | 599 |

These checks help assess data consistency, transaction accuracy, and the reliability of analytical outputs.

## Key Analysis Areas

- Transaction deposits and withdrawals
- Transaction volumes and financial KPIs
- Monthly transaction trends
- Duplicate transaction detection
- Account balance reconciliation checks
- Data consistency and validation

## Dataset

The project uses the **Berka / PKDD'99 Financial Dataset**, a historical Czech banking dataset containing information about clients, accounts, transactions, loans, cards, and related banking records.

**Note:** This is a historical dataset from the Czech Republic, not a Canadian banking dataset.

## Project Structure

```text
banking-transaction-analytics/
│
├── data/
│   ├── raw/
│   └── archive_ijs/
│
├── scripts/
│   └── Python data processing scripts
│
├── sql/
│   ├── schema/
│   ├── data_quality/
│   ├── kpis/
│   └── monthly_trends/
│
├── notebooks/
│
├── reports/
│
├── README.md
└── requirements.txt
```

*Folder names may be adjusted to match the actual repository structure.*

## Learning Outcomes

- Relational database design and management
- SQL querying and financial data analysis
- Python-based data validation
- Data-quality assessment and discrepancy investigation
- KPI development and monthly trend analysis
- Organizing analytical workflows and documenting results

## Disclaimer

This project is for educational and analytical purposes. The dataset is historical, and identified anomalies or discrepancies should not automatically be interpreted as fraud or misconduct.
