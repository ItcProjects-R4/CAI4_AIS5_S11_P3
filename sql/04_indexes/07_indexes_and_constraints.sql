-- =============================================================================
-- FILE: 07_indexes_and_constraints.sql (Idempotent Version)
-- =============================================================================

-- ── 1. ADDITIONAL ANALYTICS INDEXES ──────────────────────────────────────────
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'ix_fact_orders_product_date_revenue' AND object_id = OBJECT_ID('dw.fact_order_items'))
BEGIN
    CREATE INDEX ix_fact_orders_product_date_revenue
        ON dw.fact_order_items (order_date_key, product_sk)
        INCLUDE (net_revenue, quantity, gross_revenue, discount_amount)
        WHERE net_revenue > 0;
END
GO

IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'ix_fact_orders_geo_month' AND object_id = OBJECT_ID('dw.fact_order_items'))
BEGIN
    CREATE INDEX ix_fact_orders_geo_month
        ON dw.fact_order_items (geography_sk, order_date_key)
        INCLUDE (net_revenue, quantity, customer_sk);
END
GO

IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'ix_dim_customer_ltv' AND object_id = OBJECT_ID('dw.dim_customer'))
BEGIN
    CREATE INDEX ix_dim_customer_ltv
        ON dw.dim_customer (total_lifetime_value DESC)
        INCLUDE (customer_id, customer_name, city, customer_segment);
END
GO

-- ── 2. COLUMN-LEVEL CHECK CONSTRAINTS ────────────────────────────────────────
IF NOT EXISTS (SELECT * FROM sys.check_constraints WHERE name = 'chk_fact_order_items_date')
BEGIN
    ALTER TABLE dw.fact_order_items ADD CONSTRAINT chk_fact_order_items_date CHECK (order_date_key BETWEEN 20190101 AND 20311231);
END
GO

IF NOT EXISTS (SELECT * FROM sys.check_constraints WHERE name = 'chk_fact_net_revenue_nonneg')
BEGIN
    ALTER TABLE dw.fact_order_items ADD CONSTRAINT chk_fact_net_revenue_nonneg CHECK (net_revenue >= 0);
END
GO

IF NOT EXISTS (SELECT * FROM sys.check_constraints WHERE name = 'chk_fact_quantity_positive')
BEGIN
    ALTER TABLE dw.fact_order_items ADD CONSTRAINT chk_fact_quantity_positive CHECK (quantity > 0);
END
GO

-- ── 3. PARTITIONING NOTE ─────────────────────────────────────────────────────
IF NOT EXISTS (SELECT * FROM sys.partition_functions WHERE name = 'pf_order_year')
BEGIN
    CREATE PARTITION FUNCTION pf_order_year (INT) AS RANGE RIGHT FOR VALUES (20210101, 20220101, 20230101, 20240101, 20250101, 20260101);
END
GO

IF NOT EXISTS (SELECT * FROM sys.partition_schemes WHERE name = 'ps_order_year')
BEGIN
    CREATE PARTITION SCHEME ps_order_year AS PARTITION pf_order_year ALL TO ([PRIMARY]);
END
GO

PRINT 'Indexes, constraints, and partition objects checked and verified successfully.';
GO