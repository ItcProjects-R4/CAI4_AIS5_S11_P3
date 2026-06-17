# Architecture Reference
## ITC E-Commerce Data Warehouse

---

## 1. LAYERED ARCHITECTURE — WHY EACH LAYER EXISTS

```
SOURCE ──► RAW ──► STAGING ──► DATA WAREHOUSE ──► ANALYTICS ──► BI / CONSUMERS
```

### Layer 1: Raw (`raw` schema)

**Why it exists**: Immutability and disaster recovery.

Every row from the source CSV lands here exactly as it arrived — all columns stored
as `VARCHAR` to guarantee zero-rejection loads regardless of data quality issues in
the source. This layer is append-only; rows are never deleted or modified.

If a transformation bug corrupts the staging or DW layers, the raw layer is the
single source of truth from which the entire warehouse can be replayed.

**Tables**: `raw.ecommerce_orders`
**Access**: ETL write-only; no BI tools or analysts should query this layer.

---

### Layer 2: Staging (`staging` schema)

**Why it exists**: Transformation workspace and data quality enforcement.

The raw VARCHAR data is cast to proper data types (`INT`, `DATE`, `DECIMAL`),
deduplicated, and enriched with DQ flags. Business rules are applied here
(e.g., city name standardisation, price band assignment). This layer is
truncated and fully reloaded on every ETL run.

Analysts must never build reports on this layer — it's transient and incomplete.

**Tables**: `staging.order_items`
**Access**: ETL read/write; DBAs for debugging.

---

### Layer 3: Data Warehouse (`dw` schema)

**Why it exists**: The single source of analytical truth.

This is the **Star Schema** — conformed, history-complete, surrogate-keyed,
and index-optimised. All BI tools and analyst queries target this layer.
Data here is never deleted; ETL uses MERGE (upsert) for dimensions and
truncate-reload for facts on this dataset size.

**Star Schema objects**:

| Object | Type | Grain | Row Count |
|--------|------|-------|-----------|
| `dw.dim_date` | Dimension | 1 row per calendar day | 4,018 |
| `dw.dim_customer` | Dimension | 1 row per customer | 1,283 |
| `dw.dim_product` | Dimension | 1 row per product | 100 |
| `dw.dim_geography` | Dimension | 1 row per city | 5 |
| `dw.dim_channel` | Dimension | 1 row per channel | 6 |
| `dw.fact_order_items` | Fact | 1 row per order line item | 2,000 |
| `dw.fact_order_summary` | Fact | 1 row per order | 1,637 |
| `dw.fact_monthly_product_performance` | Fact | 1 row per product per month | 1,628 |

**Access**: BI readers (SELECT only), ETL (INSERT/UPDATE), analysts (SELECT).

---

### Layer 4: Analytics (`analytics` schema)

**Why it exists**: Performance isolation and stable BI interfaces.

Pre-aggregated views sit between the DW and BI tools. Power BI connects to
`analytics.vw_*` views, not directly to fact tables. This means:

1. **Stability**: Renaming or restructuring DW tables only requires updating
   the view — Power BI reports don't break.
2. **Performance**: Common GROUP BY operations are pre-computed, reducing
   query load on the fact tables.
3. **Security**: Fine-grained column masking and row filtering can be applied
   in views without modifying the underlying tables.

**Views**:
- `analytics.vw_monthly_revenue` — Monthly revenue trend data
- `analytics.vw_product_performance` — Product-level aggregates
- `analytics.vw_city_performance` — Geographic sales summary with coordinates
- `analytics.vw_customer_360` — Customer-level summary with RFM inputs

---

## 2. ETL PIPELINE DESIGN

```
CSV File
  │
  ▼  extract_clean.py
  ├─ extract_csv()         → reads raw CSV, all cols as str
  └─ clean_data()          → 10-step cleaning pipeline
       ├─ 1. Column name standardisation
       ├─ 2. Duplicate removal
       ├─ 3. Null handling (drop critical | fill non-critical)
       ├─ 4. Numeric type casting
       ├─ 5. String normalisation (title-case, aliases)
       ├─ 6. Date parsing + flagging
       ├─ 7. Range validation (qty > 0, price > 0)
       ├─ 8. Email validation flag
       ├─ 9. Derived columns (gross/net/discount/tenure/year/month)
       └─ 10. Price band classification
  │
  ▼  load.py (raw + staging)
  ├─ load_raw()             → appends to raw.ecommerce_orders
  └─ load_staging()         → truncates + reloads staging.order_items
  │
  ▼  transform.py
  ├─ build_dim_customer()   → 1 row/customer, LTV, segments
  ├─ build_dim_product()    → 1 row/product, latest price
  └─ build_fact_order_items()  → SK lookups, date keys, measures
  │
  ▼  load.py (dimensions)
  ├─ load_dim_customer()    → MERGE upsert → returns {id: sk} map
  └─ load_dim_product()     → MERGE upsert → returns {id: sk} map
  │
  ▼  transform.py → load.py (facts)
  ├─ build_fact_order_items()            → line-item grain
  ├─ load_fact_order_items()             → truncate + reload
  ├─ build_fact_order_summary()          → order-level agg
  ├─ load_fact_order_summary()           → truncate + reload
  ├─ build_fact_monthly_product_performance()  → product × month
  └─ load_fact_monthly_performance()     → truncate + reload
```

**ETL Modes**:
- `main_etl.py` — Full historical reload (current data size: fast enough daily)
- `incremental_load.py` — Delta load using high-water mark from `dw.etl_control_table`

---

## 3. DATA MODEL DECISIONS

### Why Star Schema (not Snowflake)?

Snowflake normalises dimensions further (e.g. `dim_city` referencing `dim_country`).
Star schema denormalises these into one dimension table, which:
- Reduces JOIN depth in queries (faster for BI tools)
- Simplifies Power BI relationship diagrams
- Is the industry standard for analytical workloads

The slight storage overhead from denormalisation is negligible at this scale.

### Why Surrogate Integer Keys?

Natural keys (`customer_id = 300`) have business meaning and can change if the
source system is updated. Surrogate keys (`customer_sk = 12`) are:
- Stable — never changed, even if source data changes
- Small integer type — faster JOIN performance than VARCHAR natural keys
- Enable SCD Type 2 (multiple versions of a customer over time)

### Why Three Fact Tables?

| Fact Table | Purpose | When to query |
|------------|---------|---------------|
| `fact_order_items` | Line-item detail; finest grain | Revenue analysis, product mix, discount analysis |
| `fact_order_summary` | Order-level totals | Basket analysis, funnel metrics, AOV |
| `fact_monthly_product_performance` | Pre-aggregated | Dashboard KPI cards, trend charts (fastest) |

Separate fact tables at different grains avoid the "fan-out" problem where
joining a line-item fact to an order-level fact inflates counts.

### SCD Strategy

| Dimension | SCD Type | Reasoning |
|-----------|----------|-----------|
| `dim_customer` | Type 1 (overwrite) | Name/city changes are corrections, not history |
| `dim_product` | Type 1 (overwrite) | Price is current price; use fact table for price-at-sale |
| `dim_geography` | Type 0 (static) | Cities don't change |
| `dim_date` | Type 0 (static) | Pre-populated, immutable |
| `dim_channel` | Type 0 (static) | Small reference table |

**To upgrade `dim_customer` to SCD Type 2** (track name/city changes over time),
add `effective_from DATE`, `effective_to DATE`, `is_current BIT` columns and
update the MERGE procedure to INSERT new versions instead of updating in place.

---

## 4. KEY DESIGN PATTERNS

### Pattern 1: Date Key as Integer (YYYYMMDD)

Using `INT` instead of a `DATE` foreign key:
- Avoids NULL FK violations (every `INT` key can be checked immediately)
- Allows date arithmetic without JOIN (`WHERE order_date_key BETWEEN 20230101 AND 20231231`)
- Human-readable in query results without formatting

### Pattern 2: Computed Columns PERSISTED

Columns like `order_year`, `order_month`, `customer_tenure_days` are computed
and PERSISTED in the staging table. This means:
- Computed once at INSERT time, not recalculated on every query
- Can be indexed (non-persisted computed columns cannot)
- Zero cost in SELECT queries

### Pattern 3: Included Columns on Indexes

```sql
CREATE INDEX ix_fact_orders_date_key
    ON dw.fact_order_items (order_date_key)
    INCLUDE (net_revenue, quantity, customer_sk, product_sk);
```

The `INCLUDE` columns are stored at the leaf level of the index — queries
that need these columns don't need to touch the main table (covering index),
eliminating expensive key lookups.

### Pattern 4: Filtered Indexes

```sql
CREATE INDEX ix_fact_orders_product_date_revenue
    ON dw.fact_order_items (order_date_key, product_sk)
    WHERE net_revenue > 0;
```

Only indexes non-zero revenue rows. Smaller index → faster scans → less
storage. Especially useful when 0-revenue rows are common (e.g. cancelled orders).

---

## 5. SCALABILITY PATH

| Dataset Size | Current Approach | When to Upgrade |
|-------------|-----------------|-----------------|
| < 5M rows | Azure SQL Standard S2/S3 + rowstore indexes | N/A — current state |
| 5–50M rows | Azure SQL Premium P1 + columnstore indexes on facts | When daily load > 15 min |
| 50–500M rows | Azure Synapse Dedicated Pool (DW100c) + HASH distribution | When queries > 30 sec |
| 500M+ rows | Synapse + Spark pools + Delta Lake on ADLS Gen2 | Enterprise scale |

**Columnstore index upgrade path** (when row count exceeds 5M):
```sql
-- Replace clustered rowstore with clustered columnstore
-- (10–100× compression; up to 10× query speedup for analytics)
CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_order_items
    ON dw.fact_order_items;
```

**Synapse HASH distribution** (prevents data skew on large joins):
```sql
CREATE TABLE dw.fact_order_items
WITH (
    DISTRIBUTION = HASH(customer_sk),
    CLUSTERED COLUMNSTORE INDEX
) AS SELECT ...
```
