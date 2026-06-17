-- =============================================================================
-- FILE: 08_analytics_queries.sql (Corrected)
-- =============================================================================

USE ITC_DataWarehouse;
GO

-- =============================================================================
-- SECTION 1: REVENUE ANALYSIS
-- =============================================================================

-- ── 1A. Total Revenue by Year and Quarter ────────────────────────────────────
SELECT
    d.year_number,
    d.quarter_name,
    d.year_quarter,
    COUNT(DISTINCT f.order_id)          AS total_orders,
    COUNT(DISTINCT f.customer_sk)       AS unique_customers,
    SUM(f.quantity)                     AS total_units_sold,
    SUM(f.gross_revenue)                AS gross_revenue,
    SUM(f.net_revenue)                  AS net_revenue,
    SUM(f.discount_amount)              AS total_discounts,
    AVG(f.net_revenue)                  AS avg_order_item_value,
    SUM(f.net_revenue) / NULLIF(COUNT(DISTINCT f.customer_sk), 0)
                                        AS revenue_per_customer
FROM  dw.fact_order_items   f
JOIN  dw.dim_date            d ON d.date_key = f.order_date_key
-- تم إضافة d.quarter_number هنا لحل الإيرور
GROUP BY d.year_number, d.quarter_number, d.quarter_name, d.year_quarter 
ORDER BY d.year_number, d.quarter_number;
GO

-- ── 1B. Monthly Revenue with Month-over-Month Growth ─────────────────────────
WITH monthly_revenue AS (
    SELECT
        d.year_month,
        d.year_number,
        d.month_number,
        d.month_name,
        SUM(f.net_revenue)              AS net_revenue,
        COUNT(DISTINCT f.order_id)      AS total_orders,
        COUNT(DISTINCT f.customer_sk)   AS unique_customers
    FROM  dw.fact_order_items f
    JOIN  dw.dim_date          d ON d.date_key = f.order_date_key
    GROUP BY d.year_month, d.year_number, d.month_number, d.month_name
)
SELECT
    year_month,
    year_number,
    month_name,
    net_revenue,
    total_orders,
    unique_customers,
    LAG(net_revenue) OVER (ORDER BY year_month)  AS prior_month_revenue,
    CASE
        WHEN LAG(net_revenue) OVER (ORDER BY year_month) IS NULL THEN NULL
        ELSE ROUND(
            (net_revenue - LAG(net_revenue) OVER (ORDER BY year_month))
            / NULLIF(LAG(net_revenue) OVER (ORDER BY year_month), 0) * 100, 2)
    END                                          AS mom_growth_pct,
    SUM(net_revenue) OVER (
        PARTITION BY year_number
        ORDER BY month_number
        ROWS UNBOUNDED PRECEDING
    )                                            AS ytd_revenue
FROM monthly_revenue
ORDER BY year_month;
GO

-- ── 1C. Revenue by Product Category ──────────────────────────────────────────
SELECT
    p.category,
    d.year_number,
    SUM(f.net_revenue)                  AS net_revenue,
    SUM(f.gross_revenue)                AS gross_revenue,
    SUM(f.discount_amount)              AS total_discounts,
    COUNT(DISTINCT f.order_id)          AS total_orders,
    SUM(f.quantity)                     AS units_sold,
    ROUND(
        SUM(f.net_revenue) * 100.0 /
        SUM(SUM(f.net_revenue)) OVER (PARTITION BY d.year_number), 2
    )                                   AS revenue_share_pct,
    AVG(f.unit_price)                   AS avg_unit_price
FROM  dw.fact_order_items   f
JOIN  dw.dim_product         p ON p.product_sk      = f.product_sk
JOIN  dw.dim_date            d ON d.date_key         = f.order_date_key
GROUP BY p.category, d.year_number
ORDER BY d.year_number, net_revenue DESC;
GO

-- =============================================================================
-- SECTION 2: PRODUCT PERFORMANCE
-- =============================================================================

-- ── 2A. Top 20 Products by Net Revenue (All Time) ────────────────────────────
SELECT TOP 20
    p.product_id,
    p.product_name,
    p.category,
    p.price_band,
    p.unit_price,
    COUNT(DISTINCT f.order_id)          AS total_orders,
    SUM(f.quantity)                     AS total_units_sold,
    SUM(f.net_revenue)                  AS total_net_revenue,
    SUM(f.gross_revenue)                AS total_gross_revenue,
    AVG(f.quantity)                     AS avg_qty_per_order,
    RANK() OVER (
        PARTITION BY p.category
        ORDER BY SUM(f.net_revenue) DESC
    )                                   AS rank_in_category
FROM  dw.fact_order_items   f
JOIN  dw.dim_product         p ON p.product_sk = f.product_sk
GROUP BY p.product_id, p.product_name, p.category, p.price_band, p.unit_price
ORDER BY total_net_revenue DESC;
GO

-- ── 2B. Product Performance by Category with ABC Classification ──────────────
WITH product_revenue AS (
    SELECT
        p.product_sk,
        p.product_name,
        p.category,
        SUM(f.net_revenue)      AS net_revenue,
        SUM(f.quantity)         AS units_sold,
        COUNT(DISTINCT f.order_id) AS order_count
    FROM  dw.fact_order_items f
    JOIN  dw.dim_product       p ON p.product_sk = f.product_sk
    GROUP BY p.product_sk, p.product_name, p.category
),
ranked AS (
    SELECT *,
        SUM(net_revenue) OVER ()                        AS grand_total_revenue,
        SUM(net_revenue) OVER (ORDER BY net_revenue DESC
            ROWS UNBOUNDED PRECEDING)                   AS running_revenue
    FROM product_revenue
)
SELECT
    product_name,
    category,
    net_revenue,
    units_sold,
    order_count,
    ROUND(net_revenue * 100.0 / grand_total_revenue, 2)     AS revenue_pct,
    ROUND(running_revenue * 100.0 / grand_total_revenue, 2) AS cumulative_pct,
    CASE
        WHEN running_revenue * 100.0 / grand_total_revenue <= 70  THEN 'A - High Value'
        WHEN running_revenue * 100.0 / grand_total_revenue <= 90  THEN 'B - Mid Value'
        ELSE                                                      'C - Low Value'
    END                                                     AS abc_class
FROM ranked
ORDER BY net_revenue DESC;
GO

-- =============================================================================
-- SECTION 3: CUSTOMER SEGMENTATION & ANALYSIS
-- =============================================================================

-- ── 3A. RFM Segmentation ─────────────────────────────────────────────────────
WITH rfm_raw AS (
    SELECT
        c.customer_sk,
        c.customer_id,
        c.customer_name,
        c.city,
        c.email,
        DATEDIFF(DAY,
            MAX(d.full_date),
            CAST('2025-03-01' AS DATE))                 AS recency_days,
        COUNT(DISTINCT f.order_id)                      AS frequency,
        SUM(f.net_revenue)                              AS monetary_value
    FROM  dw.fact_order_items  f
    JOIN  dw.dim_customer       c ON c.customer_sk  = f.customer_sk
    JOIN  dw.dim_date           d ON d.date_key     = f.order_date_key
    GROUP BY c.customer_sk, c.customer_id, c.customer_name, c.city, c.email
),
rfm_scored AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days ASC)   AS r_score,
        NTILE(5) OVER (ORDER BY frequency    ASC)   AS f_score,
        NTILE(5) OVER (ORDER BY monetary_value ASC) AS m_score
    FROM rfm_raw
)
SELECT
    customer_id,
    customer_name,
    city,
    recency_days,
    frequency,
    ROUND(monetary_value, 2)        AS monetary_value,
    r_score, f_score, m_score,
    (r_score + f_score + m_score)   AS rfm_total_score,
    CASE
        WHEN r_score >= 4 AND f_score >= 4 AND m_score >= 4 THEN 'Champions'
        WHEN r_score >= 3 AND f_score >= 3                  THEN 'Loyal Customers'
        WHEN r_score >= 4 AND f_score <= 2                  THEN 'Recent Customers'
        WHEN r_score <= 2 AND f_score >= 3 AND m_score >= 3 THEN 'At Risk'
        WHEN r_score <= 2 AND f_score <= 2 AND m_score <= 2 THEN 'Lost'
        WHEN m_score >= 4                                   THEN 'High Spenders'
        ELSE                                                     'Regular'
    END                             AS customer_segment
FROM rfm_scored
ORDER BY rfm_total_score DESC;
GO

-- ── 3B. Customer Cohort Retention Analysis ───────────────────────────────────
WITH first_order AS (
    SELECT
        c.customer_sk,
        MIN(d.year_month)   AS cohort_month
    FROM  dw.fact_order_items  f
    JOIN  dw.dim_customer       c ON c.customer_sk = f.customer_sk
    JOIN  dw.dim_date           d ON d.date_key    = f.order_date_key
    GROUP BY c.customer_sk
),
orders_with_cohort AS (
    SELECT
        f.customer_sk,
        fo.cohort_month,
        d.year_month        AS order_month,
        DATEDIFF(MONTH,
            CAST(fo.cohort_month + '-01' AS DATE),
            CAST(d.year_month   + '-01' AS DATE))   AS months_since_first
    FROM  dw.fact_order_items  f
    JOIN  dw.dim_date           d  ON d.date_key    = f.order_date_key
    JOIN  first_order           fo ON fo.customer_sk = f.customer_sk
)
SELECT
    cohort_month,
    months_since_first,
    COUNT(DISTINCT customer_sk)             AS active_customers,
    MAX(COUNT(DISTINCT customer_sk)) OVER (
        PARTITION BY cohort_month
    )                                       AS cohort_size,
    ROUND(
        COUNT(DISTINCT customer_sk) * 100.0 /
        MAX(COUNT(DISTINCT customer_sk)) OVER (PARTITION BY cohort_month), 2
    )                                       AS retention_pct
FROM orders_with_cohort
WHERE months_since_first BETWEEN 0 AND 12
GROUP BY cohort_month, months_since_first
ORDER BY cohort_month, months_since_first;
GO

-- ── 3C. Customer Lifetime Value (CLV) Ranking ────────────────────────────────
SELECT
    c.customer_id,
    c.customer_name,
    c.city,
    c.signup_date,
    COUNT(DISTINCT f.order_id)              AS total_orders,
    SUM(f.quantity)                         AS total_items_bought,
    SUM(f.net_revenue)                      AS lifetime_value,
    AVG(f.net_revenue)                      AS avg_order_value,
    MAX(d.full_date)                        AS last_order_date,
    DATEDIFF(DAY, c.signup_date, MAX(d.full_date))
                                            AS customer_age_days,
    PERCENT_RANK() OVER (ORDER BY SUM(f.net_revenue))
                                            AS clv_percentile,
    NTILE(4) OVER (ORDER BY SUM(f.net_revenue))
                                            AS clv_quartile
FROM  dw.fact_order_items  f
JOIN  dw.dim_customer       c ON c.customer_sk = f.customer_sk
JOIN  dw.dim_date           d ON d.date_key    = f.order_date_key
GROUP BY c.customer_id, c.customer_name, c.city, c.signup_date
ORDER BY lifetime_value DESC;
GO

-- =============================================================================
-- SECTION 4: GEOGRAPHIC ANALYSIS
-- =============================================================================

-- ── 4A. Revenue and Orders by City ───────────────────────────────────────────
SELECT
    g.city_name,
    g.country,
    d.year_number,
    COUNT(DISTINCT f.order_id)          AS total_orders,
    COUNT(DISTINCT f.customer_sk)       AS unique_customers,
    SUM(f.net_revenue)                  AS net_revenue,
    AVG(f.net_revenue)                  AS avg_order_value,
    SUM(f.quantity)                     AS units_sold,
    ROUND(
        SUM(f.net_revenue) * 100.0 /
        SUM(SUM(f.net_revenue)) OVER (PARTITION BY d.year_number), 2
    )                                   AS city_revenue_share_pct,
    RANK() OVER (
        PARTITION BY d.year_number
        ORDER BY SUM(f.net_revenue) DESC
    )                                   AS city_rank
FROM  dw.fact_order_items  f
JOIN  dw.dim_geography      g ON g.geography_sk = f.geography_sk
JOIN  dw.dim_date           d ON d.date_key     = f.order_date_key
GROUP BY g.city_name, g.country, d.year_number
ORDER BY d.year_number, net_revenue DESC;
GO

-- ── 4B. City × Category Cross Analysis ───────────────────────────────────────
SELECT
    g.city_name,
    p.category,
    SUM(f.net_revenue)              AS net_revenue,
    COUNT(DISTINCT f.order_id)      AS total_orders,
    SUM(f.quantity)                 AS units_sold
FROM  dw.fact_order_items  f
JOIN  dw.dim_geography      g ON g.geography_sk = f.geography_sk
JOIN  dw.dim_product        p ON p.product_sk   = f.product_sk
GROUP BY g.city_name, p.category
ORDER BY g.city_name, net_revenue DESC;
GO

-- =============================================================================
-- SECTION 5: CONVERSION & FUNNEL METRICS
-- =============================================================================

-- ── 5A. Repeat Purchase Rate ─────────────────────────────────────────────────
WITH customer_order_counts AS (
    SELECT
        customer_sk,
        COUNT(DISTINCT order_id) AS order_count
    FROM dw.fact_order_items
    GROUP BY customer_sk
)
SELECT
    COUNT(*)                                AS total_customers,
    SUM(CASE WHEN order_count = 1 THEN 1 ELSE 0 END) AS one_time_buyers,
    SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) AS repeat_buyers,
    SUM(CASE WHEN order_count >= 5 THEN 1 ELSE 0 END) AS loyal_buyers,
    ROUND(
        SUM(CASE WHEN order_count >= 2 THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2
    )                                       AS repeat_purchase_rate_pct,
    AVG(CAST(order_count AS FLOAT))         AS avg_orders_per_customer
FROM customer_order_counts;
GO

-- ── 5B. Monthly New vs. Returning Customer Orders ────────────────────────────
WITH customer_first_order AS (
    SELECT
        customer_sk,
        MIN(order_date_key) AS first_order_date_key
    FROM dw.fact_order_items
    GROUP BY customer_sk
)
SELECT
    d.year_month,
    COUNT(DISTINCT CASE
        WHEN f.order_date_key = cfo.first_order_date_key THEN f.customer_sk
    END)                                    AS new_customers,
    COUNT(DISTINCT CASE
        WHEN f.order_date_key > cfo.first_order_date_key THEN f.customer_sk
    END)                                    AS returning_customers,
    SUM(CASE
        WHEN f.order_date_key = cfo.first_order_date_key THEN f.net_revenue ELSE 0
    END)                                    AS new_customer_revenue,
    SUM(CASE
        WHEN f.order_date_key > cfo.first_order_date_key THEN f.net_revenue ELSE 0
    END)                                    AS returning_customer_revenue
FROM  dw.fact_order_items      f
JOIN  dw.dim_date               d  ON d.date_key    = f.order_date_key
JOIN  customer_first_order      cfo ON cfo.customer_sk = f.customer_sk
GROUP BY d.year_month
ORDER BY d.year_month;
GO

-- =============================================================================
-- SECTION 6: MARKETING CHANNEL COMPARISON
-- =============================================================================

-- ── 6A. Revenue by Channel ───────────────────────────────────────────────────
SELECT
    ch.channel_name,
    ch.channel_type,
    d.year_number,
    COUNT(DISTINCT f.order_id)      AS total_orders,
    COUNT(DISTINCT f.customer_sk)   AS unique_customers,
    SUM(f.net_revenue)              AS net_revenue,
    AVG(f.net_revenue)              AS avg_order_value,
    SUM(f.quantity)                 AS units_sold,
    ROUND(
        SUM(f.net_revenue) * 100.0 /
        SUM(SUM(f.net_revenue)) OVER (PARTITION BY d.year_number), 2
    )                               AS channel_revenue_share_pct
FROM  dw.fact_order_items  f
JOIN  dw.dim_channel        ch ON ch.channel_sk  = f.channel_sk
JOIN  dw.dim_date           d  ON d.date_key     = f.order_date_key
GROUP BY ch.channel_name, ch.channel_type, d.year_number
ORDER BY d.year_number, net_revenue DESC;
GO

-- ── 6B. Category Performance by Channel ──────────────────────────────────────
SELECT
    ch.channel_name,
    p.category,
    SUM(f.net_revenue)              AS net_revenue,
    COUNT(DISTINCT f.customer_sk)   AS customers,
    AVG(f.net_revenue)              AS avg_order_value
FROM  dw.fact_order_items  f
JOIN  dw.dim_channel        ch ON ch.channel_sk = f.channel_sk
JOIN  dw.dim_product        p  ON p.product_sk  = f.product_sk
GROUP BY ch.channel_name, p.category
ORDER BY ch.channel_name, net_revenue DESC;
GO

-- =============================================================================
-- SECTION 7: EXECUTIVE SUMMARY KPIs
-- =============================================================================

-- ── 7A. Single-Row KPI Summary ───────────────────────────────────────────────
SELECT
    SUM(net_revenue)                        AS total_net_revenue,
    SUM(gross_revenue)                      AS total_gross_revenue,
    SUM(discount_amount)                    AS total_discounts,
    ROUND(SUM(discount_amount) * 100.0 /
          NULLIF(SUM(gross_revenue),0), 2)  AS overall_discount_pct,
    COUNT(DISTINCT order_id)                AS total_orders,
    COUNT(DISTINCT customer_sk)             AS total_customers,
    COUNT(*)                                AS total_line_items,
    SUM(quantity)                           AS total_units_sold,
    ROUND(AVG(net_revenue), 2)              AS avg_order_item_value,
    ROUND(SUM(net_revenue) /
          NULLIF(COUNT(DISTINCT order_id),0), 2)
                                            AS avg_basket_value,
    ROUND(SUM(net_revenue) /
          NULLIF(COUNT(DISTINCT customer_sk),0), 2)
                                            AS avg_customer_value,
    MIN(d.full_date)                        AS data_from_date,
    MAX(d.full_date)                        AS data_to_date,
    DATEDIFF(DAY, MIN(d.full_date), MAX(d.full_date))
                                            AS data_span_days
FROM  dw.fact_order_items  f
JOIN  dw.dim_date           d ON d.date_key = f.order_date_key;
GO

-- =============================================================================
-- ANALYTICS VIEWS 
-- =============================================================================

CREATE OR ALTER VIEW analytics.vw_monthly_revenue AS
SELECT
    d.year_month,
    d.year_number,
    d.month_name,
    d.month_number,
    SUM(f.net_revenue)              AS net_revenue,
    SUM(f.gross_revenue)            AS gross_revenue,
    SUM(f.discount_amount)          AS discounts,
    COUNT(DISTINCT f.order_id)      AS orders,
    COUNT(DISTINCT f.customer_sk)   AS customers,
    SUM(f.quantity)                 AS units_sold
FROM  dw.fact_order_items f
JOIN  dw.dim_date          d ON d.date_key = f.order_date_key
GROUP BY d.year_month, d.year_number, d.month_name, d.month_number;
GO

CREATE OR ALTER VIEW analytics.vw_product_performance AS
SELECT
    p.product_id,
    p.product_name,
    p.category,
    p.price_band,
    p.unit_price,
    SUM(f.net_revenue)              AS total_revenue,
    SUM(f.quantity)                 AS total_units,
    COUNT(DISTINCT f.order_id)      AS total_orders,
    COUNT(DISTINCT f.customer_sk)   AS unique_buyers,
    AVG(f.net_revenue)              AS avg_order_value
FROM  dw.fact_order_items  f
JOIN  dw.dim_product        p ON p.product_sk = f.product_sk
GROUP BY p.product_id, p.product_name, p.category, p.price_band, p.unit_price;
GO

CREATE OR ALTER VIEW analytics.vw_city_performance AS
SELECT
    g.city_name,
    g.country,
    g.latitude,
    g.longitude,
    SUM(f.net_revenue)              AS total_revenue,
    COUNT(DISTINCT f.order_id)      AS total_orders,
    COUNT(DISTINCT f.customer_sk)   AS unique_customers,
    AVG(f.net_revenue)              AS avg_order_value
FROM  dw.fact_order_items  f
JOIN  dw.dim_geography      g ON g.geography_sk = f.geography_sk
GROUP BY g.city_name, g.country, g.latitude, g.longitude;
GO

CREATE OR ALTER VIEW analytics.vw_customer_360 AS
SELECT
    c.customer_id,
    c.customer_name,
    c.email,
    c.city,
    c.signup_date,
    c.customer_segment,
    COUNT(DISTINCT f.order_id)          AS total_orders,
    SUM(f.net_revenue)                  AS lifetime_value,
    AVG(f.net_revenue)                  AS avg_order_value,
    MAX(d.full_date)                    AS last_order_date,
    MIN(d.full_date)                    AS first_order_date,
    DATEDIFF(DAY, MAX(d.full_date), CAST(GETDATE() AS DATE))
                                        AS days_since_last_order
FROM  dw.fact_order_items  f
JOIN  dw.dim_customer       c ON c.customer_sk = f.customer_sk
JOIN  dw.dim_date           d ON d.date_key    = f.order_date_key
GROUP BY
    c.customer_id, c.customer_name, c.email,
    c.city, c.signup_date, c.customer_segment;
GO

PRINT 'All analytics queries and views created successfully.';
GO