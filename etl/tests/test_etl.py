"""
FILE: tests/test_etl.py
PURPOSE: Unit tests for the ITC Data Warehouse ETL pipeline.
         Tests every cleaning rule, transformation, and business logic.
         Does NOT require a database connection — all tests run offline.

USAGE:
    cd project/etl
    pytest tests/test_etl.py -v                  # All tests
    pytest tests/test_etl.py -v -k "clean"       # Only cleaning tests
    pytest tests/test_etl.py --cov=. --cov-report=term-missing  # Coverage
"""

import sys
import pathlib
import pytest
import pandas as pd
import numpy as np
from datetime import date, datetime

# ── Path setup: allow importing etl modules from parent directory ─────────────
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))

import config

# Override paths so tests use a local test fixture, not the real CSV
TEST_DIR = pathlib.Path(__file__).parent
config.SOURCE_CSV    = TEST_DIR / "fixtures" / "test_data.csv"
config.PROCESSED_DIR = TEST_DIR / "tmp"
config.LOG_DIR       = TEST_DIR / "tmp"

from extract_clean import clean_data
from transform import (
    build_dim_customer,
    build_dim_product,
    build_fact_order_items,
    build_fact_order_summary,
    build_fact_monthly_product_performance,
)


# =============================================================================
# SHARED TEST FIXTURES
# =============================================================================

def make_clean_row(**overrides) -> dict:
    """
    Return a dictionary representing one valid, clean order row.
    Pass keyword arguments to override specific fields for edge-case tests.
    """
    defaults = {
        "order_item_id": "1001",
        "order_id":      "5001",
        "product_id":    "200",
        "customer_id":   "300",
        "quantity":      "2",
        "total_amount":  "1000.00",
        "name":          "Ahmed Hassan",
        "city":          "Cairo",
        "email":         "ahmed@example.com",
        "signup_date":   "2021-01-01",
        "order_date":    "2022-06-15",
        "product_name":  "Laptop",
        "category":      "Electronics",
        "price":         "600.00",
    }
    defaults.update(overrides)
    return defaults


def make_dataframe(*rows) -> pd.DataFrame:
    """Build a raw (all-string) DataFrame from one or more row dicts."""
    if not rows:
        rows = [make_clean_row()]
    return pd.DataFrame(rows)


# =============================================================================
# 1. CLEANING TESTS
# =============================================================================

class TestDataCleaning:

    def test_clean_single_valid_row(self):
        """A single valid row should survive cleaning unchanged."""
        df  = make_dataframe()
        out = clean_data(df)
        assert len(out) == 1

    def test_removes_exact_duplicates(self):
        """Exact duplicate rows should be reduced to one."""
        row = make_clean_row()
        df  = make_dataframe(row, row, row)
        out = clean_data(df)
        assert len(out) == 1

    def test_drops_null_order_item_id(self):
        """Row with null order_item_id must be dropped (critical key)."""
        df  = make_dataframe(make_clean_row(order_item_id=""))
        out = clean_data(df)
        assert len(out) == 0

    def test_drops_null_customer_id(self):
        """Row with null customer_id must be dropped."""
        df  = make_dataframe(make_clean_row(customer_id=""))
        out = clean_data(df)
        assert len(out) == 0

    def test_fills_null_city(self):
        """Null city should be replaced with 'Unknown', not dropped."""
        df  = make_dataframe(make_clean_row(city=""))
        out = clean_data(df)
        assert len(out) == 1
        assert out.iloc[0]["city"] == "Unknown"

    def test_city_title_case(self):
        """City names should be title-cased."""
        df  = make_dataframe(make_clean_row(city="cairo"))
        out = clean_data(df)
        assert out.iloc[0]["city"] == "Cairo"

    def test_city_normalisation_aliases(self):
        """Known city aliases (e.g. 'El Cairo') should map to 'Cairo'."""
        df  = make_dataframe(make_clean_row(city="El Cairo"))
        out = clean_data(df)
        assert out.iloc[0]["city"] == "Cairo"

    def test_category_title_case(self):
        """Categories should be title-cased (e.g. 'electronics' → 'Electronics')."""
        df  = make_dataframe(make_clean_row(category="electronics"))
        out = clean_data(df)
        assert out.iloc[0]["category"] == "Electronics"

    def test_category_alias_normalisation(self):
        """'Electronic' should be mapped to 'Electronics'."""
        df  = make_dataframe(make_clean_row(category="Electronic"))
        out = clean_data(df)
        assert out.iloc[0]["category"] == "Electronics"

    def test_email_lowercased(self):
        """Email addresses should be lowercased."""
        df  = make_dataframe(make_clean_row(email="Ahmed@Example.COM"))
        out = clean_data(df)
        assert out.iloc[0]["email"] == "ahmed@example.com"

    def test_invalid_email_flagged_not_dropped(self):
        """Invalid email should set dq_email_valid=0 but row is retained."""
        df  = make_dataframe(make_clean_row(email="not-an-email"))
        out = clean_data(df)
        assert len(out) == 1
        assert out.iloc[0]["dq_email_valid"] == 0

    def test_valid_email_flag(self):
        """Valid email should have dq_email_valid=1."""
        df  = make_dataframe(make_clean_row(email="test@domain.com"))
        out = clean_data(df)
        assert out.iloc[0]["dq_email_valid"] == 1

    def test_quantity_numeric_cast(self):
        """quantity column should be cast to int."""
        df  = make_dataframe(make_clean_row(quantity="3"))
        out = clean_data(df)
        assert out.iloc[0]["quantity"] == 3
        assert isinstance(out.iloc[0]["quantity"], (int, np.integer))

    def test_price_numeric_cast(self):
        """price column should be cast to float."""
        df  = make_dataframe(make_clean_row(price="599.99"))
        out = clean_data(df)
        assert abs(out.iloc[0]["price"] - 599.99) < 0.01

    def test_zero_quantity_replaced_with_one(self):
        """quantity <= 0 should be replaced with 1."""
        df  = make_dataframe(make_clean_row(quantity="0"))
        out = clean_data(df)
        assert out.iloc[0]["quantity"] == 1

    def test_negative_quantity_replaced_with_one(self):
        """Negative quantity should be replaced with 1."""
        df  = make_dataframe(make_clean_row(quantity="-5"))
        out = clean_data(df)
        assert out.iloc[0]["quantity"] == 1

    def test_order_date_parsed(self):
        """order_date should be parsed to a Python date."""
        df  = make_dataframe(make_clean_row(order_date="2023-03-15"))
        out = clean_data(df)
        val = out.iloc[0]["order_date"]
        assert str(val) == "2023-03-15"

    def test_invalid_order_date_flagged(self):
        """Unparseable date should set dq_date_valid=0."""
        df  = make_dataframe(make_clean_row(order_date="not-a-date"))
        out = clean_data(df)
        assert out.iloc[0]["dq_date_valid"] == 0

    def test_order_before_signup_flagged(self):
        """order_date < signup_date should set dq_order_before_signup=1."""
        df  = make_dataframe(make_clean_row(
            order_date="2021-01-01",
            signup_date="2022-06-01"    # Signup AFTER order
        ))
        out = clean_data(df)
        assert out.iloc[0]["dq_order_before_signup"] == 1

    def test_null_representations_replaced(self):
        """'NULL', 'N/A', 'nan' strings should become NaN then be handled."""
        df  = make_dataframe(make_clean_row(city="NULL"))
        out = clean_data(df)
        assert out.iloc[0]["city"] == "Unknown"


# =============================================================================
# 2. DERIVED COLUMN TESTS
# =============================================================================

class TestDerivedColumns:

    def test_gross_revenue_calculation(self):
        """gross_revenue should equal quantity × price."""
        df  = make_dataframe(make_clean_row(quantity="4", price="250.00"))
        out = clean_data(df)
        assert abs(out.iloc[0]["gross_revenue"] - 1000.00) < 0.01

    def test_discount_amount_positive(self):
        """discount_amount = gross_revenue - net_revenue, floored at 0."""
        # qty=2, price=600 → gross=1200; total_amount=1000 → discount=200
        df  = make_dataframe(make_clean_row(quantity="2", price="600.00",
                                            total_amount="1000.00"))
        out = clean_data(df)
        assert abs(out.iloc[0]["discount_amount"] - 200.00) < 0.01

    def test_discount_amount_never_negative(self):
        """discount_amount must be ≥ 0 even if total_amount > gross_revenue."""
        # Impossible but check the floor
        df  = make_dataframe(make_clean_row(quantity="1", price="100.00",
                                            total_amount="200.00"))
        out = clean_data(df)
        assert out.iloc[0]["discount_amount"] >= 0

    def test_customer_tenure_days(self):
        """customer_tenure_days = days between signup and order."""
        df  = make_dataframe(make_clean_row(
            signup_date="2022-01-01",
            order_date="2022-07-01"   # 181 days later
        ))
        out = clean_data(df)
        assert out.iloc[0]["customer_tenure_days"] == 181

    def test_price_band_budget(self):
        """Price < 500 should map to 'Budget'."""
        df  = make_dataframe(make_clean_row(price="199.00"))
        out = clean_data(df)
        assert out.iloc[0]["price_band"] == "Budget"

    def test_price_band_midrange(self):
        """500 ≤ price < 2000 should map to 'Mid-Range'."""
        df  = make_dataframe(make_clean_row(price="999.00"))
        out = clean_data(df)
        assert out.iloc[0]["price_band"] == "Mid-Range"

    def test_price_band_premium(self):
        """2000 ≤ price < 4000 should map to 'Premium'."""
        df  = make_dataframe(make_clean_row(price="3000.00"))
        out = clean_data(df)
        assert out.iloc[0]["price_band"] == "Premium"

    def test_price_band_luxury(self):
        """price ≥ 4000 should map to 'Luxury'."""
        df  = make_dataframe(make_clean_row(price="4500.00"))
        out = clean_data(df)
        assert out.iloc[0]["price_band"] == "Luxury"

    def test_etl_load_id_populated(self):
        """All rows in a batch should have the same etl_load_id."""
        rows = [make_clean_row(order_item_id=str(i)) for i in range(5)]
        df   = make_dataframe(*rows)
        out  = clean_data(df)
        assert out["etl_load_id"].nunique() == 1     # One batch = one ID

    def test_order_year_derived(self):
        df  = make_dataframe(make_clean_row(order_date="2024-09-15"))
        out = clean_data(df)
        assert out.iloc[0]["order_year"] == 2024

    def test_order_month_derived(self):
        df  = make_dataframe(make_clean_row(order_date="2024-09-15"))
        out = clean_data(df)
        assert out.iloc[0]["order_month"] == 9


# =============================================================================
# 3. DIMENSION TRANSFORM TESTS
# =============================================================================

class TestDimensionTransforms:

    def _multi_customer_df(self):
        """Helper: DataFrame with 3 distinct customers, 2 orders each."""
        rows = []
        for cust_id in [1, 2, 3]:
            for order_num in [1, 2]:
                rows.append(make_clean_row(
                    customer_id=str(cust_id),
                    order_item_id=str(cust_id * 10 + order_num),
                    order_id=str(cust_id * 100 + order_num),
                    email=f"cust{cust_id}@example.com",
                    name=f"Customer {cust_id}",
                    city="Cairo",
                    price="500.00",
                    total_amount="900.00",
                    quantity="2",
                    order_date=f"202{order_num}-06-01",
                    signup_date="2020-01-01",
                ))
        return clean_data(make_dataframe(*rows))

    def test_dim_customer_one_row_per_customer(self):
        """dim_customer must have exactly one row per unique customer_id."""
        df  = self._multi_customer_df()
        dim = build_dim_customer(df)
        assert len(dim) == 3
        assert dim["customer_id"].nunique() == 3

    def test_dim_customer_has_segment(self):
        """Every dim_customer row must have a non-null customer_segment."""
        df  = self._multi_customer_df()
        dim = build_dim_customer(df)
        assert dim["customer_segment"].notna().all()
        assert set(dim["customer_segment"]).issubset(
            {"High Value", "Regular", "New", "Developing"}
        )

    def test_dim_customer_high_value_segment(self):
        """Customer with LTV ≥ 20000 should be 'High Value'."""
        # 10 orders × qty=1 × price=2500 = 25000 LTV
        rows = []
        for i in range(10):
            rows.append(make_clean_row(
                customer_id="999",
                order_item_id=str(i),
                order_id=str(i + 100),
                price="2500.00",
                total_amount="2500.00",
                quantity="1",
                order_date=f"2022-0{(i%9)+1}-01",
                signup_date="2020-01-01",
            ))
        df  = clean_data(make_dataframe(*rows))
        dim = build_dim_customer(df)
        cust = dim[dim["customer_id"] == 999]
        assert len(cust) == 1
        assert cust.iloc[0]["customer_segment"] == "High Value"

    def test_dim_product_one_row_per_product(self):
        """dim_product must have exactly one row per unique product_id."""
        rows = [
            make_clean_row(product_id="10", product_name="Laptop",   price="3000.00"),
            make_clean_row(product_id="10", product_name="Laptop",   price="3000.00",
                           order_item_id="2"),   # Duplicate product
            make_clean_row(product_id="20", product_name="T-Shirt",  price="300.00",
                           order_item_id="3"),
        ]
        df  = clean_data(make_dataframe(*rows))
        dim = build_dim_product(df)
        assert len(dim) == 2
        assert dim["product_id"].nunique() == 2

    def test_dim_product_latest_price_wins(self):
        """When same product appears with different prices, latest order wins."""
        rows = [
            make_clean_row(product_id="10", price="900.00",  order_date="2022-01-01",
                           order_item_id="1"),
            make_clean_row(product_id="10", price="1200.00", order_date="2023-06-01",
                           order_item_id="2"),   # Later order, higher price
        ]
        df  = clean_data(make_dataframe(*rows))
        dim = build_dim_product(df)
        prod = dim[dim["product_id"] == 10]
        assert abs(prod.iloc[0]["unit_price"] - 1200.00) < 0.01


# =============================================================================
# 4. FACT TRANSFORM TESTS
# =============================================================================

class TestFactTransforms:

    def _make_clean_df_with_maps(self):
        """Build a clean df + minimal SK maps for fact transform tests."""
        rows = [
            make_clean_row(customer_id="1", product_id="10",
                           order_item_id="1", order_id="100",
                           quantity="3", price="200.00", total_amount="540.00"),
            make_clean_row(customer_id="2", product_id="20",
                           order_item_id="2", order_id="101",
                           quantity="1", price="500.00", total_amount="450.00"),
        ]
        df  = clean_data(make_dataframe(*rows))
        csk = {1: 10, 2: 20}
        psk = {10: 100, 20: 200}
        return df, csk, psk

    def test_fact_order_items_row_count(self):
        """fact_order_items should have one row per source order line item."""
        df, csk, psk = self._make_clean_df_with_maps()
        fact = build_fact_order_items(df, csk, psk)
        assert len(fact) == 2

    def test_fact_surrogate_keys_mapped(self):
        """customer_sk and product_sk must be filled from the maps."""
        df, csk, psk = self._make_clean_df_with_maps()
        fact = build_fact_order_items(df, csk, psk)
        assert set(fact["customer_sk"]).issubset({10, 20})
        assert set(fact["product_sk"]).issubset({100, 200})

    def test_fact_date_key_format(self):
        """order_date_key must be an 8-digit YYYYMMDD integer."""
        df, csk, psk = self._make_clean_df_with_maps()
        fact = build_fact_order_items(df, csk, psk)
        for dk in fact["order_date_key"]:
            assert 20000101 <= dk <= 20991231, f"Invalid date_key: {dk}"

    def test_fact_gross_revenue(self):
        """gross_revenue = quantity × unit_price."""
        df, csk, psk = self._make_clean_df_with_maps()
        fact = build_fact_order_items(df, csk, psk)
        row = fact[fact["customer_sk"] == 10].iloc[0]
        # qty=3, price=200 → gross=600
        assert abs(row["gross_revenue"] - 600.00) < 0.01

    def test_fact_net_revenue_from_total_amount(self):
        """net_revenue must equal the source total_amount."""
        df, csk, psk = self._make_clean_df_with_maps()
        fact = build_fact_order_items(df, csk, psk)
        row = fact[fact["customer_sk"] == 10].iloc[0]
        assert abs(row["net_revenue"] - 540.00) < 0.01

    def test_fact_discount_amount(self):
        """discount_amount = gross_revenue - net_revenue (≥ 0)."""
        df, csk, psk = self._make_clean_df_with_maps()
        fact = build_fact_order_items(df, csk, psk)
        row = fact[fact["customer_sk"] == 10].iloc[0]
        # gross=600, net=540 → discount=60
        assert abs(row["discount_amount"] - 60.00) < 0.01

    def test_fact_drops_unmapped_customers(self):
        """Rows whose customer_id has no SK mapping must be excluded."""
        df, _, psk = self._make_clean_df_with_maps()
        incomplete_csk = {1: 10}   # customer_id=2 has NO mapping
        fact = build_fact_order_items(df, incomplete_csk, psk)
        assert len(fact) == 1
        assert 20 not in fact["customer_sk"].values

    def test_fact_order_summary_grain(self):
        """fact_order_summary must have one row per unique order_id."""
        rows = [
            make_clean_row(order_id="100", order_item_id="1", customer_id="1",
                           product_id="10", quantity="1", price="500.00",
                           total_amount="450.00"),
            make_clean_row(order_id="100", order_item_id="2", customer_id="1",
                           product_id="20", quantity="2", price="300.00",
                           total_amount="540.00"),   # Same order, 2nd item
            make_clean_row(order_id="101", order_item_id="3", customer_id="2",
                           product_id="10", quantity="1", price="500.00",
                           total_amount="480.00"),
        ]
        df  = clean_data(make_dataframe(*rows))
        csk = {1: 10, 2: 20}
        psk = {10: 100, 20: 200}
        fact_items   = build_fact_order_items(df, csk, psk)
        fact_summary = build_fact_order_summary(fact_items)

        assert len(fact_summary) == 2   # 2 unique orders

        # Order 100 should have 2 items aggregated
        order_100 = fact_summary[fact_summary["order_id"] == 100]
        assert order_100.iloc[0]["total_items"] == 2
        assert order_100.iloc[0]["distinct_products"] == 2

    def test_fact_monthly_performance_grain(self):
        """fact_monthly_product_performance must have one row per product+month."""
        rows = []
        for i in range(5):
            rows.append(make_clean_row(
                order_id=str(i),
                order_item_id=str(i),
                product_id="10",
                customer_id=str(i + 1),
                order_date="2023-03-15",   # All same month
                price="500.00",
                total_amount="450.00",
                quantity="1",
                signup_date="2020-01-01",
            ))
        df  = clean_data(make_dataframe(*rows))
        csk = {i + 1: i + 10 for i in range(5)}
        psk = {10: 100}
        fact_items   = build_fact_order_items(df, csk, psk)
        fact_monthly = build_fact_monthly_product_performance(fact_items, psk)

        # 1 product × 1 month = 1 row
        assert len(fact_monthly) == 1
        assert fact_monthly.iloc[0]["total_orders"] == 5
        assert fact_monthly.iloc[0]["total_units_sold"] == 5


# =============================================================================
# 5. EDGE CASE TESTS
# =============================================================================

class TestEdgeCases:

    def test_empty_dataframe(self):
        """Cleaning an empty DataFrame should return empty without error."""
        df = pd.DataFrame(columns=make_clean_row().keys())
        # Should not raise
        try:
            out = clean_data(df)
            assert len(out) == 0
        except Exception as e:
            pytest.fail(f"clean_data raised on empty DataFrame: {e}")

    def test_single_character_name(self):
        """Very short customer names should not raise errors."""
        df  = make_dataframe(make_clean_row(name="X"))
        out = clean_data(df)
        assert len(out) == 1

    def test_unicode_name(self):
        """Arabic customer names should be handled correctly."""
        df  = make_dataframe(make_clean_row(name="محمد علي"))
        out = clean_data(df)
        assert len(out) == 1
        assert out.iloc[0]["name"] == "محمد علي"

    def test_very_large_order_amount(self):
        """Large monetary values should not overflow DECIMAL(18,2)."""
        df  = make_dataframe(make_clean_row(
            price="9999999.99",
            total_amount="9999999.99",
            quantity="1",
        ))
        out = clean_data(df)
        assert len(out) == 1
        assert out.iloc[0]["price"] < 10_000_000

    def test_all_null_representations(self):
        """All variants of null strings must be handled."""
        for null_val in ["", "null", "NULL", "N/A", "nan", "NaN", "None"]:
            df  = make_dataframe(make_clean_row(city=null_val))
            out = clean_data(df)
            assert out.iloc[0]["city"] == "Unknown", \
                f"Null string '{null_val}' was not replaced with 'Unknown'"
