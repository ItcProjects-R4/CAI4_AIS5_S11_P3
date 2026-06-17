-- =============================================================================
-- FILE: 09_stored_procedures.sql
-- PURPOSE: Database-side stored procedures that complement the Python ETL.
--          These handle the MERGE (upsert) logic for dimension tables and
--          the aggregation logic for derived fact tables — entirely within
--          the database engine for maximum performance.
--
--          Execution order (called by Python load.py after staging is loaded):
--            1. dw.usp_load_dim_customer
--            2. dw.usp_load_dim_product
--            3. dw.usp_load_fact_order_items
--            4. dw.usp_load_fact_order_summary        (derived from fact_order_items)
--            5. dw.usp_load_fact_monthly_performance  (derived from fact_order_items)
--            6. dw.usp_refresh_analytics_cache        (optional — updates dim_customer stats)
-- =============================================================================

USE ITC_DataWarehouse;
GO

-- =============================================================================
-- PROCEDURE 1: dw.usp_load_dim_customer
-- Merges staging.order_items → dw.dim_customer
-- SCD Type 1: overwrites name, city, email if changed; preserves signup_date.
-- Also recalculates total_orders and total_lifetime_value from fact table
-- on subsequent runs (after facts are loaded).
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_load_dim_customer
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inserted INT = 0, @updated INT = 0;

    -- ── Step 1: MERGE staging data into dim_customer ──────────────────────────
    MERGE dw.dim_customer AS tgt
    USING (
        -- Deduplicate staging: one row per customer_id (latest attributes win)
        SELECT
            customer_id,
            customer_name,
            email,
            city,
            signup_date,
            signup_year,
            signup_month,
            'Egypt'  AS country,
            'MENA'   AS region
        FROM (
            SELECT
                CAST(customer_id   AS INT)          AS customer_id,
                customer_name,
                email,
                city,
                CAST(signup_date   AS DATE)         AS signup_date,
                YEAR(CAST(signup_date AS DATE))     AS signup_year,
                MONTH(CAST(signup_date AS DATE))    AS signup_month,
                ROW_NUMBER() OVER (
                    PARTITION BY customer_id
                    ORDER BY order_date DESC          -- Latest record wins
                )                                   AS rn
            FROM staging.order_items
        ) ranked
        WHERE rn = 1
    ) AS src
    ON tgt.customer_id = src.customer_id

    -- Update existing customers (SCD Type 1 — latest value wins)
    WHEN MATCHED AND (
        tgt.customer_name <> src.customer_name OR
        tgt.email         <> src.email         OR
        tgt.city          <> src.city
    ) THEN UPDATE SET
        tgt.customer_name     = src.customer_name,
        tgt.email             = src.email,
        tgt.city              = src.city,
        tgt.signup_date       = src.signup_date,
        tgt.signup_year       = src.signup_year,
        tgt.signup_month      = src.signup_month,
        tgt.last_updated_date = SYSUTCDATETIME()

    -- Insert new customers
    WHEN NOT MATCHED BY TARGET THEN INSERT (
        customer_id, customer_name, email, city, country, region,
        signup_date, signup_year, signup_month,
        customer_segment, total_orders, total_lifetime_value,
        is_active, created_date, last_updated_date
    ) VALUES (
        src.customer_id, src.customer_name, src.email, src.city,
        src.country, src.region,
        src.signup_date, src.signup_year, src.signup_month,
        'New', 0, 0.00,           -- Segment + stats updated in Step 2
        1, SYSUTCDATETIME(), SYSUTCDATETIME()
    );

    -- ── Step 2: Refresh aggregate stats and segment classification ────────────
    -- Runs AFTER fact_order_items is loaded. Called separately if needed.
    UPDATE c
    SET
        c.total_orders         = agg.total_orders,
        c.total_lifetime_value = agg.total_lifetime_value,
        c.customer_segment     = CASE
            WHEN agg.total_lifetime_value >= 20000 OR agg.total_orders >= 5 THEN 'High Value'
            WHEN agg.total_lifetime_value >= 8000  OR agg.total_orders >= 3 THEN 'Regular'
            WHEN agg.total_orders = 1                                        THEN 'New'
            ELSE                                                                  'Developing'
        END,
        c.last_updated_date = SYSUTCDATETIME()
    FROM dw.dim_customer c
    JOIN (
        SELECT
            customer_sk,
            COUNT(DISTINCT order_id)    AS total_orders,
            SUM(net_revenue)            AS total_lifetime_value
        FROM dw.fact_order_items
        GROUP BY customer_sk
    ) agg ON agg.customer_sk = c.customer_sk;

    PRINT 'dw.usp_load_dim_customer complete.';
END;
GO

-- =============================================================================
-- PROCEDURE 2: dw.usp_load_dim_product
-- Merges staging.order_items → dw.dim_product
-- SCD Type 1: always overwrites unit_price with most recent value.
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_load_dim_product
AS
BEGIN
    SET NOCOUNT ON;

    MERGE dw.dim_product AS tgt
    USING (
        SELECT
            product_id, product_name, category, unit_price, price_band
        FROM (
            SELECT
                CAST(product_id  AS INT)          AS product_id,
                product_name,
                category,
                CAST(unit_price  AS DECIMAL(18,2)) AS unit_price,
                -- Price band classification
                CASE
                    WHEN CAST(unit_price AS DECIMAL(18,2)) < 500    THEN 'Budget'
                    WHEN CAST(unit_price AS DECIMAL(18,2)) < 2000   THEN 'Mid-Range'
                    WHEN CAST(unit_price AS DECIMAL(18,2)) < 4000   THEN 'Premium'
                    ELSE                                                  'Luxury'
                END                               AS price_band,
                ROW_NUMBER() OVER (
                    PARTITION BY product_id
                    ORDER BY order_date DESC       -- Latest price wins
                )                                 AS rn
            FROM staging.order_items
        ) ranked
        WHERE rn = 1
    ) AS src
    ON tgt.product_id = src.product_id

    WHEN MATCHED AND (
        tgt.unit_price   <> src.unit_price   OR
        tgt.product_name <> src.product_name OR
        tgt.category     <> src.category
    ) THEN UPDATE SET
        tgt.product_name      = src.product_name,
        tgt.category          = src.category,
        tgt.unit_price        = src.unit_price,
        tgt.price_band        = src.price_band,
        tgt.last_updated_date = SYSUTCDATETIME()

    WHEN NOT MATCHED BY TARGET THEN INSERT (
        product_id, product_name, category, unit_price, price_band,
        is_active, created_date, last_updated_date
    ) VALUES (
        src.product_id, src.product_name, src.category,
        src.unit_price, src.price_band,
        1, SYSUTCDATETIME(), SYSUTCDATETIME()
    );

    PRINT 'dw.usp_load_dim_product complete.';
END;
GO

-- =============================================================================
-- PROCEDURE 3: dw.usp_load_fact_order_items
-- Transforms staging.order_items → dw.fact_order_items.
-- Performs surrogate key lookups via JOIN (no Python-side SK mapping needed
-- when using this proc directly).
-- Uses TRUNCATE + INSERT for full historical reload.
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_load_fact_order_items
    @etl_load_id VARCHAR(100) = NULL   -- Optional: pass batch GUID for lineage
AS
BEGIN
    SET NOCOUNT ON;
    SET @etl_load_id = ISNULL(@etl_load_id, CAST(NEWID() AS VARCHAR(100)));

    -- Truncate and reload (idempotent)
    TRUNCATE TABLE dw.fact_order_items;

    INSERT INTO dw.fact_order_items (
        order_date_key,
        customer_sk,
        product_sk,
        geography_sk,
        channel_sk,
        order_id,
        order_item_id,
        quantity,
        unit_price,
        gross_revenue,
        net_revenue,
        discount_amount,
        discount_pct,
        customer_tenure_days,
        etl_load_id
    )
    SELECT
        -- Date key: YYYYMMDD integer from order_date
        CAST(FORMAT(CAST(s.order_date AS DATE), 'yyyyMMdd') AS INT)
                                                AS order_date_key,

        -- Dimension surrogate key lookups
        c.customer_sk,
        p.product_sk,
        ISNULL(g.geography_sk, 1)               AS geography_sk,
        1                                       AS channel_sk,  -- Default: Online

        -- Degenerate dimensions
        CAST(s.order_id      AS INT)            AS order_id,
        CAST(s.order_item_id AS INT)            AS order_item_id,

        -- Measures
        CAST(s.quantity   AS SMALLINT)          AS quantity,
        CAST(s.unit_price AS DECIMAL(18,2))     AS unit_price,

        -- Gross = qty × unit_price
        CAST(s.quantity AS DECIMAL(18,2)) * CAST(s.unit_price AS DECIMAL(18,2))
                                                AS gross_revenue,

        -- Net = total_amount as provided
        CAST(s.total_amount AS DECIMAL(18,2))   AS net_revenue,

        -- Discount = gross - net (floor at 0)
        CASE
            WHEN (CAST(s.quantity AS DECIMAL(18,2)) * CAST(s.unit_price AS DECIMAL(18,2)))
                 > CAST(s.total_amount AS DECIMAL(18,2))
            THEN (CAST(s.quantity AS DECIMAL(18,2)) * CAST(s.unit_price AS DECIMAL(18,2)))
                 - CAST(s.total_amount AS DECIMAL(18,2))
            ELSE 0
        END                                     AS discount_amount,

        -- Discount %
        CASE
            WHEN (CAST(s.quantity AS DECIMAL(18,2)) * CAST(s.unit_price AS DECIMAL(18,2))) > 0
            THEN ROUND(
                ((CAST(s.quantity AS DECIMAL(18,2)) * CAST(s.unit_price AS DECIMAL(18,2)))
                 - CAST(s.total_amount AS DECIMAL(18,2)))
                / (CAST(s.quantity AS DECIMAL(18,2)) * CAST(s.unit_price AS DECIMAL(18,2))), 4)
            ELSE 0
        END                                     AS discount_pct,

        -- Customer tenure at time of order
        DATEDIFF(DAY,
            CAST(s.signup_date AS DATE),
            CAST(s.order_date  AS DATE))        AS customer_tenure_days,

        @etl_load_id                            AS etl_load_id

    FROM staging.order_items s

    -- Surrogate key lookups — rows without a match are silently excluded
    INNER JOIN dw.dim_customer   c ON c.customer_id = CAST(s.customer_id AS INT)
    INNER JOIN dw.dim_product    p ON p.product_id  = CAST(s.product_id  AS INT)
    LEFT  JOIN dw.dim_geography  g ON g.city_name   = s.city;

    DECLARE @loaded INT = @@ROWCOUNT;
    PRINT 'dw.usp_load_fact_order_items complete: ' + CAST(@loaded AS VARCHAR) + ' rows.';
END;
GO

-- =============================================================================
-- PROCEDURE 4: dw.usp_load_fact_order_summary
-- Aggregates dw.fact_order_items → dw.fact_order_summary (order-level grain).
-- Always derived from fact_order_items — never from staging directly.
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_load_fact_order_summary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dw.fact_order_summary;

    INSERT INTO dw.fact_order_summary (
        order_date_key,
        customer_sk,
        geography_sk,
        order_id,
        total_items,
        total_quantity,
        order_gross_revenue,
        order_net_revenue,
        order_discount_amount,
        distinct_products
    )
    SELECT
        order_date_key,
        customer_sk,
        geography_sk,
        order_id,
        COUNT(*)                        AS total_items,
        SUM(quantity)                   AS total_quantity,
        ROUND(SUM(gross_revenue), 2)    AS order_gross_revenue,
        ROUND(SUM(net_revenue),   2)    AS order_net_revenue,
        ROUND(SUM(discount_amount),2)   AS order_discount_amount,
        COUNT(DISTINCT product_sk)      AS distinct_products
    FROM dw.fact_order_items
    GROUP BY order_date_key, customer_sk, geography_sk, order_id;

    DECLARE @loaded INT = @@ROWCOUNT;
    PRINT 'dw.usp_load_fact_order_summary complete: ' + CAST(@loaded AS VARCHAR) + ' rows.';
END;
GO

-- =============================================================================
-- PROCEDURE 5: dw.usp_load_fact_monthly_performance
-- Aggregates dw.fact_order_items → dw.fact_monthly_product_performance.
-- Includes month-over-month delta calculation using LAG().
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_load_fact_monthly_performance
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dw.fact_monthly_product_performance;

    ;WITH monthly_base AS (
        SELECT
            d.year_month                                AS year_month_key,
            f.product_sk,
            SUM(f.quantity)                             AS total_units_sold,
            COUNT(DISTINCT f.order_id)                  AS total_orders,
            ROUND(SUM(f.gross_revenue), 2)              AS total_gross_revenue,
            ROUND(SUM(f.net_revenue),   2)              AS total_net_revenue,
            ROUND(AVG(f.unit_price),    2)              AS avg_unit_price,
            ROUND(AVG(f.net_revenue),   2)              AS avg_order_value,
            COUNT(DISTINCT f.customer_sk)               AS total_customers
        FROM dw.fact_order_items f
        JOIN dw.dim_date          d ON d.date_key = f.order_date_key
        GROUP BY d.year_month, f.product_sk
    ),
    monthly_with_lag AS (
        SELECT
            *,
            LAG(total_net_revenue) OVER (
                PARTITION BY product_sk ORDER BY year_month_key
            )                                           AS prior_month_revenue,
            LAG(total_units_sold)  OVER (
                PARTITION BY product_sk ORDER BY year_month_key
            )                                           AS prior_month_units
        FROM monthly_base
    )
    INSERT INTO dw.fact_monthly_product_performance (
        year_month_key,
        product_sk,
        total_units_sold,
        total_orders,
        total_gross_revenue,
        total_net_revenue,
        avg_unit_price,
        avg_order_value,
        total_customers,
        revenue_mom_change_pct,
        units_mom_change_pct
    )
    SELECT
        year_month_key,
        product_sk,
        total_units_sold,
        total_orders,
        total_gross_revenue,
        total_net_revenue,
        avg_unit_price,
        avg_order_value,
        total_customers,
        -- MoM revenue change %
        CASE
            WHEN prior_month_revenue IS NULL OR prior_month_revenue = 0 THEN NULL
            ELSE ROUND(
                (total_net_revenue - prior_month_revenue) / prior_month_revenue, 4)
        END                                             AS revenue_mom_change_pct,
        -- MoM units change %
        CASE
            WHEN prior_month_units IS NULL OR prior_month_units = 0 THEN NULL
            ELSE ROUND(
                (CAST(total_units_sold AS DECIMAL(10,2)) - prior_month_units)
                / prior_month_units, 4)
        END                                             AS units_mom_change_pct
    FROM monthly_with_lag;

    DECLARE @loaded INT = @@ROWCOUNT;
    PRINT 'dw.usp_load_fact_monthly_performance complete: ' + CAST(@loaded AS VARCHAR) + ' rows.';
END;
GO

-- =============================================================================
-- PROCEDURE 6: dw.usp_refresh_analytics_cache
-- Refreshes customer segment + LTV stats in dim_customer after facts load.
-- Run as the final step of each ETL cycle.
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_refresh_analytics_cache
AS
BEGIN
    SET NOCOUNT ON;

    -- Recompute segment + lifetime value from the loaded fact table
    UPDATE c
    SET
        c.total_orders         = ISNULL(agg.total_orders, 0),
        c.total_lifetime_value = ISNULL(agg.total_ltv, 0),
        c.customer_segment = CASE
            WHEN ISNULL(agg.total_ltv, 0) >= 20000
              OR ISNULL(agg.total_orders, 0) >= 5   THEN 'High Value'
            WHEN ISNULL(agg.total_ltv, 0) >= 8000
              OR ISNULL(agg.total_orders, 0) >= 3   THEN 'Regular'
            WHEN ISNULL(agg.total_orders, 0) = 1    THEN 'New'
            ELSE                                         'Developing'
        END,
        c.last_updated_date = SYSUTCDATETIME()
    FROM dw.dim_customer c
    LEFT JOIN (
        SELECT
            customer_sk,
            COUNT(DISTINCT order_id) AS total_orders,
            SUM(net_revenue)         AS total_ltv
        FROM dw.fact_order_items
        GROUP BY customer_sk
    ) agg ON agg.customer_sk = c.customer_sk;

    DECLARE @refreshed INT = @@ROWCOUNT;
    PRINT 'dw.usp_refresh_analytics_cache complete: '
          + CAST(@refreshed AS VARCHAR) + ' customers refreshed.';
END;
GO

-- =============================================================================
-- PROCEDURE 7: dw.usp_run_full_etl
-- Master procedure — calls all 6 load procs in the correct order.
-- Can be invoked directly from Azure Data Factory or SQL Agent Job.
-- Usage: EXEC dw.usp_run_full_etl;
-- =============================================================================
CREATE OR ALTER PROCEDURE dw.usp_run_full_etl
    @etl_load_id VARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start DATETIME2 = SYSUTCDATETIME();
    SET @etl_load_id = ISNULL(@etl_load_id, CAST(NEWID() AS VARCHAR(100)));

    PRINT '============================================';
    PRINT 'ITC DW FULL ETL — START ' + CAST(SYSUTCDATETIME() AS VARCHAR);
    PRINT 'Batch ID: ' + @etl_load_id;
    PRINT '============================================';

    BEGIN TRY
        EXEC dw.usp_load_dim_customer;
        EXEC dw.usp_load_dim_product;
        EXEC dw.usp_load_fact_order_items   @etl_load_id = @etl_load_id;
        EXEC dw.usp_load_fact_order_summary;
        EXEC dw.usp_load_fact_monthly_performance;
        EXEC dw.usp_refresh_analytics_cache;

        DECLARE @elapsed_ms INT =
            DATEDIFF(MILLISECOND, @start, SYSUTCDATETIME());

        PRINT '============================================';
        PRINT 'ITC DW FULL ETL — COMPLETE in '
              + CAST(@elapsed_ms / 1000.0 AS VARCHAR(10)) + 's';
        PRINT '============================================';
    END TRY
    BEGIN CATCH
        PRINT 'ETL FAILED: ' + ERROR_MESSAGE();
        THROW;  -- Re-raise so ADF / calling process sees the failure
    END CATCH;
END;
GO

PRINT 'All stored procedures created successfully.';
GO
