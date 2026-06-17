# =============================================================================
# FILE: load.py
# PURPOSE: Step 3 of the ETL pipeline — Load transformed DataFrames into
#          Azure SQL Database tables using SQLAlchemy + pandas.
#          Uses upsert (merge) logic for dimension tables and
#          append / truncate-reload for fact tables.
# =============================================================================

import time
import pyodbc
import pandas as pd
import sqlalchemy as sa
from sqlalchemy import text

from config import get_sqlalchemy_url, get_pyodbc_conn_str, ETL_BATCH_SIZE
from logger import get_logger

log = get_logger(__name__)


# =============================================================================
# CONNECTION HELPERS
# =============================================================================

def get_engine() -> sa.Engine:
    """Create and return a SQLAlchemy engine for Azure SQL."""
    url = get_sqlalchemy_url()
    engine = sa.create_engine(
        url,
        fast_executemany=True,   # Bulk insert mode — much faster than row-by-row
        pool_size=5,
        pool_recycle=3600,
    )
    log.debug("SQLAlchemy engine created.")
    return engine


def get_pyodbc_connection():
    """Return a raw pyodbc connection for running stored procedures and DDL."""
    conn = pyodbc.connect(get_pyodbc_conn_str(), autocommit=False)
    log.debug("pyodbc connection established.")
    return conn


def test_connection() -> bool:
    """Quick connectivity check before running the full pipeline."""
    try:
        engine = get_engine()
        with engine.connect() as conn:
            result = conn.execute(text("SELECT GETDATE() AS server_time"))
            row = result.fetchone()
            log.info(f"Azure SQL connection OK. Server time: {row[0]}")
            return True
    except Exception as exc:
        log.error(f"Connection test FAILED: {exc}")
        return False


# =============================================================================
# RAW LAYER LOAD
# =============================================================================

def load_raw(df: pd.DataFrame, engine: sa.Engine) -> None:
    """
    Append all rows to raw.ecommerce_orders (no truncation — keeps full history).

    Args:
        df:     Cleaned DataFrame (with etl_load_id / etl_load_date columns).
        engine: SQLAlchemy engine.
    """
    log.info(f"Loading {len(df):,} rows into raw.ecommerce_orders ...")

    # Select only columns that exist in the raw table
    raw_cols = [
        "order_item_id", "order_id", "product_id", "quantity",
        "customer_id", "order_date", "total_amount", "name",
        "city", "email", "signup_date", "product_name",
        "category", "price", "etl_load_id", "etl_load_date", "etl_source_file",
    ]
    # Cast all to string for raw layer (mirrors VARCHAR schema)
    raw_df = df[raw_cols].astype(str)

    raw_df.to_sql(
        name="ecommerce_orders",
        con=engine,
        schema="raw",
        if_exists="append",
        index=False,
        chunksize=ETL_BATCH_SIZE,
        method="multi",
    )
    log.info("raw.ecommerce_orders loaded successfully.")


# =============================================================================
# STAGING LAYER LOAD
# =============================================================================

def load_staging(df: pd.DataFrame, engine: sa.Engine) -> None:
    """
    Truncate and reload staging.order_items (full refresh each run).

    Args:
        df:     Cleaned typed DataFrame.
        engine: SQLAlchemy engine.
    """
    log.info("Truncating staging.order_items ...")
    with engine.connect() as conn:
        conn.execute(text("TRUNCATE TABLE staging.order_items"))
        conn.commit()

    staging_cols = [
        "order_item_id", "order_id", "product_id", "customer_id",
        "quantity", "net_revenue", "order_date",
        "name", "city", "email", "signup_date",
        "product_name", "category", "price",
        "dq_email_valid", "dq_date_valid",
    ]
    rename_map = {
        "net_revenue": "total_amount",
        "name":        "customer_name",
        "price":       "unit_price",
    }

    stg_df = df[staging_cols].rename(columns=rename_map)

    log.info(f"Loading {len(stg_df):,} rows into staging.order_items ...")
    stg_df.to_sql(
        name="order_items",
        con=engine,
        schema="staging",
        if_exists="append",
        index=False,
        chunksize=ETL_BATCH_SIZE,
        method="multi",
    )
    log.info("staging.order_items loaded successfully.")


# =============================================================================
# DIMENSION LOADS  (upsert / merge pattern)
# =============================================================================

def _upsert_dimension(
    df:          pd.DataFrame,
    table_name:  str,
    schema:      str,
    natural_key: str,
    engine:      sa.Engine,
) -> dict:
    """
    Generic dimension upsert using a staging temp table + MERGE statement.
    Returns a dict mapping natural_key value → surrogate_key (for FK resolution).

    Strategy:
        1. Write DataFrame to a temp table (#dim_staging).
        2. MERGE temp → target: UPDATE existing rows, INSERT new rows.
        3. SELECT all natural_key + surrogate_key pairs for FK mapping.
    """
    temp_table = f"#tmp_{table_name}"
    surrogate_col = table_name.replace("dim_", "") + "_sk"

    log.info(f"Upserting {len(df):,} rows into {schema}.{table_name} ...")

    # Step 1: Write to temp table
    df.to_sql(
        name=temp_table.lstrip("#"),
        con=engine,
        schema="dbo",       # Temp tables go to dbo in Azure SQL
        if_exists="replace",
        index=False,
        chunksize=ETL_BATCH_SIZE,
        method="multi",
    )

    # Step 2: MERGE
    update_cols = [c for c in df.columns if c != natural_key]
    update_clause = ",\n        ".join(
        [f"tgt.{c} = src.{c}" for c in update_cols]
    )
    insert_cols   = ", ".join(df.columns)
    insert_values = ", ".join([f"src.{c}" for c in df.columns])

    merge_sql = f"""
    MERGE {schema}.{table_name} AS tgt
    USING dbo.{temp_table.lstrip('#')} AS src
        ON tgt.{natural_key} = src.{natural_key}
    WHEN MATCHED THEN
        UPDATE SET
        {update_clause},
        tgt.last_updated_date = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT ({insert_cols})
        VALUES ({insert_values});
    """

    with engine.connect() as conn:
        conn.execute(text(merge_sql))
        conn.commit()

    # Step 3: Fetch surrogate key map
    sk_query = f"SELECT {natural_key}, {surrogate_col} FROM {schema}.{table_name}"
    with engine.connect() as conn:
        result = conn.execute(text(sk_query))
        sk_map = {row[0]: row[1] for row in result}

    log.info(f"{schema}.{table_name} upsert complete. {len(sk_map)} total rows.")
    return sk_map


def load_dim_customer(df_dim: pd.DataFrame, engine: sa.Engine) -> dict:
    """Load dim_customer and return {customer_id: customer_sk} map."""
    return _upsert_dimension(df_dim, "dim_customer", "dw", "customer_id", engine)


def load_dim_product(df_dim: pd.DataFrame, engine: sa.Engine) -> dict:
    """Load dim_product and return {product_id: product_sk} map."""
    return _upsert_dimension(df_dim, "dim_product", "dw", "product_id", engine)


# =============================================================================
# FACT LOADS  (truncate-reload or append)
# =============================================================================

def load_fact_order_items(df_fact: pd.DataFrame, engine: sa.Engine) -> None:
    """
    Load fact_order_items.
    Uses TRUNCATE + reload (idempotent for full historical loads).
    Switch to incremental append once the dataset grows beyond daily limits.
    """
    log.info("Truncating dw.fact_order_items ...")
    with engine.connect() as conn:
        conn.execute(text("TRUNCATE TABLE dw.fact_order_items"))
        conn.commit()

    log.info(f"Loading {len(df_fact):,} rows into dw.fact_order_items ...")
    t0 = time.time()

    df_fact.to_sql(
        name="fact_order_items",
        con=engine,
        schema="dw",
        if_exists="append",
        index=False,
        chunksize=ETL_BATCH_SIZE,
        method="multi",
    )

    elapsed = round(time.time() - t0, 1)
    log.info(f"dw.fact_order_items loaded in {elapsed}s.")


def load_fact_order_summary(df_fact: pd.DataFrame, engine: sa.Engine) -> None:
    """Truncate-reload dw.fact_order_summary."""
    with engine.connect() as conn:
        conn.execute(text("TRUNCATE TABLE dw.fact_order_summary"))
        conn.commit()

    df_fact.to_sql(
        name="fact_order_summary",
        con=engine,
        schema="dw",
        if_exists="append",
        index=False,
        chunksize=ETL_BATCH_SIZE,
        method="multi",
    )
    log.info(f"dw.fact_order_summary loaded: {len(df_fact):,} rows.")


def load_fact_monthly_performance(df_fact: pd.DataFrame, engine: sa.Engine) -> None:
    """Truncate-reload dw.fact_monthly_product_performance."""
    with engine.connect() as conn:
        conn.execute(text("TRUNCATE TABLE dw.fact_monthly_product_performance"))
        conn.commit()

    df_fact.to_sql(
        name="fact_monthly_product_performance",
        con=engine,
        schema="dw",
        if_exists="append",
        index=False,
        chunksize=ETL_BATCH_SIZE,
        method="multi",
    )
    log.info(f"dw.fact_monthly_product_performance loaded: {len(df_fact):,} rows.")
