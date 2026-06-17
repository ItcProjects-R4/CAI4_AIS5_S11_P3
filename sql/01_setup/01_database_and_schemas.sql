-- =============================================================================
-- FILE: 01_database_and_schemas.sql
-- PURPOSE: Create the ITC E-Commerce Data Warehouse database and all schemas
-- LAYER: Foundation setup (runs first, before any other script)
-- COMPATIBLE: Azure SQL Database / Azure Synapse Analytics
-- AUTHOR: Senior Data Engineering Team
-- DATE: 2025
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- NOTE FOR AZURE SQL DATABASE:
--   Azure SQL does not support CREATE DATABASE inside a script run against
--   an existing connection. Create the database via Azure Portal or Azure CLI:
--
--   az sql db create \
--     --resource-group rg-itc-datawarehouse \
--     --server sql-itc-dw-server \
--     --name ITC_DataWarehouse \
--     --service-objective S3
--
--   Then connect to ITC_DataWarehouse and run the rest of this script.
-- ─────────────────────────────────────────────────────────────────────────────

USE ITC_DataWarehouse;
GO

-- =============================================================================
-- SCHEMA CREATION
-- Each schema represents one LAYER in our modern data warehouse architecture.
-- Separation into schemas provides:
--   1. Security boundaries (GRANT/DENY per schema)
--   2. Logical grouping and namespace clarity
--   3. Independent lifecycle management per layer
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- RAW LAYER
-- Purpose : Land source data exactly as received — no transformations.
--           Acts as an immutable audit trail and replay source.
--           All rows from CSV are inserted here first, preserving original
--           data types as VARCHAR to avoid load-time type failures.
-- ─────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raw')
    EXEC('CREATE SCHEMA raw');
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- STAGING LAYER
-- Purpose : Apply data quality rules, type casting, deduplication, and
--           business-rule transformations. Data here is cleaned but not yet
--           modelled. Tables are truncated and reloaded on every ETL run.
-- ─────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'staging')
    EXEC('CREATE SCHEMA staging');
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- DATA WAREHOUSE LAYER  (the Star Schema lives here)
-- Purpose : Conformed, modelled, history-complete data. Fact and Dimension
--           tables. This is what BI tools and analysts query directly.
--           Data here is never deleted; new versions are added (SCD Type 2
--           where applicable).
-- ─────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')
    EXEC('CREATE SCHEMA dw');
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- ANALYTICS LAYER
-- Purpose : Pre-aggregated views, materialised summaries, and KPI tables
--           purpose-built for dashboards and ad-hoc reporting. Never stores
--           source data — derived from the dw schema only.
-- ─────────────────────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'analytics')
    EXEC('CREATE SCHEMA analytics');
GO

PRINT 'All schemas created successfully: raw | staging | dw | analytics';
GO
