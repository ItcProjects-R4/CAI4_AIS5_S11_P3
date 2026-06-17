-- =============================================================================
-- FILE: 04_dimension_tables.sql
-- PURPOSE: Create all Dimension tables in the Star Schema (dw schema).
--          Dimensions provide descriptive context for facts.
--          All use surrogate integer PKs (not source natural keys) for:
--            - Faster JOIN performance
--            - Isolation from source system key changes
--            - Support for SCD Type 2 (history tracking)
-- LAYER: Data Warehouse (dw)
-- =============================================================================

USE ITC_DataWarehouse;
GO

-- =============================================================================
-- DIMENSION 1: dw.dim_date
-- Purpose  : The "Time" dimension. Pre-populated with every calendar day
--            from 2019-01-01 through 2030-12-31 by the ETL. Allows rich
--            date-based slicing without DATEPART() calls in queries.
-- PK       : date_key (YYYYMMDD integer — human-readable surrogate)
-- Used by  : fact_order_items.order_date_key, fact_order_items.signup_date_key
-- =============================================================================
IF OBJECT_ID('dw.dim_date', 'U') IS NOT NULL DROP TABLE dw.dim_date;
GO

CREATE TABLE dw.dim_date (
    date_key            INT             NOT NULL,   -- YYYYMMDD, e.g. 20230115
    full_date           DATE            NOT NULL,   -- 2023-01-15
    day_of_month        TINYINT         NOT NULL,   -- 1–31
    day_name            NVARCHAR(20)    NOT NULL,   -- 'Monday'
    day_of_week         TINYINT         NOT NULL,   -- 1=Sunday, 7=Saturday (ISO: 1=Mon)
    day_of_year         SMALLINT        NOT NULL,   -- 1–366
    week_of_year        TINYINT         NOT NULL,   -- ISO week number
    month_number        TINYINT         NOT NULL,   -- 1–12
    month_name          NVARCHAR(20)    NOT NULL,   -- 'January'
    month_name_short    CHAR(3)         NOT NULL,   -- 'Jan'
    quarter_number      TINYINT         NOT NULL,   -- 1–4
    quarter_name        CHAR(2)         NOT NULL,   -- 'Q1'
    year_number         SMALLINT        NOT NULL,   -- 2023
    year_month          CHAR(7)         NOT NULL,   -- '2023-01'
    year_quarter        CHAR(7)         NOT NULL,   -- '2023-Q1'
    is_weekend          BIT             NOT NULL,   -- 1 if Sat/Sun
    is_weekday          BIT             NOT NULL,   -- 1 if Mon–Fri
    is_leap_year        BIT             NOT NULL,
    days_in_month       TINYINT         NOT NULL,

    CONSTRAINT pk_dim_date PRIMARY KEY CLUSTERED (date_key)
);
GO

-- Unique constraint on actual date (useful for ETL upserts)
CREATE UNIQUE INDEX uix_dim_date_full_date ON dw.dim_date (full_date);
GO

-- =============================================================================
-- DIMENSION 2: dw.dim_customer
-- Purpose  : One row per unique customer. SCD Type 1 (overwrite on change)
--            for most attributes; surrogate key allows safe updates.
-- PK       : customer_sk   (surrogate, system-generated)
-- NK       : customer_id   (natural key from source system)
-- Used by  : fact_order_items.customer_sk
-- =============================================================================
IF OBJECT_ID('dw.dim_customer', 'U') IS NOT NULL DROP TABLE dw.dim_customer;
GO

CREATE TABLE dw.dim_customer (
    -- ── Surrogate Key ─────────────────────────────────────────────────────────
    customer_sk         INT             NOT NULL IDENTITY(1,1),

    -- ── Natural Key (from source) ─────────────────────────────────────────────
    customer_id         INT             NOT NULL,   -- Source customer_id

    -- ── Customer Attributes ───────────────────────────────────────────────────
    customer_name       NVARCHAR(300)   NOT NULL,
    email               NVARCHAR(300)   NOT NULL,
    signup_date         DATE            NOT NULL,
    signup_year         SMALLINT        NOT NULL,   -- Derived: YEAR(signup_date)
    signup_month        TINYINT         NOT NULL,   -- Derived: MONTH(signup_date)

    -- ── Geography Attributes (denormalised here for simplicity) ───────────────
    city                NVARCHAR(100)   NOT NULL,
    country             NVARCHAR(100)   NOT NULL DEFAULT 'Egypt',
    region              NVARCHAR(100)   NOT NULL DEFAULT 'MENA',

    -- ── Segmentation (computed by ETL based on order history) ─────────────────
    customer_segment    NVARCHAR(50)    NULL,       -- 'High Value','Regular','New'
    total_orders        INT             NOT NULL DEFAULT 0,
    total_lifetime_value DECIMAL(18,2)  NOT NULL DEFAULT 0,

    -- ── SCD Type 1 Audit ─────────────────────────────────────────────────────
    created_date        DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),
    last_updated_date   DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),
    is_active           BIT             NOT NULL DEFAULT 1,

    CONSTRAINT pk_dim_customer PRIMARY KEY CLUSTERED (customer_sk)
);
GO

-- Unique natural key constraint — one DW record per source customer
CREATE UNIQUE INDEX uix_dim_customer_natural_key
    ON dw.dim_customer (customer_id);
GO

-- City lookup is very common in marketing analytics
CREATE INDEX ix_dim_customer_city
    ON dw.dim_customer (city);
GO

CREATE INDEX ix_dim_customer_segment
    ON dw.dim_customer (customer_segment);
GO

-- =============================================================================
-- DIMENSION 3: dw.dim_product
-- Purpose  : One row per unique product. Captures product master data.
--            SCD Type 1: price is updated to latest value; no history kept.
--            Extend to SCD Type 2 (with effective_from / effective_to)
--            if price history tracking becomes a requirement.
-- PK       : product_sk  (surrogate)
-- NK       : product_id  (source natural key)
-- Used by  : fact_order_items.product_sk
-- =============================================================================
IF OBJECT_ID('dw.dim_product', 'U') IS NOT NULL DROP TABLE dw.dim_product;
GO

CREATE TABLE dw.dim_product (
    -- ── Surrogate Key ─────────────────────────────────────────────────────────
    product_sk          INT             NOT NULL IDENTITY(1,1),

    -- ── Natural Key ───────────────────────────────────────────────────────────
    product_id          INT             NOT NULL,

    -- ── Product Attributes ────────────────────────────────────────────────────
    product_name        NVARCHAR(300)   NOT NULL,
    category            NVARCHAR(100)   NOT NULL,
    unit_price          DECIMAL(18, 2)  NOT NULL,

    -- ── Price Banding (for aggregated analysis without CASE in queries) ───────
    price_band          NVARCHAR(50)    NOT NULL,
    -- Values: 'Budget (<500)', 'Mid-Range (500-2000)',
    --         'Premium (2000-4000)', 'Luxury (4000+)'

    -- ── Audit ─────────────────────────────────────────────────────────────────
    created_date        DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),
    last_updated_date   DATETIME2(3)    NOT NULL DEFAULT SYSUTCDATETIME(),
    is_active           BIT             NOT NULL DEFAULT 1,

    CONSTRAINT pk_dim_product PRIMARY KEY CLUSTERED (product_sk)
);
GO

CREATE UNIQUE INDEX uix_dim_product_natural_key
    ON dw.dim_product (product_id);
GO

CREATE INDEX ix_dim_product_category
    ON dw.dim_product (category);
GO

CREATE INDEX ix_dim_product_price_band
    ON dw.dim_product (price_band);
GO

-- =============================================================================
-- DIMENSION 4: dw.dim_geography
-- Purpose  : Geographic hierarchy. Currently city-level (Egypt).
--            Designed to expand to country / region / governorate levels.
--            Separate from dim_customer so the same city appears once.
-- PK       : geography_sk (surrogate)
-- NK       : city_name    (natural key from source)
-- Used by  : fact_order_items.geography_sk
-- =============================================================================
IF OBJECT_ID('dw.dim_geography', 'U') IS NOT NULL DROP TABLE dw.dim_geography;
GO

CREATE TABLE dw.dim_geography (
    -- ── Surrogate Key ─────────────────────────────────────────────────────────
    geography_sk        INT             NOT NULL IDENTITY(1,1),

    -- ── Natural Key ───────────────────────────────────────────────────────────
    city_name           NVARCHAR(100)   NOT NULL,

    -- ── Geographic Hierarchy ─────────────────────────────────────────────────
    governorate         NVARCHAR(100)   NULL,       -- Future: e.g. 'Cairo Governorate'
    country             NVARCHAR(100)   NOT NULL DEFAULT 'Egypt',
    country_code        CHAR(2)         NOT NULL DEFAULT 'EG',
    region              NVARCHAR(100)   NOT NULL DEFAULT 'MENA',
    continent           NVARCHAR(50)    NOT NULL DEFAULT 'Africa',

    -- ── Geo-coordinates (populate from geocoding API if needed) ───────────────
    latitude            DECIMAL(9, 6)   NULL,
    longitude           DECIMAL(9, 6)   NULL,

    CONSTRAINT pk_dim_geography PRIMARY KEY CLUSTERED (geography_sk)
);
GO

CREATE UNIQUE INDEX uix_dim_geography_city
    ON dw.dim_geography (city_name);
GO

-- Pre-populate known Egyptian cities from our dataset
INSERT INTO dw.dim_geography (city_name, governorate, latitude, longitude)
VALUES
    ('Cairo',       'Cairo Governorate',        30.0444, 31.2357),
    ('Giza',        'Giza Governorate',         30.0131, 31.2089),
    ('Alexandria',  'Alexandria Governorate',   31.2001, 29.9187),
    ('Mansoura',    'Dakahlia Governorate',     31.0364, 31.3807),
    ('Tanta',       'Gharbia Governorate',      30.7865, 31.0004);
GO

-- =============================================================================
-- DIMENSION 5: dw.dim_channel
-- Purpose  : Marketing / Sales channel dimension. Currently derived from
--            product category patterns; extend when channel data is added
--            to the source system.
-- PK       : channel_sk (surrogate)
-- Used by  : fact_order_items.channel_sk
-- =============================================================================
IF OBJECT_ID('dw.dim_channel', 'U') IS NOT NULL DROP TABLE dw.dim_channel;
GO

CREATE TABLE dw.dim_channel (
    -- ── Surrogate Key ─────────────────────────────────────────────────────────
    channel_sk          INT             NOT NULL IDENTITY(1,1),

    -- ── Channel Attributes ────────────────────────────────────────────────────
    channel_name        NVARCHAR(100)   NOT NULL,   -- 'Online', 'Mobile', 'Retail'
    channel_type        NVARCHAR(100)   NOT NULL,   -- 'Direct', 'Partner', 'Organic'
    channel_category    NVARCHAR(100)   NULL,       -- Maps to product categories

    CONSTRAINT pk_dim_channel PRIMARY KEY CLUSTERED (channel_sk)
);
GO

-- Seed with known channels
INSERT INTO dw.dim_channel (channel_name, channel_type, channel_category)
VALUES
    ('Online Store',    'Direct',   NULL),
    ('Mobile App',      'Direct',   NULL),
    ('Email Campaign',  'Direct',   NULL),
    ('Social Media',    'Organic',  NULL),
    ('Search (SEO)',    'Organic',  NULL),
    ('Paid Search',     'Partner',  NULL),
    ('Unknown',         'Unknown',  NULL);
GO

PRINT 'All dimension tables created: dim_date | dim_customer | dim_product | dim_geography | dim_channel';
GO
