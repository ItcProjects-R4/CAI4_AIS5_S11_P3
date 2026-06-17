# =============================================================================
# FILE: extract_clean.py
# PURPOSE: Step 1 of the ETL pipeline — Extract from CSV and apply all
#          data-quality, cleaning, and type-casting transformations.
#          Output: a clean pandas DataFrame ready for the load step.
# =============================================================================

import re
import uuid
from datetime import datetime

import numpy as np
import pandas as pd

from config import SOURCE_CSV, PRICE_BANDS, PROCESSED_DIR
from logger import get_logger

log = get_logger(__name__)


# =============================================================================
# EXTRACTION
# =============================================================================

def extract_csv(filepath=SOURCE_CSV) -> pd.DataFrame:
    """
    Read the source CSV into a raw DataFrame.
    All columns kept as-is; no transformations here.

    Returns:
        Raw DataFrame.
    """
    log.info(f"Extracting CSV: {filepath}")
    df = pd.read_csv(filepath, dtype=str)   # Read everything as str for safety
    log.info(f"Extracted {len(df):,} rows, {len(df.columns)} columns.")
    log.debug(f"Columns: {list(df.columns)}")
    return df


# =============================================================================
# CLEANING
# =============================================================================

def clean_data(df: pd.DataFrame) -> pd.DataFrame:
    """
    Apply the full data-cleaning pipeline in order:
      1.  Column name standardisation
      2.  Duplicate removal
      3.  Null handling
      4.  Type casting
      5.  String standardisation
      6.  Date validation
      7.  Numeric range validation
      8.  Email validation flag
      9.  Derived column calculation
      10. Price band assignment

    Args:
        df: Raw DataFrame from extract_csv().

    Returns:
        Cleaned DataFrame ready for loading.
    """
    log.info("Starting data cleaning pipeline...")
    original_count = len(df)

    # ── Step 1: Standardise column names ────────────────────────────────────
    df.columns = (
        df.columns
        .str.strip()
        .str.lower()
        .str.replace(r'\s+', '_', regex=True)
        .str.replace(r'[^a-z0-9_]', '', regex=True)
    )
    log.debug(f"Standardised columns: {list(df.columns)}")

    # ── Step 2: Remove exact duplicate rows ─────────────────────────────────
    dupes = df.duplicated().sum()
    if dupes > 0:
        log.warning(f"Removing {dupes} duplicate rows.")
        df = df.drop_duplicates()

    # ── Step 3: Null / missing value handling ────────────────────────────────
    # Replace common null-like strings with actual NaN
    null_representations = ["", "null", "NULL", "None", "none", "N/A", "n/a",
                            "NA", "#N/A", "nan", "NaN"]
    df.replace(null_representations, np.nan, inplace=True)

    null_report = df.isnull().sum()
    if null_report.sum() > 0:
        log.warning(f"Null values found:\n{null_report[null_report > 0]}")

    # Drop rows where critical business keys are null
    critical_cols = ["order_item_id", "order_id", "product_id", "customer_id"]
    pre_drop = len(df)
    df.dropna(subset=critical_cols, inplace=True)
    dropped = pre_drop - len(df)
    if dropped > 0:
        log.warning(f"Dropped {dropped} rows with null critical keys.")

    # Fill non-critical nulls with sensible defaults (pandas 2.x compatible)
    df = df.copy()  # Ensure we own this DataFrame before modifications
    df["city"]         = df["city"].fillna("Unknown")
    df["category"]     = df["category"].fillna("Uncategorised")
    df["product_name"] = df["product_name"].fillna("Unknown Product")
    df["name"]         = df["name"].fillna("Unknown Customer")

    # ── Step 4: Cast numeric columns ─────────────────────────────────────────
    numeric_cols = {
        "order_item_id": "int64",
        "order_id":      "int64",
        "product_id":    "int64",
        "customer_id":   "int64",
        "quantity":      "int16",
    }
    float_cols = ["total_amount", "price"]

    for col, dtype in numeric_cols.items():
        df[col] = pd.to_numeric(df[col], errors="coerce").astype(dtype)

    for col in float_cols:
        df[col] = pd.to_numeric(df[col], errors="coerce").round(2)

    # ── Step 5: Standardise string / categorical columns ────────────────────
    # Title-case city and name; uppercase category for consistency
    df["city"]         = df["city"].str.strip().str.title()
    df["name"]         = df["name"].str.strip()
    df["category"]     = df["category"].str.strip().str.title()
    df["product_name"] = df["product_name"].str.strip()
    df["email"]        = df["email"].str.strip().str.lower()

    # Standardise known city name variations
    city_map = {
        "El Cairo":   "Cairo",
        "Al Cairo":   "Cairo",
        "Al-Qahira":  "Cairo",
        "Alex":       "Alexandria",
        "El Giza":    "Giza",
        "Al Giza":    "Giza",
    }
    df["city"] = df["city"].replace(city_map)

    # Enforce known category values; remap typos
    category_map = {
        "Electronic":  "Electronics",
        "Cloths":      "Clothing",
        "Cloth":       "Clothing",
        "Book":        "Books",
        "Food & Bev":  "Food",
    }
    df["category"] = df["category"].replace(category_map)

    log.info(f"Category distribution:\n{df['category'].value_counts().to_string()}")
    log.info(f"City distribution:\n{df['city'].value_counts().to_string()}")

    # ── Step 6: Date parsing and validation ──────────────────────────────────
    df["order_date"]  = pd.to_datetime(df["order_date"],  errors="coerce").dt.date
    df["signup_date"] = pd.to_datetime(df["signup_date"], errors="coerce").dt.date

    # Flag rows where dates could not be parsed
    df["dq_date_valid"] = (~(
        df["order_date"].isnull() | df["signup_date"].isnull()
    )).astype(int)

    bad_dates = df["dq_date_valid"].eq(0).sum()
    if bad_dates > 0:
        log.warning(f"{bad_dates} rows have invalid dates — flagged but retained.")

    # Fill unparseable dates with a sentinel value so they load without NULLs
    df["order_date"]  = df["order_date"].fillna(pd.Timestamp("1900-01-01").date())
    df["signup_date"] = df["signup_date"].fillna(pd.Timestamp("1900-01-01").date())

    # Flag rows where order_date is before signup_date (data anomaly)
    df["dq_order_before_signup"] = (
        df["order_date"] < df["signup_date"]
    ).astype(int)
    anomaly_count = df["dq_order_before_signup"].sum()
    if anomaly_count > 0:
        log.warning(f"{anomaly_count} rows have order_date < signup_date.")

    # ── Step 7: Numeric range validation ─────────────────────────────────────
    # Remove physically impossible values
    invalid_qty = df["quantity"].le(0) | df["quantity"].isna()
    if invalid_qty.sum() > 0:
        log.warning(f"Replacing {invalid_qty.sum()} invalid quantity values with 1.")
        df.loc[invalid_qty, "quantity"] = 1

    invalid_price = df["price"].le(0) | df["price"].isna()
    if invalid_price.sum() > 0:
        log.warning(f"Replacing {invalid_price.sum()} invalid price values with median.")
        median_price = df.loc[~invalid_price, "price"].median()
        df.loc[invalid_price, "price"] = median_price

    invalid_amount = df["total_amount"].le(0) | df["total_amount"].isna()
    if invalid_amount.sum() > 0:
        log.warning(f"Replacing {invalid_amount.sum()} invalid total_amount values.")
        df.loc[invalid_amount, "total_amount"] = (
            df.loc[invalid_amount, "quantity"] * df.loc[invalid_amount, "price"]
        )

    # ── Step 8: Email validation flag ────────────────────────────────────────
    email_pattern = re.compile(r"^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+$")
    df["dq_email_valid"] = df["email"].apply(
        lambda x: 1 if pd.notna(x) and email_pattern.match(str(x)) else 0
    )
    invalid_email_count = df["dq_email_valid"].eq(0).sum()
    if invalid_email_count > 0:
        log.warning(f"{invalid_email_count} rows have invalid email addresses.")

    # ── Step 9: Derived columns ───────────────────────────────────────────────
    # Gross revenue (before any discount)
    df["gross_revenue"] = (df["quantity"] * df["price"]).round(2)

    # Net revenue = total_amount as provided by source
    df["net_revenue"] = df["total_amount"].round(2)

    # Discount amount (can be 0 if no discount applied)
    df["discount_amount"] = (df["gross_revenue"] - df["net_revenue"]).clip(lower=0).round(2)

    # Discount percentage
    df["discount_pct"] = np.where(
        df["gross_revenue"] > 0,
        (df["discount_amount"] / df["gross_revenue"]).round(4),
        0,
    )

    # Customer tenure in days at order time
    df["customer_tenure_days"] = (
        pd.to_datetime(df["order_date"]) - pd.to_datetime(df["signup_date"])
    ).dt.days.clip(lower=0)

    # Year/month from order_date (for staging table computed columns if needed)
    df["order_year"]  = pd.to_datetime(df["order_date"]).dt.year
    df["order_month"] = pd.to_datetime(df["order_date"]).dt.month

    # ── Step 10: Price band assignment ───────────────────────────────────────
    def assign_price_band(price: float) -> str:
        for band, (low, high) in PRICE_BANDS.items():
            if low <= price < high:
                return band
        return "Unknown"

    df["price_band"] = df["price"].apply(assign_price_band)

    # ── Step 11: ETL metadata ─────────────────────────────────────────────────
    batch_id = str(uuid.uuid4())
    df["etl_load_id"]    = batch_id
    df["etl_load_date"]  = datetime.utcnow()
    df["etl_source_file"] = str(SOURCE_CSV.name)

    # ── Final summary ─────────────────────────────────────────────────────────
    final_count = len(df)
    log.info(
        f"Cleaning complete. "
        f"In: {original_count:,} rows → Out: {final_count:,} rows "
        f"({original_count - final_count} removed)."
    )

    return df


# =============================================================================
# SAVE PROCESSED DATA (for audit trail)
# =============================================================================

def save_processed(df: pd.DataFrame) -> None:
    """Save cleaned DataFrame to the processed folder as Parquet (efficient)."""
    PROCESSED_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    out_path = PROCESSED_DIR / f"cleaned_orders_{ts}.parquet"
    df.to_parquet(out_path, index=False)
    log.info(f"Saved cleaned data to: {out_path}")


# =============================================================================
# STANDALONE ENTRY POINT (for testing this step independently)
# =============================================================================

if __name__ == "__main__":
    raw_df     = extract_csv()
    clean_df   = clean_data(raw_df)
    save_processed(clean_df)
    print(clean_df.dtypes)
    print(clean_df.head(3).to_string())
