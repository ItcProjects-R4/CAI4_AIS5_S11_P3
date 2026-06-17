#!/usr/bin/env python3
# =============================================================================
# FILE: main_etl.py
# PURPOSE: Master orchestrator for the ITC E-Commerce Data Warehouse ETL.
#          Run this single script to execute the complete pipeline:
#
#   CSV File
#     └─► [EXTRACT]  extract_clean.extract_csv()
#     └─► [CLEAN]    extract_clean.clean_data()
#     └─► [LOAD RAW] load.load_raw()
#     └─► [STAGE]    load.load_staging()
#     └─► [TRANSFORM DIMS] transform.build_dim_*()
#     └─► [LOAD DIMS]      load.load_dim_*()
#     └─► [TRANSFORM FACTS] transform.build_fact_*()
#     └─► [LOAD FACTS]      load.load_fact_*()
#
# USAGE:
#   python main_etl.py                     # Full pipeline
#   python main_etl.py --dry-run           # Clean & transform only (no DB writes)
#   python main_etl.py --skip-raw          # Skip raw layer (faster reruns)
# =============================================================================

import sys
import time
import argparse
import traceback
from datetime import datetime

from logger  import get_logger
from extract_clean import extract_csv, clean_data, save_processed
from transform     import (
    build_dim_customer,
    build_dim_product,
    build_fact_order_items,
    build_fact_order_summary,
    build_fact_monthly_product_performance,
)
from load import (
    get_engine,
    test_connection,
    load_raw,
    load_staging,
    load_dim_customer,
    load_dim_product,
    load_fact_order_items,
    load_fact_order_summary,
    load_fact_monthly_performance,
)

log = get_logger("main_etl")


# =============================================================================
# PIPELINE STEPS (each wrapped for independent error handling)
# =============================================================================

def step(name: str):
    """Decorator-like context manager for pipeline step logging."""
    class _Step:
        def __enter__(self):
            log.info(f"{'='*60}")
            log.info(f"STEP START: {name}")
            self.t0 = time.time()
            return self

        def __exit__(self, exc_type, exc_val, exc_tb):
            elapsed = round(time.time() - self.t0, 2)
            if exc_type:
                log.error(f"STEP FAILED: {name} after {elapsed}s — {exc_val}")
                traceback.print_exc()
                return False     # Re-raise
            log.info(f"STEP DONE : {name} in {elapsed}s")
            return True

    return _Step()


def run_pipeline(dry_run: bool = False, skip_raw: bool = False) -> bool:
    """
    Execute the full ETL pipeline.

    Args:
        dry_run:  If True, extract and transform only — do not write to DB.
        skip_raw: If True, skip the raw.ecommerce_orders append (for reruns).

    Returns:
        True on success, False on failure.
    """
    pipeline_start = time.time()
    log.info("=" * 60)
    log.info(f"ITC DATA WAREHOUSE ETL — STARTED {datetime.utcnow().isoformat()}Z")
    log.info(f"Mode: {'DRY RUN' if dry_run else 'LIVE'} | skip_raw={skip_raw}")
    log.info("=" * 60)

    # ── 1. Connectivity check ─────────────────────────────────────────────────
    if not dry_run:
        with step("Connection Test"):
            if not test_connection():
                log.error("Cannot connect to Azure SQL. Aborting.")
                return False
        engine = get_engine()

    # ── 2. Extract ────────────────────────────────────────────────────────────
    with step("Extract CSV"):
        raw_df = extract_csv()

    # ── 3. Clean ──────────────────────────────────────────────────────────────
    with step("Clean & Validate Data"):
        clean_df = clean_data(raw_df)
        save_processed(clean_df)      # Save parquet audit copy

    if dry_run:
        log.info("DRY RUN complete — no database writes performed.")
        log.info(f"Clean DataFrame shape: {clean_df.shape}")
        print(clean_df.describe(include="all").to_string())
        return True

    # ── 4. Load Raw Layer ─────────────────────────────────────────────────────
    if not skip_raw:
        with step("Load Raw Layer"):
            load_raw(clean_df, engine)
    else:
        log.info("Skipping raw layer load (--skip-raw flag set).")

    # ── 5. Load Staging Layer ─────────────────────────────────────────────────
    with step("Load Staging Layer"):
        load_staging(clean_df, engine)

    # ── 6. Build & Load Dimension Tables ─────────────────────────────────────
    with step("Build dim_customer"):
        dim_customer_df = build_dim_customer(clean_df)

    with step("Load dim_customer"):
        customer_sk_map = load_dim_customer(dim_customer_df, engine)
        log.info(f"Customer SK map: {len(customer_sk_map)} entries")

    with step("Build dim_product"):
        dim_product_df = build_dim_product(clean_df)

    with step("Load dim_product"):
        product_sk_map = load_dim_product(dim_product_df, engine)
        log.info(f"Product SK map: {len(product_sk_map)} entries")

    # ── 7. Build & Load Fact Tables ──────────────────────────────────────────
    with step("Build fact_order_items"):
        fact_items_df = build_fact_order_items(
            clean_df, customer_sk_map, product_sk_map
        )

    with step("Load fact_order_items"):
        load_fact_order_items(fact_items_df, engine)

    with step("Build fact_order_summary"):
        fact_summary_df = build_fact_order_summary(fact_items_df)

    with step("Load fact_order_summary"):
        load_fact_order_summary(fact_summary_df, engine)

    with step("Build fact_monthly_product_performance"):
        fact_monthly_df = build_fact_monthly_product_performance(
            fact_items_df, product_sk_map
        )

    with step("Load fact_monthly_product_performance"):
        load_fact_monthly_performance(fact_monthly_df, engine)

    # ── 8. Final summary ──────────────────────────────────────────────────────
    elapsed_total = round(time.time() - pipeline_start, 1)
    log.info("=" * 60)
    log.info(f"ETL PIPELINE COMPLETE in {elapsed_total}s")
    log.info(f"  Source rows     : {len(raw_df):,}")
    log.info(f"  Clean rows      : {len(clean_df):,}")
    log.info(f"  Customers loaded: {len(customer_sk_map):,}")
    log.info(f"  Products loaded : {len(product_sk_map):,}")
    log.info(f"  Fact rows loaded: {len(fact_items_df):,}")
    log.info("=" * 60)

    return True


# =============================================================================
# CLI ENTRY POINT
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser(
        description="ITC E-Commerce Data Warehouse ETL Pipeline"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Extract and transform only. Do not write to database.",
    )
    parser.add_argument(
        "--skip-raw",
        action="store_true",
        help="Skip appending to raw layer (use on re-runs to avoid duplicates).",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args   = parse_args()
    success = run_pipeline(dry_run=args.dry_run, skip_raw=args.skip_raw)
    sys.exit(0 if success else 1)
