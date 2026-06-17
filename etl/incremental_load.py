#!/usr/bin/env python3
# =============================================================================
# FILE: incremental_load.py
# PURPOSE: Production-grade incremental (delta) load capability.
#          Instead of truncating and reloading the full dataset each run,
#          this module detects NEW rows since the last successful load and
#          processes only the delta — dramatically faster for large datasets.
#
# WHEN TO USE:
#   - Dataset grows daily (new orders arriving continuously)
#   - Source CSV is replaced with an API or database feed
#   - Full reload takes too long (typically > 30 min is the threshold)
#
# STRATEGY:
#   - Stores the "high-water mark" (last loaded order_date) in a control table
#   - On each run, only processes rows where order_date > high-water mark
#   - Falls back to full load if no high-water mark exists
#
# USAGE:
#   python incremental_load.py                    # Auto-detect delta
#   python incremental_load.py --full-reload      # Force full reload
#   python incremental_load.py --from 2024-01-01  # Load from specific date
# =============================================================================

import sys
import argparse
from datetime import datetime, date, timedelta

import pandas as pd
import sqlalchemy as sa
from sqlalchemy import text

from config    import get_sqlalchemy_url, get_pyodbc_conn_str, SOURCE_CSV
from logger    import get_logger
from extract_clean import extract_csv, clean_data
from transform import (
    build_dim_customer, build_dim_product,
    build_fact_order_items, build_fact_order_summary,
    build_fact_monthly_product_performance,
)
from load import (
    get_engine, test_connection,
    load_dim_customer, load_dim_product,
)

log = get_logger(__name__)


# =============================================================================
# CONTROL TABLE DDL
# Run once: creates dw.etl_control_table if it doesn't exist.
# =============================================================================

CONTROL_TABLE_DDL = """
IF OBJECT_ID('dw.etl_control_table', 'U') IS NULL
BEGIN
    CREATE TABLE dw.etl_control_table (
        control_id          INT             NOT NULL IDENTITY(1,1),
        pipeline_name       NVARCHAR(200)   NOT NULL,   -- 'fact_order_items_load'
        last_loaded_date    DATE            NULL,        -- High-water mark
        last_run_start      DATETIME2(3)    NULL,
        last_run_end        DATETIME2(3)    NULL,
        last_run_status     NVARCHAR(20)    NULL,        -- 'SUCCESS' | 'FAILED'
        rows_loaded         INT             NULL,
        etl_load_id         VARCHAR(100)    NULL,
        CONSTRAINT pk_etl_control PRIMARY KEY (control_id)
    );

    -- Seed with known pipeline names
    INSERT INTO dw.etl_control_table (pipeline_name, last_run_status)
    VALUES
        ('fact_order_items_full_load',        'NEVER_RUN'),
        ('fact_order_items_incremental_load', 'NEVER_RUN'),
        ('dim_customer_load',                 'NEVER_RUN'),
        ('dim_product_load',                  'NEVER_RUN');
END;
"""


def ensure_control_table(engine: sa.Engine) -> None:
    """Create the ETL control table if it doesn't exist."""
    with engine.connect() as conn:
        conn.execute(text(CONTROL_TABLE_DDL))
        conn.commit()
    log.info("ETL control table verified/created.")


# =============================================================================
# HIGH-WATER MARK MANAGEMENT
# =============================================================================

def get_high_water_mark(engine: sa.Engine, pipeline_name: str) -> date | None:
    """
    Retrieve the last successfully loaded date for a pipeline.
    Returns None if the pipeline has never run successfully.

    Args:
        engine:        SQLAlchemy engine.
        pipeline_name: Name of the pipeline to check.

    Returns:
        date object of last loaded date, or None.
    """
    query = text("""
        SELECT last_loaded_date
        FROM dw.etl_control_table
        WHERE pipeline_name = :name
          AND last_run_status = 'SUCCESS'
    """)
    with engine.connect() as conn:
        result = conn.execute(query, {"name": pipeline_name}).fetchone()

    if result and result[0]:
        log.info(f"High-water mark for '{pipeline_name}': {result[0]}")
        return result[0]

    log.info(f"No high-water mark found for '{pipeline_name}' — will do full load.")
    return None


def set_high_water_mark(
    engine:        sa.Engine,
    pipeline_name: str,
    loaded_date:   date,
    rows_loaded:   int,
    load_id:       str,
    status:        str = "SUCCESS",
) -> None:
    """
    Update the high-water mark after a successful load.

    Args:
        engine:        SQLAlchemy engine.
        pipeline_name: Pipeline name to update.
        loaded_date:   The max order_date that was loaded.
        rows_loaded:   Number of rows loaded in this run.
        load_id:       ETL batch GUID.
        status:        'SUCCESS' or 'FAILED'.
    """
    upsert_sql = text("""
        MERGE dw.etl_control_table AS tgt
        USING (SELECT :name AS pipeline_name) AS src
            ON tgt.pipeline_name = src.pipeline_name
        WHEN MATCHED THEN UPDATE SET
            tgt.last_loaded_date = :loaded_date,
            tgt.last_run_start   = :run_start,
            tgt.last_run_end     = SYSUTCDATETIME(),
            tgt.last_run_status  = :status,
            tgt.rows_loaded      = :rows,
            tgt.etl_load_id      = :load_id
        WHEN NOT MATCHED THEN INSERT (
            pipeline_name, last_loaded_date,
            last_run_start, last_run_end,
            last_run_status, rows_loaded, etl_load_id
        ) VALUES (
            :name, :loaded_date,
            :run_start, SYSUTCDATETIME(),
            :status, :rows, :load_id
        );
    """)

    with engine.connect() as conn:
        conn.execute(upsert_sql, {
            "name":        pipeline_name,
            "loaded_date": str(loaded_date),
            "run_start":   datetime.utcnow().isoformat(),
            "status":      status,
            "rows":        rows_loaded,
            "load_id":     load_id,
        })
        conn.commit()

    log.info(
        f"High-water mark updated: pipeline='{pipeline_name}' "
        f"date={loaded_date} rows={rows_loaded} status={status}"
    )


# =============================================================================
# INCREMENTAL FACT LOAD
# =============================================================================

def load_fact_incremental(
    df:              pd.DataFrame,
    engine:          sa.Engine,
    from_date:       date | None = None,
    full_reload:     bool        = False,
    customer_sk_map: dict        = None,
    product_sk_map:  dict        = None,
) -> tuple[int, date]:
    """
    Load only NEW rows to dw.fact_order_items.

    Strategy:
    1. Determine the delta window (from_date → max date in source).
    2. Filter the clean DataFrame to that window.
    3. DELETE existing rows in the DW for that window (idempotent re-runs).
    4. INSERT the new rows.
    5. Return (rows_inserted, max_order_date).

    Args:
        df:              Full clean DataFrame (all historical rows available).
        engine:          SQLAlchemy engine.
        from_date:       Load rows where order_date > from_date.
                         If None, loads all (full reload).
        full_reload:     If True, truncate-reload regardless of from_date.
        customer_sk_map: {customer_id: customer_sk} from dimension load.
        product_sk_map:  {product_id: product_sk} from dimension load.

    Returns:
        Tuple of (rows_inserted, max_order_date_loaded).
    """
    import uuid
    from transform import build_fact_order_items

    load_id = str(uuid.uuid4())
    df_copy = df.copy()
    df_copy["order_date"] = pd.to_datetime(df_copy["order_date"])

    if full_reload:
        log.info("Full reload mode: truncating fact_order_items ...")
        with engine.connect() as conn:
            conn.execute(text("TRUNCATE TABLE dw.fact_order_items"))
            conn.commit()
        delta_df = df_copy
    elif from_date is not None:
        log.info(f"Incremental load: loading rows where order_date > {from_date}")
        delta_df = df_copy[df_copy["order_date"].dt.date > from_date]

        # Delete any existing rows for this date window (prevents duplicates on rerun)
        from_date_key = int(from_date.strftime("%Y%m%d"))
        delete_sql = text(
            "DELETE FROM dw.fact_order_items WHERE order_date_key > :dk"
        )
        with engine.connect() as conn:
            deleted = conn.execute(delete_sql, {"dk": from_date_key}).rowcount
            conn.commit()
        log.info(f"Deleted {deleted} existing rows for re-load window.")
    else:
        log.info("No high-water mark — loading all rows.")
        delta_df = df_copy

    if len(delta_df) == 0:
        log.info("No new rows to load — data is up to date.")
        max_date = df_copy["order_date"].max().date()
        return 0, max_date

    log.info(f"Delta size: {len(delta_df):,} rows "
             f"({delta_df['order_date'].min().date()} → {delta_df['order_date'].max().date()})")

    # Build fact DataFrame for delta only
    fact_delta = build_fact_order_items(delta_df, customer_sk_map, product_sk_map)
    fact_delta["etl_load_id"] = load_id

    # Append to fact table
    fact_delta.to_sql(
        name="fact_order_items",
        con=engine,
        schema="dw",
        if_exists="append",
        index=False,
        chunksize=500,
        method="multi",
    )

    rows_inserted = len(fact_delta)
    max_date = delta_df["order_date"].max().date()
    log.info(f"Incremental load complete: {rows_inserted:,} rows → max_date={max_date}")

    return rows_inserted, max_date


# =============================================================================
# INCREMENTAL DIMENSION LOAD
# Dimensions always do a full upsert (merge) — they're small enough that
# re-processing all of them on every run is negligible cost.
# =============================================================================

def run_incremental_pipeline(
    from_date:   date | None = None,
    full_reload: bool        = False,
) -> bool:
    """
    Execute the incremental ETL pipeline.

    Args:
        from_date:   Override from-date (bypasses high-water mark lookup).
        full_reload: Force a full truncate-reload.

    Returns:
        True on success, False on failure.
    """
    import uuid

    log.info("=" * 60)
    log.info(f"INCREMENTAL ETL — STARTED {datetime.utcnow().isoformat()}Z")
    log.info("=" * 60)

    engine = get_engine()
    if not test_connection():
        return False

    # Ensure control table exists
    ensure_control_table(engine)

    # Determine high-water mark
    if not full_reload and from_date is None:
        from_date = get_high_water_mark(engine, "fact_order_items_incremental_load")

    # Extract + clean full source (needed to rebuild dims even in incremental mode)
    log.info("Extracting source data ...")
    raw_df   = extract_csv()
    clean_df = clean_data(raw_df)

    # Always upsert dimensions (fast — small tables)
    log.info("Upserting dimensions ...")
    dim_cust_df = build_dim_customer(clean_df)
    dim_prod_df = build_dim_product(clean_df)
    customer_sk_map = load_dim_customer(dim_cust_df, engine)
    product_sk_map  = load_dim_product(dim_prod_df, engine)

    # Load facts (incremental or full)
    rows_loaded, max_date = load_fact_incremental(
        df              = clean_df,
        engine          = engine,
        from_date       = from_date,
        full_reload     = full_reload,
        customer_sk_map = customer_sk_map,
        product_sk_map  = product_sk_map,
    )

    # Rebuild derived facts (always from full fact_order_items)
    log.info("Rebuilding derived facts ...")
    from load import load_fact_order_summary, load_fact_monthly_performance
    from transform import build_fact_order_summary, build_fact_monthly_product_performance

    # Need full fact data for summaries — query from DB
    with engine.connect() as conn:
        full_fact = pd.read_sql(
            "SELECT * FROM dw.fact_order_items", conn
        )

    fact_summary = build_fact_order_summary(full_fact)
    load_fact_order_summary(fact_summary, engine)

    fact_monthly = build_fact_monthly_product_performance(full_fact, product_sk_map)
    load_fact_monthly_performance(fact_monthly, engine)

    # Update high-water mark
    pipeline_name = (
        "fact_order_items_full_load"
        if full_reload else
        "fact_order_items_incremental_load"
    )
    set_high_water_mark(
        engine        = engine,
        pipeline_name = pipeline_name,
        loaded_date   = max_date,
        rows_loaded   = rows_loaded,
        load_id       = str(uuid.uuid4()),
        status        = "SUCCESS",
    )

    log.info("=" * 60)
    log.info(f"INCREMENTAL ETL COMPLETE — {rows_loaded:,} new rows loaded")
    log.info(f"High-water mark advanced to: {max_date}")
    log.info("=" * 60)
    return True


# =============================================================================
# CLI ENTRY POINT
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser(
        description="ITC DW Incremental ETL — loads only new rows since last run."
    )
    parser.add_argument(
        "--full-reload",
        action="store_true",
        help="Ignore high-water mark and reload all historical data.",
    )
    parser.add_argument(
        "--from",
        dest="from_date",
        type=lambda d: datetime.strptime(d, "%Y-%m-%d").date(),
        default=None,
        metavar="YYYY-MM-DD",
        help="Load rows with order_date > this date (overrides high-water mark).",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args    = parse_args()
    success = run_incremental_pipeline(
        from_date   = args.from_date,
        full_reload = args.full_reload,
    )
    sys.exit(0 if success else 1)
