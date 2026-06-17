# =============================================================================
# FILE: transform.py
# PURPOSE: Step 2 of the ETL pipeline — Transform clean data into the
#          Star Schema structure (dimension DataFrames + fact DataFrames).
#          These DataFrames are then loaded into Azure SQL by load.py.
# =============================================================================

import pandas as pd
import numpy as np
from datetime import datetime, date

from config import CITY_TO_GEOGRAPHY, DEFAULT_CHANNEL_SK
from logger import get_logger

log = get_logger(__name__)


# =============================================================================
# DIMENSION TRANSFORMS
# =============================================================================

def build_dim_customer(df: pd.DataFrame) -> pd.DataFrame:
    """
    Build dim_customer DataFrame from clean order data.
    One row per unique customer_id.
    Computes aggregated fields: total_orders, total_lifetime_value, segment.

    Args:
        df: Cleaned DataFrame from extract_clean.clean_data().

    Returns:
        dim_customer DataFrame ready to upsert into dw.dim_customer.
    """
    log.info("Building dim_customer...")

    # Aggregate per customer
    customer_agg = df.groupby("customer_id").agg(
        total_orders        = ("order_id",    "nunique"),
        total_lifetime_value= ("net_revenue", "sum"),
    ).reset_index()

    # Take the latest attribute values (SCD Type 1 — latest wins)
    customer_attrs = (
        df.sort_values("order_date", ascending=False)
          .drop_duplicates(subset=["customer_id"])
        [["customer_id", "name", "city", "email", "signup_date"]]
    )

    dim_cust = customer_attrs.merge(customer_agg, on="customer_id", how="left")
    dim_cust.rename(columns={"name": "customer_name"}, inplace=True)

    # Derived date columns
    dim_cust["signup_date"]  = pd.to_datetime(dim_cust["signup_date"])
    dim_cust["signup_year"]  = dim_cust["signup_date"].dt.year
    dim_cust["signup_month"] = dim_cust["signup_date"].dt.month

    # Geography defaults
    dim_cust["country"] = "Egypt"
    dim_cust["region"]  = "MENA"

    # Customer segmentation based on LTV
    def segment_customer(row):
        ltv = row["total_lifetime_value"]
        orders = row["total_orders"]
        if ltv >= 20000 or orders >= 5:
            return "High Value"
        elif ltv >= 8000 or orders >= 3:
            return "Regular"
        elif orders == 1:
            return "New"
        else:
            return "Developing"

    dim_cust["customer_segment"] = dim_cust.apply(segment_customer, axis=1)

    # Audit
    dim_cust["is_active"]        = 1
    dim_cust["created_date"]     = datetime.utcnow()
    dim_cust["last_updated_date"]= datetime.utcnow()

    # Round monetary
    dim_cust["total_lifetime_value"] = dim_cust["total_lifetime_value"].round(2)

    log.info(f"dim_customer: {len(dim_cust):,} rows.")
    return dim_cust


def build_dim_product(df: pd.DataFrame) -> pd.DataFrame:
    """
    Build dim_product DataFrame.
    One row per unique product_id with latest price (SCD Type 1).

    Args:
        df: Cleaned DataFrame.

    Returns:
        dim_product DataFrame.
    """
    log.info("Building dim_product...")

    # Latest price per product (SCD Type 1)
    dim_prod = (
        df.sort_values("order_date", ascending=False)
          .drop_duplicates(subset=["product_id"])
        [["product_id", "product_name", "category", "price", "price_band"]]
    )
    dim_prod.rename(columns={"price": "unit_price"}, inplace=True)

    dim_prod["is_active"]         = 1
    dim_prod["created_date"]      = datetime.utcnow()
    dim_prod["last_updated_date"] = datetime.utcnow()

    log.info(f"dim_product: {len(dim_prod):,} rows.")
    return dim_prod


# =============================================================================
# FACT TRANSFORMS
# =============================================================================

def build_fact_order_items(
    df:         pd.DataFrame,
    customer_sk_map: dict,
    product_sk_map:  dict,
) -> pd.DataFrame:
    """
    Build the grain-level fact table: one row per order line item.
    Looks up surrogate keys for customer and product from the maps
    returned after loading the dimension tables.

    Args:
        df:               Cleaned DataFrame.
        customer_sk_map:  {customer_id: customer_sk}
        product_sk_map:   {product_id: product_sk}

    Returns:
        fact_order_items DataFrame.
    """
    log.info("Building fact_order_items...")

    fact = df[[
        "order_item_id", "order_id",
        "customer_id",   "product_id",
        "quantity",      "price",
        "gross_revenue", "net_revenue",
        "discount_amount", "discount_pct",
        "order_date",    "city",
        "customer_tenure_days",
        "etl_load_id",
    ]].copy()

    # ── Surrogate key lookups ─────────────────────────────────────────────────
    fact["customer_sk"] = fact["customer_id"].map(customer_sk_map)
    fact["product_sk"]  = fact["product_id"].map(product_sk_map)

    # Log any unmapped keys (data quality issue)
    unmapped_customers = fact["customer_sk"].isnull().sum()
    unmapped_products  = fact["product_sk"].isnull().sum()
    if unmapped_customers > 0:
        log.warning(f"{unmapped_customers} rows have unmapped customer_sk!")
    if unmapped_products > 0:
        log.warning(f"{unmapped_products} rows have unmapped product_sk!")

    # Drop rows with no valid surrogate key (cannot load to fact without FK)
    fact.dropna(subset=["customer_sk", "product_sk"], inplace=True)

    # ── Geography surrogate key ───────────────────────────────────────────────
    fact["geography_sk"] = fact["city"].map(CITY_TO_GEOGRAPHY).fillna(5).astype(int)
    # Note: 5 maps to a catch-all 'Unknown' geography if city not recognised

    # ── Channel surrogate key ─────────────────────────────────────────────────
    # Default to 'Online Store' until source system provides channel data
    fact["channel_sk"] = DEFAULT_CHANNEL_SK

    # ── Date key: YYYYMMDD integer ────────────────────────────────────────────
    fact["order_date_key"] = (
        pd.to_datetime(fact["order_date"])
        .dt.strftime("%Y%m%d")
        .astype(int)
    )

    # ── Type cleanup ──────────────────────────────────────────────────────────
    fact["customer_sk"]   = fact["customer_sk"].astype(int)
    fact["product_sk"]    = fact["product_sk"].astype(int)
    fact["order_item_id"] = fact["order_item_id"].astype(int)
    fact["order_id"]      = fact["order_id"].astype(int)
    fact["quantity"]      = fact["quantity"].astype(int)
    fact["unit_price"]    = fact["price"].astype(float).round(2)

    # ── Select final columns matching dw.fact_order_items DDL ─────────────────
    fact = fact[[
        "order_date_key", "customer_sk", "product_sk",
        "geography_sk",   "channel_sk",
        "order_id",       "order_item_id",
        "quantity",       "unit_price",
        "gross_revenue",  "net_revenue",
        "discount_amount","discount_pct",
        "customer_tenure_days",
        "etl_load_id",
    ]]

    log.info(f"fact_order_items: {len(fact):,} rows.")
    return fact


def build_fact_order_summary(fact_items: pd.DataFrame) -> pd.DataFrame:
    """
    Aggregate fact_order_items to order-level grain.
    Derives dw.fact_order_summary.

    Args:
        fact_items: The already-built fact_order_items DataFrame.

    Returns:
        fact_order_summary DataFrame.
    """
    log.info("Building fact_order_summary...")

    summary = (
        fact_items
        .groupby(["order_id", "order_date_key", "customer_sk", "geography_sk"])
        .agg(
            total_items           = ("order_item_id",  "count"),
            total_quantity        = ("quantity",        "sum"),
            order_gross_revenue   = ("gross_revenue",   "sum"),
            order_net_revenue     = ("net_revenue",     "sum"),
            order_discount_amount = ("discount_amount", "sum"),
            distinct_products     = ("product_sk",      "nunique"),
        )
        .reset_index()
    )

    summary["order_gross_revenue"]   = summary["order_gross_revenue"].round(2)
    summary["order_net_revenue"]     = summary["order_net_revenue"].round(2)
    summary["order_discount_amount"] = summary["order_discount_amount"].round(2)

    log.info(f"fact_order_summary: {len(summary):,} rows.")
    return summary


def build_fact_monthly_product_performance(
    fact_items:    pd.DataFrame,
    product_sk_map: dict,
) -> pd.DataFrame:
    """
    Pre-aggregate to product × month grain.
    Includes month-over-month delta calculation.

    Args:
        fact_items:    The already-built fact_order_items DataFrame.
        product_sk_map: {product_id: product_sk}

    Returns:
        fact_monthly_product_performance DataFrame.
    """
    log.info("Building fact_monthly_product_performance...")

    # Join back to get year_month string
    fact_items = fact_items.copy()
    fact_items["year_month"] = (
        pd.to_datetime(fact_items["order_date_key"].astype(str), format="%Y%m%d")
        .dt.strftime("%Y-%m")
    )

    monthly = (
        fact_items
        .groupby(["year_month", "product_sk"])
        .agg(
            total_units_sold    = ("quantity",       "sum"),
            total_orders        = ("order_id",       "nunique"),
            total_gross_revenue = ("gross_revenue",  "sum"),
            total_net_revenue   = ("net_revenue",    "sum"),
            avg_unit_price      = ("unit_price",     "mean"),
            avg_order_value     = ("net_revenue",    "mean"),
            total_customers     = ("customer_sk",    "nunique"),
        )
        .reset_index()
    )

    # Month-over-month revenue change per product
    monthly.sort_values(["product_sk", "year_month"], inplace=True)
    monthly["revenue_mom_change_pct"] = (
        monthly.groupby("product_sk")["total_net_revenue"]
               .pct_change()
               .round(4)
    )
    monthly["units_mom_change_pct"] = (
        monthly.groupby("product_sk")["total_units_sold"]
               .pct_change()
               .round(4)
    )

    # Round
    for col in ["total_gross_revenue", "total_net_revenue",
                "avg_unit_price", "avg_order_value"]:
        monthly[col] = monthly[col].round(2)

    monthly.rename(columns={"year_month": "year_month_key"}, inplace=True)

    log.info(f"fact_monthly_product_performance: {len(monthly):,} rows.")
    return monthly
