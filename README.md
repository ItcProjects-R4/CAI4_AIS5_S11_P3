# ITC E-Commerce Data Warehouse
### Enterprise-Grade Modern Data Warehouse on Azure SQL

---

## PROJECT OVERVIEW

This project implements a complete, production-quality Data Warehouse solution
for the ITC E-Commerce dataset. It transforms raw transactional CSV data
into a fully modelled Star Schema optimised for business intelligence and analytics.

**Dataset**: 2,000 order line items | 1,283 customers | 100 products | 4 categories | 5 Egyptian cities | 2021–2025

---

## ARCHITECTURE OVERVIEW

```
┌─────────────────────────────────────────────────────────────────────┐
│                    ITC DATA WAREHOUSE ARCHITECTURE                   │
├─────────────────┬───────────────────────────────────────────────────┤
│   SOURCE        │  CSV File: ITC_ecommerce_2000_rows.csv             │
│   SYSTEM        │  14 columns: orders, customers, products           │
├─────────────────┴───────────────────────────────────────────────────┤
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │  LAYER 1: RAW  (schema: raw)                                 │  │
│   │  • Exact copy of source — no transformations                 │  │
│   │  • All columns VARCHAR — guaranteed zero-rejection loads      │  │
│   │  • Append-only — full audit trail of every load              │  │
│   │  • Table: raw.ecommerce_orders                               │  │
│   └─────────────────────────────┬────────────────────────────────┘  │
│                                 │ ETL: extract_clean.py              │
│   ┌─────────────────────────────▼────────────────────────────────┐  │
│   │  LAYER 2: STAGING  (schema: staging)                         │  │
│   │  • Typed, cleaned, deduplicated working tables               │  │
│   │  • Computed DQ flags, derived columns                        │  │
│   │  • Truncate-reload on each ETL run                           │  │
│   │  • Table: staging.order_items                                │  │
│   └─────────────────────────────┬────────────────────────────────┘  │
│                                 │ ETL: transform.py                  │
│   ┌─────────────────────────────▼────────────────────────────────┐  │
│   │  LAYER 3: DATA WAREHOUSE  (schema: dw)                       │  │
│   │                                                              │  │
│   │  DIMENSIONS (slow-changing descriptive data):                │  │
│   │    dim_date       — 4,018 calendar days (2019–2030)          │  │
│   │    dim_customer   — 1,283 unique customers + segments        │  │
│   │    dim_product    — 100 products with price bands            │  │
│   │    dim_geography  — 5 Egyptian cities with coordinates       │  │
│   │    dim_channel    — 6 marketing/sales channels               │  │
│   │                                                              │  │
│   │  FACTS (measurable business events):                         │  │
│   │    fact_order_items              — 2,000 line items (grain)  │  │
│   │    fact_order_summary            — 1,637 order-level rows    │  │
│   │    fact_monthly_product_perf     — Product × Month aggs      │  │
│   └─────────────────────────────┬────────────────────────────────┘  │
│                                 │ SQL Views                          │
│   ┌─────────────────────────────▼────────────────────────────────┐  │
│   │  LAYER 4: ANALYTICS  (schema: analytics)                     │  │
│   │  • Pre-aggregated views for Power BI                         │  │
│   │  • vw_monthly_revenue, vw_product_performance               │  │
│   │  • vw_city_performance, vw_customer_360                      │  │
│   └─────────────────────────────┬────────────────────────────────┘  │
│                                 │                                    │
└─────────────────────────────────┼────────────────────────────────────┘
                                  │
            ┌─────────────────────▼─────────────────────┐
            │  CONSUMPTION LAYER                        │
            │  Power BI Desktop → Power BI Service      │
            │  5 dashboards: Executive | Products |     │
            │  Customers | Geography | Time Intelligence │
            └───────────────────────────────────────────┘
```

---

## STAR SCHEMA DIAGRAM

```
                          dim_date
                         ┌─────────────────┐
                         │ date_key (PK)    │
                         │ full_date        │
                         │ year_number      │
                         │ month_name       │
                         │ quarter_name     │
                         │ is_weekend       │
                         └────────┬────────┘
                                  │
dim_customer                      │                    dim_product
┌──────────────────┐   ┌──────────▼──────────────┐   ┌──────────────────┐
│ customer_sk (PK) │   │   fact_order_items       │   │ product_sk (PK)  │
│ customer_id (NK) ├───┤ ─────────────────────── ├───┤ product_id (NK)  │
│ customer_name    │   │ order_item_sk  (PK)      │   │ product_name     │
│ email            │   │ order_date_key (FK→date) │   │ category         │
│ city             │   │ customer_sk    (FK)      │   │ unit_price       │
│ signup_date      │   │ product_sk     (FK)      │   │ price_band       │
│ customer_segment │   │ geography_sk   (FK)      │   └──────────────────┘
│ total_orders     │   │ channel_sk     (FK)      │
│ lifetime_value   │   │ order_id       (DD)      │   dim_geography
└──────────────────┘   │ quantity                 │   ┌──────────────────┐
                        │ unit_price               ├───┤ geography_sk(PK) │
dim_channel             │ gross_revenue            │   │ city_name (NK)   │
┌──────────────────┐   │ net_revenue              │   │ country          │
│ channel_sk (PK)  ├───┤ discount_amount          │   │ region           │
│ channel_name     │   │ discount_pct             │   │ latitude         │
│ channel_type     │   │ customer_tenure_days     │   │ longitude        │
└──────────────────┘   └─────────────────────────┘   └──────────────────┘

PK = Primary Key  |  NK = Natural Key  |  FK = Foreign Key  |  DD = Degenerate Dimension
```

---

## PROJECT STRUCTURE

```
project/
├── data/
│   ├── raw/                          ← Source CSV files (input)
│   │   └── ITC_ecommerce_2000_rows.csv
│   └── processed/                    ← Cleaned Parquet files (ETL output)
│
├── sql/
│   ├── 01_setup/
│   │   ├── 01_database_and_schemas.sql  ← Schemas: raw|staging|dw|analytics
│   │   ├── 02_raw_layer.sql             ← raw.ecommerce_orders
│   │   └── 03_staging_layer.sql         ← staging.order_items
│   ├── 02_dimensions/
│   │   ├── 04_dimension_tables.sql      ← All 5 dim tables + geography seed data
│   │   └── 05_populate_dim_date.sql     ← Date dimension stored procedure
│   ├── 03_facts/
│   │   └── 06_fact_tables.sql           ← 3 fact tables + FK constraints
│   ├── 04_indexes/
│   │   └── 07_indexes_and_constraints.sql ← Composite indexes + partitioning
│   └── 05_analytics/
│       └── 08_analytics_queries.sql     ← 20+ analytical queries + 4 views
│
├── etl/
│   ├── config.py          ← Connection strings + business rules (no secrets)
│   ├── logger.py          ← Rotating file logger
│   ├── extract_clean.py   ← Step 1: CSV extract + 10-step cleaning pipeline
│   ├── transform.py       ← Step 2: Build dimension + fact DataFrames
│   ├── load.py            ← Step 3: Upsert dims + reload facts to Azure SQL
│   ├── main_etl.py        ← Orchestrator — run this script
│   └── requirements.txt   ← Python dependencies
│
├── docs/
│   ├── azure_deployment_guide.md  ← Step-by-step Azure setup
│   ├── powerbi_guide.md           ← Dashboard specs + DAX measures
│   └── architecture.md            ← (this file's architecture section)
│
└── README.md              ← This file
```

---

## QUICK START

### 1. Set up Azure (first time only)
```bash
# See docs/azure_deployment_guide.md for full details
az group create --name rg-itc-datawarehouse --location westeurope
az sql server create --resource-group rg-itc-datawarehouse \
  --name sql-itc-dw-server --admin-user itc_admin \
  --admin-password "YourPassword!"
az sql db create --resource-group rg-itc-datawarehouse \
  --server sql-itc-dw-server --name ITC_DataWarehouse \
  --service-objective S2
```

### 2. Run SQL scripts (in order)
Open Azure Data Studio, connect to `ITC_DataWarehouse`, and run:
```
sql/01_setup/01_database_and_schemas.sql
sql/01_setup/02_raw_layer.sql
sql/01_setup/03_staging_layer.sql
sql/02_dimensions/04_dimension_tables.sql
sql/02_dimensions/05_populate_dim_date.sql
sql/03_facts/06_fact_tables.sql
sql/04_indexes/07_indexes_and_constraints.sql
sql/05_analytics/08_analytics_queries.sql
```

### 3. Run ETL pipeline
```bash
cd etl
pip install -r requirements.txt

# Set credentials
export AZURE_SQL_SERVER="sql-itc-dw-server.database.windows.net"
export AZURE_SQL_DATABASE="ITC_DataWarehouse"
export AZURE_SQL_USERNAME="itc_admin"
export AZURE_SQL_PASSWORD="YourPassword!"

# Dry run first
python main_etl.py --dry-run

# Full load
python main_etl.py
```

### 4. Connect Power BI
See `docs/powerbi_guide.md` for full dashboard specifications.

---

## DATA QUALITY RULES

| Rule | Implementation | Action on Failure |
|------|---------------|-------------------|
| No null primary keys | `dropna(subset=[...])` | Row dropped + logged |
| Valid email format | Regex pattern check | Flag `dq_email_valid=0` |
| Valid dates | `pd.to_datetime(errors='coerce')` | Sentinel date + flag |
| Quantity > 0 | Range check | Replace with 1 + warn |
| Price > 0 | Range check | Replace with median + warn |
| No duplicate rows | `drop_duplicates()` | First occurrence kept |
| Order date ≥ signup date | Business rule check | Flag + warn |

---

## NAMING CONVENTIONS

| Object Type | Convention | Example |
|-------------|------------|---------|
| Schema | `lowercase` | `dw`, `staging`, `raw`, `analytics` |
| Table | `prefix_noun` | `dim_customer`, `fact_order_items` |
| Column | `snake_case` | `customer_sk`, `net_revenue` |
| Primary Key | `table_sk` | `customer_sk` |
| Natural Key | `source_field_id` | `customer_id` |
| Index | `ix_table_col` | `ix_fact_orders_date_key` |
| Unique Index | `uix_table_col` | `uix_dim_customer_natural_key` |
| View | `vw_noun` | `vw_monthly_revenue` |
| Stored Proc | `usp_verb_noun` | `usp_populate_dim_date` |
| Python files | `verb_noun.py` | `extract_clean.py` |

---

## SECURITY BEST PRACTICES

1. **Never hardcode credentials** — use environment variables or Azure Key Vault
2. **Least privilege access** — create a dedicated ETL user with INSERT/UPDATE only:
   ```sql
   CREATE USER itc_etl_user WITH PASSWORD = 'EtlP@ssw0rd!';
   GRANT INSERT, UPDATE, SELECT ON SCHEMA::raw      TO itc_etl_user;
   GRANT INSERT, UPDATE, SELECT ON SCHEMA::staging  TO itc_etl_user;
   GRANT INSERT, UPDATE, SELECT ON SCHEMA::dw       TO itc_etl_user;
   GRANT SELECT                  ON SCHEMA::analytics TO itc_etl_user;
   ```
3. **Read-only user for Power BI**:
   ```sql
   CREATE USER powerbi_reader WITH PASSWORD = 'PbiR3ad@Only!';
   GRANT SELECT ON SCHEMA::analytics TO powerbi_reader;
   GRANT SELECT ON SCHEMA::dw        TO powerbi_reader;
   ```
4. **Encrypt connection** — always use `Encrypt=yes` in connection strings
5. **Rotate passwords** every 90 days via Azure AD
6. **Enable Azure Defender for SQL** — detects SQL injection attempts

---

## PERFORMANCE OPTIMISATION CHECKLIST

- [x] Surrogate integer PKs on all dimension tables (faster than natural keys)
- [x] Composite indexes on fact table filtered by most common query patterns
- [x] Included columns in indexes to avoid key lookups
- [x] Computed columns PERSISTED for frequently filtered derived fields
- [x] Analytics views pre-aggregate common GROUP BY patterns
- [x] `fast_executemany=True` in SQLAlchemy for bulk inserts
- [x] Partition function by year for range-scan optimisation
- [x] Filtered index on `fact_order_items WHERE net_revenue > 0`
- [ ] (Future) Columnstore index when row count exceeds 1M
- [ ] (Future) Partition switching for large monthly loads
- [ ] (Future) Query Store enabled for workload monitoring

---

## SCALABILITY ROADMAP

| Scale | Recommended Azure Service | Migration Path |
|-------|--------------------------|----------------|
| 0–1M rows | Azure SQL Basic/Standard | Current architecture |
| 1–100M rows | Azure SQL Premium / Hyperscale | Add columnstore index, partition switching |
| 100M+ rows | Azure Synapse Analytics | Migrate DDL with DISTRIBUTION=HASH, add ADF |
| Real-time | Event Hubs + Synapse Streaming | Add streaming pipeline alongside batch |

---

## CONTRIBUTING

1. Create a feature branch: `git checkout -b feature/new-dimension`
2. Follow naming conventions (see above)
3. Add SQL scripts in the correct numbered folder
4. Update `README.md` if architecture changes
5. Test with `python main_etl.py --dry-run` before merging

---

## SUPPORT

For issues:
1. Check `logs/etl_YYYYMMDD.log` for detailed error messages
2. Run `python main_etl.py --dry-run` to isolate data issues from connectivity issues
3. Refer to `docs/azure_deployment_guide.md` → "Common Errors and Fixes"
