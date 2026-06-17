#!/usr/bin/env python3
# =============================================================================
# FILE: data_quality_report.py
# PURPOSE: Standalone DQ analysis script. Run before the ETL to understand
#          the quality of the source CSV. Produces a printable report.
#          Does NOT require a database connection.
# USAGE: python data_quality_report.py
# =============================================================================

import sys
import pathlib
import pandas as pd
import numpy as np

# Allow running from any working directory
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import config

def generate_report(csv_path=config.SOURCE_CSV):
    df = pd.read_csv(csv_path, dtype=str)

    SEP = "=" * 65

    print(f"\n{SEP}")
    print("  ITC E-COMMERCE DATA QUALITY REPORT")
    print(f"  Source: {csv_path.name}")
    print(SEP)

    # ── 1. Dataset Overview ───────────────────────────────────────────────────
    print(f"\n{'─'*65}")
    print("  1. DATASET OVERVIEW")
    print(f"{'─'*65}")
    print(f"  Total rows       : {len(df):,}")
    print(f"  Total columns    : {len(df.columns)}")
    print(f"  Columns          : {', '.join(df.columns)}")

    # ── 2. Null Analysis ──────────────────────────────────────────────────────
    print(f"\n{'─'*65}")
    print("  2. NULL / MISSING VALUES")
    print(f"{'─'*65}")
    null_counts = df.isnull().sum()
    null_pct    = (null_counts / len(df) * 100).round(2)
    null_df     = pd.DataFrame({"Null Count": null_counts, "Null %": null_pct})
    null_df     = null_df[null_df["Null Count"] > 0]
    if len(null_df) == 0:
        print("  ✓ No null values detected in any column.")
    else:
        print(null_df.to_string())

    # ── 3. Duplicate Analysis ─────────────────────────────────────────────────
    print(f"\n{'─'*65}")
    print("  3. DUPLICATE ANALYSIS")
    print(f"{'─'*65}")
    full_dupes = df.duplicated().sum()
    id_dupes   = df.duplicated(subset=["order_item_id"]).sum()
    print(f"  Full row duplicates    : {full_dupes:,}")
    print(f"  order_item_id dupes    : {id_dupes:,}")
    print(f"  Unique order_ids       : {df['order_id'].nunique():,}")
    print(f"  Unique customer_ids    : {df['customer_id'].nunique():,}")
    print(f"  Unique product_ids     : {df['product_id'].nunique():,}")

    # ── 4. Numeric Validation ─────────────────────────────────────────────────
    print(f"\n{'─'*65}")
    print("  4. NUMERIC COLUMN RANGES")
    print(f"{'─'*65}")
    num_cols = ["quantity", "total_amount", "price"]
    for col in num_cols:
        vals = pd.to_numeric(df[col], errors="coerce")
        neg  = (vals < 0).sum()
        zero = (vals == 0).sum()
        null = vals.isnull().sum()
        print(f"  {col:15s}  min={vals.min():.2f}  max={vals.max():.2f}  "
              f"mean={vals.mean():.2f}  negatives={neg}  zeros={zero}  nulls={null}")

    # ── 5. Date Validation ────────────────────────────────────────────────────
    print(f"\n{'─'*65}")
    print("  5. DATE VALIDATION")
    print(f"{'─'*65}")
    order_dates  = pd.to_datetime(df["order_date"],  errors="coerce")
    signup_dates = pd.to_datetime(df["signup_date"], errors="coerce")
    bad_order    = order_dates.isnull().sum()
    bad_signup   = signup_dates.isnull().sum()
    order_before = (order_dates < signup_dates).sum()
    print(f"  order_date  range  : {order_dates.min().date()} → {order_dates.max().date()}")
    print(f"  signup_date range  : {signup_dates.min().date()} → {signup_dates.max().date()}")
    print(f"  Unparseable order_date  : {bad_order}")
    print(f"  Unparseable signup_date : {bad_signup}")
    if order_before > 0:
        print(f"  ⚠ order_date < signup_date : {order_before:,} rows "
              f"({order_before/len(df)*100:.1f}%) — likely test/demo data")

    # ── 6. Categorical Analysis ───────────────────────────────────────────────
    print(f"\n{'─'*65}")
    print("  6. CATEGORICAL DISTRIBUTIONS")
    print(f"{'─'*65}")
    for col in ["category", "city"]:
        print(f"\n  {col.upper()}:")
        counts = df[col].value_counts()
        for val, cnt in counts.items():
            pct = cnt / len(df) * 100
            bar = "█" * int(pct / 2)
            print(f"    {val:15s}  {cnt:5,}  ({pct:5.1f}%)  {bar}")

    # ── 7. Email Validation ───────────────────────────────────────────────────
    import re
    pattern = re.compile(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$")
    invalid_emails = df["email"].apply(
        lambda x: not bool(pattern.match(str(x).strip())) if pd.notna(x) else True
    ).sum()
    print(f"\n{'─'*65}")
    print("  7. EMAIL VALIDATION")
    print(f"{'─'*65}")
    print(f"  Invalid email addresses : {invalid_emails:,}")
    print(f"  Valid email addresses   : {len(df) - invalid_emails:,}")

    # ── 8. DQ Summary Score ───────────────────────────────────────────────────
    total_issues = (
        full_dupes + id_dupes + bad_order + bad_signup + invalid_emails
        + (null_counts > 0).sum()
    )
    score = max(0, 100 - total_issues * 0.5)
    grade = "A" if score >= 90 else "B" if score >= 75 else "C" if score >= 60 else "D"

    print(f"\n{SEP}")
    print(f"  DATA QUALITY SCORE: {score:.1f}/100  Grade: {grade}")
    print(f"  Total issues found : {total_issues}")
    print(f"  Note: 891 rows with order < signup are expected for demo data.")
    print(f"        ETL flags these but does NOT drop them.")
    print(SEP)
    print()


if __name__ == "__main__":
    generate_report()
