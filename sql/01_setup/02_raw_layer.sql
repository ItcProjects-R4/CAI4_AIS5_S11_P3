-- =============================================================================
-- FILE: 02_raw_layer.sql
-- PURPOSE: Raw landing zone — one table mirroring the source CSV exactly.
--          All columns are VARCHAR to guarantee zero-rejection loads.
--          Adds metadata columns for audit/lineage tracking.
-- LAYER: Raw
-- =============================================================================

USE ITC_DataWarehouse;
GO

-- Drop and recreate for idempotent deployments
IF OBJECT_ID('raw.ecommerce_orders', 'U') IS NOT NULL
    DROP TABLE raw.ecommerce_orders;
GO

-- =============================================================================
-- raw.ecommerce_orders
-- Direct mirror of ITC_ecommerce_2000_rows.csv
-- Every source column is VARCHAR(500) — no casting at this layer.
-- Three audit columns are appended by the ETL loader.
-- =============================================================================
CREATE TABLE raw.ecommerce_orders (
    -- ── Source Columns (VARCHAR to ensure no load failures) ──────────────────
    order_item_id   VARCHAR(50)     NOT NULL,   -- Unique row identifier in source
    order_id        VARCHAR(50)     NOT NULL,   -- Parent order grouping
    product_id      VARCHAR(50)     NOT NULL,   -- Product reference
    quantity        VARCHAR(50)     NULL,       -- Units purchased
    customer_id     VARCHAR(50)     NOT NULL,   -- Customer reference
    order_date      VARCHAR(50)     NULL,       -- Raw date string (YYYY-MM-DD)
    total_amount    VARCHAR(50)     NULL,       -- Order line monetary value
    name            VARCHAR(500)    NULL,       -- Customer display name
    city            VARCHAR(200)    NULL,       -- Customer city
    email           VARCHAR(500)    NULL,       -- Customer email
    signup_date     VARCHAR(50)     NULL,       -- Customer account creation date
    product_name    VARCHAR(500)    NULL,       -- Product display name
    category        VARCHAR(200)    NULL,       -- Product category
    price           VARCHAR(50)     NULL,       -- Unit product price

    -- ── ETL Audit Columns ────────────────────────────────────────────────────
    etl_load_id     VARCHAR(100)    NOT NULL,   -- Batch identifier (GUID or timestamp)
    etl_load_date   DATETIME2(3)    NOT NULL    -- Exact UTC timestamp of this load
                        DEFAULT SYSUTCDATETIME(),
    etl_source_file VARCHAR(500)    NULL        -- Source filename for full lineage
);
GO

-- Index on load date for fast audit queries and incremental reload detection
CREATE INDEX ix_raw_ecommerce_load_date
    ON raw.ecommerce_orders (etl_load_date);
GO

-- Index to quickly find rows by order_id in the raw layer
CREATE INDEX ix_raw_ecommerce_order_id
    ON raw.ecommerce_orders (order_id);
GO

PRINT 'raw.ecommerce_orders created successfully.';
GO
