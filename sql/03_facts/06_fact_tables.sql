-- =============================================================================
-- FILE: 06_fact_tables.sql
-- PURPOSE: Create Fact tables in the Star Schema (dw schema).
--          Facts store measurable events (orders, campaigns, performance).
--          All facts reference dimension surrogate keys (not natural keys).
-- LAYER: Data Warehouse (dw)
-- =============================================================================

USE ITC_DataWarehouse;
GO

-- =============================================================================
-- FACT TABLE 1: dw.fact_order_items
-- Grain      : One row per ORDER LINE ITEM (finest possible grain from source)
-- Purpose    : Core transactional fact. Captures every product sold, to whom,
--              when, where, and for how much. All monetary amounts in EGP.
--              Enables: revenue analysis, product performance, customer value,
--              geographic sales, time-series analysis.
-- PK         : order_item_sk  (surrogate)
-- FK Keys    : Joins to all 5 dimensions
-- Source     : staging.order_items → fact_order_items
-- =============================================================================
IF OBJECT_ID('dw.fact_order_items', 'U') IS NOT NULL DROP TABLE dw.fact_order_items;
GO

CREATE TABLE dw.fact_order_items (
    -- ── Surrogate Key ─────────────────────────────────────────────────────────
    order_item_sk           BIGINT          NOT NULL IDENTITY(1,1),

    -- ── Dimension Foreign Keys (all surrogate) ────────────────────────────────
    order_date_key          INT             NOT NULL,   -- → dw.dim_date.date_key
    customer_sk             INT             NOT NULL,   -- → dw.dim_customer.customer_sk
    product_sk              INT             NOT NULL,   -- → dw.dim_product.product_sk
    geography_sk            INT             NOT NULL,   -- → dw.dim_geography.geography_sk
    channel_sk              INT             NOT NULL    -- → dw.dim_channel.channel_sk
                                                        --   (defaulted to 1='Online Store')
                                            DEFAULT 1,

    -- ── Degenerate Dimensions (no separate dimension table needed) ────────────
    -- "Degenerate" = structured identifiers from source; stored in fact directly
    order_id                INT             NOT NULL,   -- Order grouping key
    order_item_id           INT             NOT NULL,   -- Source row identifier

    -- ── Facts / Measures ──────────────────────────────────────────────────────
    quantity                SMALLINT        NOT NULL,   -- Units ordered
    unit_price              DECIMAL(18, 2)  NOT NULL,   -- Price at time of sale
    gross_revenue           DECIMAL(18, 2)  NOT NULL,   -- quantity × unit_price
    net_revenue             DECIMAL(18, 2)  NOT NULL,   -- total_amount (after discount)
    discount_amount         DECIMAL(18, 2)  NOT NULL,   -- gross_revenue - net_revenue
    discount_pct            DECIMAL(7, 4)   NOT NULL,   -- discount / gross_revenue

    -- ── Semi-Additive Facts ───────────────────────────────────────────────────
    -- (cannot be summed across all dimensions — use AVG or snapshot logic)
    customer_tenure_days    INT             NULL,       -- Days since signup at order time

    -- ── Audit ─────────────────────────────────────────────────────────────────
    etl_load_date           DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),
    etl_load_id             VARCHAR(100)    NULL,

    CONSTRAINT pk_fact_order_items PRIMARY KEY CLUSTERED (order_item_sk)
);
GO

-- ── Foreign Key Constraints ───────────────────────────────────────────────────
ALTER TABLE dw.fact_order_items
    ADD CONSTRAINT fk_fact_orders_date
        FOREIGN KEY (order_date_key) REFERENCES dw.dim_date (date_key);

ALTER TABLE dw.fact_order_items
    ADD CONSTRAINT fk_fact_orders_customer
        FOREIGN KEY (customer_sk) REFERENCES dw.dim_customer (customer_sk);

ALTER TABLE dw.fact_order_items
    ADD CONSTRAINT fk_fact_orders_product
        FOREIGN KEY (product_sk) REFERENCES dw.dim_product (product_sk);

ALTER TABLE dw.fact_order_items
    ADD CONSTRAINT fk_fact_orders_geography
        FOREIGN KEY (geography_sk) REFERENCES dw.dim_geography (geography_sk);

ALTER TABLE dw.fact_order_items
    ADD CONSTRAINT fk_fact_orders_channel
        FOREIGN KEY (channel_sk) REFERENCES dw.dim_channel (channel_sk);
GO

-- ── Performance Indexes ───────────────────────────────────────────────────────
-- Date-range queries are the most common analytical pattern
CREATE INDEX ix_fact_orders_date_key
    ON dw.fact_order_items (order_date_key)
    INCLUDE (net_revenue, quantity, customer_sk, product_sk);

-- Customer-centric analysis (CLV, retention)
CREATE INDEX ix_fact_orders_customer
    ON dw.fact_order_items (customer_sk, order_date_key)
    INCLUDE (net_revenue, quantity, product_sk);

-- Product performance queries
CREATE INDEX ix_fact_orders_product
    ON dw.fact_order_items (product_sk, order_date_key)
    INCLUDE (net_revenue, quantity, gross_revenue);

-- Geographic sales analysis
CREATE INDEX ix_fact_orders_geography
    ON dw.fact_order_items (geography_sk, order_date_key)
    INCLUDE (net_revenue, quantity);

-- Order-level lookups (for order history pages)
CREATE INDEX ix_fact_orders_order_id
    ON dw.fact_order_items (order_id);
GO

-- =============================================================================
-- FACT TABLE 2: dw.fact_order_summary
-- Grain      : One row per ORDER (aggregated from order items)
-- Purpose    : Order-level view of sales. Useful for funnel analysis,
--              average order value, orders per customer reporting.
--              Derived from fact_order_items by ETL, not loaded from raw.
-- PK         : order_summary_sk
-- =============================================================================
IF OBJECT_ID('dw.fact_order_summary', 'U') IS NOT NULL DROP TABLE dw.fact_order_summary;
GO

CREATE TABLE dw.fact_order_summary (
    order_summary_sk        INT             NOT NULL IDENTITY(1,1),

    -- ── Dimension FK ─────────────────────────────────────────────────────────
    order_date_key          INT             NOT NULL,
    customer_sk             INT             NOT NULL,
    geography_sk            INT             NOT NULL,

    -- ── Degenerate ───────────────────────────────────────────────────────────
    order_id                INT             NOT NULL,

    -- ── Measures ─────────────────────────────────────────────────────────────
    total_items             SMALLINT        NOT NULL,   -- Count of line items
    total_quantity          INT             NOT NULL,   -- Sum of quantities
    order_gross_revenue     DECIMAL(18, 2)  NOT NULL,
    order_net_revenue       DECIMAL(18, 2)  NOT NULL,
    order_discount_amount   DECIMAL(18, 2)  NOT NULL,
    distinct_products       SMALLINT        NOT NULL,   -- Unique products in order

    -- ── Audit ─────────────────────────────────────────────────────────────────
    etl_load_date           DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT pk_fact_order_summary PRIMARY KEY CLUSTERED (order_summary_sk)
);
GO

ALTER TABLE dw.fact_order_summary
    ADD CONSTRAINT fk_fact_summary_date
        FOREIGN KEY (order_date_key) REFERENCES dw.dim_date (date_key);

ALTER TABLE dw.fact_order_summary
    ADD CONSTRAINT fk_fact_summary_customer
        FOREIGN KEY (customer_sk) REFERENCES dw.dim_customer (customer_sk);

ALTER TABLE dw.fact_order_summary
    ADD CONSTRAINT fk_fact_summary_geography
        FOREIGN KEY (geography_sk) REFERENCES dw.dim_geography (geography_sk);
GO

CREATE UNIQUE INDEX uix_fact_summary_order_id
    ON dw.fact_order_summary (order_id);

CREATE INDEX ix_fact_summary_customer_date
    ON dw.fact_order_summary (customer_sk, order_date_key)
    INCLUDE (order_net_revenue, total_quantity);
GO

-- =============================================================================
-- FACT TABLE 3: dw.fact_monthly_product_performance
-- Grain      : One row per PRODUCT per MONTH
-- Purpose    : Pre-aggregated for fast dashboard rendering. Eliminates the
--              need for GROUP BY on large fact tables in real-time BI queries.
--              Refreshed monthly (or nightly with rolling window logic).
-- PK         : monthly_perf_sk
-- =============================================================================
IF OBJECT_ID('dw.fact_monthly_product_performance', 'U') IS NOT NULL
    DROP TABLE dw.fact_monthly_product_performance;
GO

CREATE TABLE dw.fact_monthly_product_performance (
    monthly_perf_sk         INT             NOT NULL IDENTITY(1,1),

    -- ── Dimension FK ─────────────────────────────────────────────────────────
    year_month_key          CHAR(7)         NOT NULL,   -- '2023-01'
    product_sk              INT             NOT NULL,

    -- ── Measures ─────────────────────────────────────────────────────────────
    total_units_sold        INT             NOT NULL,
    total_orders            INT             NOT NULL,
    total_gross_revenue     DECIMAL(18, 2)  NOT NULL,
    total_net_revenue       DECIMAL(18, 2)  NOT NULL,
    avg_unit_price          DECIMAL(18, 2)  NOT NULL,
    avg_order_value         DECIMAL(18, 2)  NOT NULL,
    total_customers         INT             NOT NULL,   -- Distinct buyers

    -- ── Month-over-Month Deltas (populated by ETL) ────────────────────────────
    revenue_mom_change_pct  DECIMAL(10, 4)  NULL,   -- (current - prior) / prior
    units_mom_change_pct    DECIMAL(10, 4)  NULL,

    -- ── Audit ─────────────────────────────────────────────────────────────────
    etl_load_date           DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT pk_fact_monthly_product PRIMARY KEY CLUSTERED (monthly_perf_sk)
);
GO

CREATE UNIQUE INDEX uix_fact_monthly_product_natural
    ON dw.fact_monthly_product_performance (year_month_key, product_sk);

CREATE INDEX ix_fact_monthly_product_sk
    ON dw.fact_monthly_product_performance (product_sk, year_month_key)
    INCLUDE (total_net_revenue, total_units_sold);
GO

PRINT 'Fact tables created: fact_order_items | fact_order_summary | fact_monthly_product_performance';
GO
