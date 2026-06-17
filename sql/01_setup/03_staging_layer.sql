-- =============================================================================
-- FILE: 03_staging_layer.sql
-- PURPOSE: Cleaned, typed, deduplicated working tables.
--          Populated by the ETL from raw.ecommerce_orders on every run.
--          Acts as the transformation workspace before loading the star schema.
-- LAYER: Staging
-- =============================================================================

USE ITC_DataWarehouse;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- staging.order_items
-- Cleaned version of raw.ecommerce_orders with proper data types.
-- The ETL truncates and fully reloads this table each run.
-- ─────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('staging.order_items', 'U') IS NOT NULL
    DROP TABLE staging.order_items;
GO

CREATE TABLE staging.order_items (
    -- ── Keys ─────────────────────────────────────────────────────────────────
    order_item_id       INT             NOT NULL,
    order_id            INT             NOT NULL,
    product_id          INT             NOT NULL,
    customer_id         INT             NOT NULL,

    -- ── Order Metrics ────────────────────────────────────────────────────────
    quantity            SMALLINT        NOT NULL    CHECK (quantity > 0),
    total_amount        DECIMAL(18, 2)  NOT NULL    CHECK (total_amount >= 0),
    order_date          DATE            NOT NULL,

    -- ── Customer Attributes ──────────────────────────────────────────────────
    customer_name       NVARCHAR(300)   NOT NULL,
    city                NVARCHAR(100)   NOT NULL,
    email               NVARCHAR(300)   NOT NULL,
    signup_date         DATE            NOT NULL,

    -- ── Product Attributes ───────────────────────────────────────────────────
    product_name        NVARCHAR(300)   NOT NULL,
    category            NVARCHAR(100)   NOT NULL,
    unit_price          DECIMAL(18, 2)  NOT NULL    CHECK (unit_price >= 0),

    -- ── Derived / Enriched Columns ───────────────────────────────────────────
    -- Revenue = quantity × unit_price (useful sanity-check vs total_amount)
    calculated_revenue  AS (CAST(quantity AS DECIMAL(18,2)) * unit_price),

    -- Discount inferred when total_amount < quantity * price
    discount_amount     AS (
        CASE
            WHEN (CAST(quantity AS DECIMAL(18,2)) * unit_price) > total_amount
            THEN (CAST(quantity AS DECIMAL(18,2)) * unit_price) - total_amount
            ELSE 0
        END
    ),

    -- Order year / month for fast time filtering without joins
    order_year          AS (YEAR(order_date))  PERSISTED,
    order_month         AS (MONTH(order_date)) PERSISTED,

    -- Customer tenure in days at the time of the order
    customer_tenure_days AS (
        DATEDIFF(DAY, signup_date, order_date)
    ) PERSISTED,

    -- ── Data Quality Flags ───────────────────────────────────────────────────
    -- Set by ETL; allows downstream filtering without re-running checks
    dq_email_valid      BIT             NOT NULL DEFAULT 1,
    dq_date_valid       BIT             NOT NULL DEFAULT 1,

    -- ── Audit ────────────────────────────────────────────────────────────────
    etl_load_date       DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Clustered index: most queries filter/join on customer and order date
CREATE CLUSTERED INDEX cix_staging_order_items_customer_date
    ON staging.order_items (customer_id, order_date);
GO

CREATE INDEX ix_staging_order_items_order_id
    ON staging.order_items (order_id);
GO

CREATE INDEX ix_staging_order_items_product_id
    ON staging.order_items (product_id);
GO

CREATE INDEX ix_staging_order_items_category
    ON staging.order_items (category);
GO

PRINT 'staging.order_items created successfully.';
GO
