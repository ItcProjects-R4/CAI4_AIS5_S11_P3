# Power BI Integration Guide
## ITC E-Commerce Data Warehouse

---

## RECOMMENDED DASHBOARD STRUCTURE

Build **5 separate report pages** in Power BI Desktop:

---

## PAGE 1: EXECUTIVE OVERVIEW

**Purpose**: C-level summary of business performance at a glance.

### KPI Cards (top row — 6 cards)
Create these using the **Card** visual:

| KPI | Measure DAX | Format |
|-----|-------------|--------|
| Total Revenue | `SUM(fact_order_items[net_revenue])` | Currency, EGP |
| Total Orders | `DISTINCTCOUNT(fact_order_items[order_id])` | Number |
| Unique Customers | `DISTINCTCOUNT(fact_order_items[customer_sk])` | Number |
| Avg Order Value | `DIVIDE([Total Revenue], [Total Orders])` | Currency |
| Total Units Sold | `SUM(fact_order_items[quantity])` | Number |
| Discount Rate % | `DIVIDE(SUM([discount_amount]), SUM([gross_revenue]))` | Percentage |

### Visualizations

**1. Revenue Trend (Line Chart)**
- X-axis: `dim_date[year_month]`
- Y-axis: `SUM(fact_order_items[net_revenue])`
- Secondary Y-axis: `DISTINCTCOUNT(fact_order_items[order_id])`
- Title: "Monthly Revenue vs Orders"

**2. Revenue by Category (Donut Chart)**
- Legend: `dim_product[category]`
- Values: `SUM(fact_order_items[net_revenue])`
- Title: "Revenue Share by Category"

**3. Revenue by City (Map Visual or Bar Chart)**
- Location: `dim_geography[city_name]`
- Size/Values: `SUM(fact_order_items[net_revenue])`
- Title: "Sales by City"

**4. Year-over-Year Comparison (Clustered Bar Chart)**
- X-axis: `dim_date[month_name]`
- Y-axis: `SUM(fact_order_items[net_revenue])`
- Legend: `dim_date[year_number]`
- Title: "YoY Revenue Comparison"

### Slicers (Filters)
- **Date slicer**: `dim_date[year_month]` → "Between" style
- **Category slicer**: `dim_product[category]` → Dropdown
- **City slicer**: `dim_geography[city_name]` → List

---

## PAGE 2: PRODUCT PERFORMANCE

**Purpose**: Identify best-sellers, slow movers, and category trends.

### KPI Cards
| KPI | Measure |
|-----|---------|
| Top Product Revenue | Use Top N filter on product bar chart |
| Best Category | Category with MAX revenue |
| Avg Unit Price | `AVERAGE(dim_product[unit_price])` |

### Visualizations

**1. Top 20 Products by Revenue (Horizontal Bar Chart)**
- Y-axis: `dim_product[product_name]`
- X-axis: `SUM(fact_order_items[net_revenue])`
- Data colors: Conditional formatting by `dim_product[category]`
- Add: Top N filter → Top 20 by Revenue

**2. Category Revenue Over Time (Area Chart)**
- X-axis: `dim_date[year_month]`
- Y-axis: `SUM(fact_order_items[net_revenue])`
- Legend: `dim_product[category]`
- Title: "Category Revenue Trends"

**3. Price Band Distribution (Stacked Bar)**
- X-axis: `dim_product[price_band]`
- Y-axis: Count of orders + Revenue
- Title: "Sales by Price Tier"

**4. Product Performance Matrix (Matrix/Table)**
Columns: Product Name | Category | Units Sold | Revenue | Avg Order Value | Orders
Sort by: Revenue descending
Add conditional formatting on Revenue column (data bars)

**5. ABC Analysis Visual (Pareto Chart)**
- Bar: Revenue per product (sorted desc)
- Line: Cumulative revenue %
- Reference lines at 70% (A) and 90% (B)

---

## PAGE 3: CUSTOMER INTELLIGENCE

**Purpose**: Understand customer segments, loyalty, and lifetime value.

### KPI Cards
| KPI | Measure |
|-----|---------|
| Avg Customer LTV | `AVERAGE([Lifetime Value per Customer])` |
| Repeat Purchase Rate | `DIVIDE([Repeat Buyers], [Total Customers])` |
| New Customers (Month) | With date context filter |
| At-Risk Customers | Customers not ordered in 90+ days |

### DAX Measures for this page
```
// Lifetime Value per Customer
Customer LTV = 
    CALCULATE(
        SUM(fact_order_items[net_revenue]),
        ALLEXCEPT(fact_order_items, fact_order_items[customer_sk])
    )

// Repeat Buyers
Repeat Buyers = 
    CALCULATE(
        DISTINCTCOUNT(fact_order_items[customer_sk]),
        FILTER(
            VALUES(fact_order_items[customer_sk]),
            CALCULATE(DISTINCTCOUNT(fact_order_items[order_id])) >= 2
        )
    )

// Days Since Last Order  
Days Since Last Purchase = 
    DATEDIFF(
        MAX(dim_date[full_date]),
        TODAY(),
        DAY
    )
```

### Visualizations

**1. Customer Segment Breakdown (Donut + Bar combo)**
- Based on `dim_customer[customer_segment]`
- Shows: High Value | Regular | New | Developing counts

**2. RFM Scatter Plot**
- X-axis: Recency (days since last order)
- Y-axis: Frequency (order count)
- Bubble size: Monetary value (LTV)
- Color: Customer segment
- Title: "RFM Customer Map"

**3. Customer Acquisition Over Time (Line Chart)**
- X-axis: `dim_customer[signup_year]` + `signup_month`
- Y-axis: Count of new customers
- Title: "Customer Acquisition Trend"

**4. Top 20 Customers Table**
Columns: Name | City | Total Orders | Lifetime Value | Last Order | Segment
Conditional format LTV column with data bars

**5. City × Segment Heatmap (Matrix)**
- Rows: `dim_geography[city_name]`
- Columns: `dim_customer[customer_segment]`
- Values: `DISTINCTCOUNT(customer_sk)`
- Conditional formatting: Background color scale

---

## PAGE 4: GEOGRAPHIC ANALYSIS

**Purpose**: Sales distribution across Egyptian cities.

### Visualizations

**1. Filled Map (if latitude/longitude available)**
- Location: `dim_geography[city_name]`
- Color saturation: `SUM(net_revenue)`
- Tooltips: Orders, Customers, Revenue
- Title: "Revenue Heatmap by City"

**2. City Revenue Comparison (Clustered Column)**
- X-axis: City
- Y-axis: Revenue
- Legend: Year
- Title: "City Revenue by Year"

**3. Category Split by City (100% Stacked Bar)**
- X-axis: City
- Y-axis: % of revenue
- Legend: Category
- Title: "Category Mix per City"

**4. City Metrics Table**
Columns: City | Revenue | Orders | Customers | Avg Order Value | Market Share %

---

## PAGE 5: TIME INTELLIGENCE

**Purpose**: Seasonality, growth trends, and period comparisons.

### DAX Time Intelligence Measures
```
// Year-over-Year Growth
Revenue YoY % = 
    VAR current_year = SUM(fact_order_items[net_revenue])
    VAR prior_year   = CALCULATE(
        SUM(fact_order_items[net_revenue]),
        DATEADD(dim_date[full_date], -1, YEAR)
    )
    RETURN DIVIDE(current_year - prior_year, prior_year)

// Year-to-Date Revenue
Revenue YTD = 
    TOTALYTD(SUM(fact_order_items[net_revenue]), dim_date[full_date])

// Rolling 3-Month Average
Revenue 3M Rolling Avg = 
    CALCULATE(
        AVERAGEX(
            DATESINPERIOD(dim_date[full_date], LASTDATE(dim_date[full_date]), -3, MONTH),
            [Total Revenue]
        )
    )
```

### Visualizations

**1. Monthly Revenue with YoY Line**
- Bars: Current year revenue
- Line: Prior year revenue
- Title: "Monthly Revenue with Prior Year"

**2. Seasonality Heatmap (Matrix)**
- Rows: Year
- Columns: Month name (Jan–Dec)
- Values: Revenue
- Conditional formatting: Color scale

**3. Weekday vs Weekend Sales (Bar)**
- X-axis: `dim_date[is_weekend]` (label as Weekday/Weekend)
- Y-axis: Revenue and order count

**4. Quarter-over-Quarter Waterfall Chart**
- Shows revenue change between quarters
- Title: "Quarterly Revenue Waterfall"

---

## PUBLISHING TO POWER BI SERVICE

### Step 1 — Publish from Desktop
1. In Power BI Desktop: **File** → **Publish** → **Publish to Power BI**
2. Select workspace: **"My workspace"** (or a team workspace)
3. Click **Select**
4. Wait for "Success!" message with a link

### Step 2 — Schedule Automatic Refresh
1. Go to https://app.powerbi.com
2. Find your dataset in **Workspaces** → **My workspace**
3. Click the **⋮** menu next to dataset → **Settings**
4. Under **Scheduled refresh**:
   - Toggle: **On**
   - Frequency: **Daily**
   - Time: **06:00 AM** (runs after your 2 AM ADF pipeline)
5. Under **Data source credentials**:
   - Click **Edit credentials**
   - Enter your Azure SQL username and password
6. Click **Apply**

### Step 3 — Share the Dashboard
1. Open your published report
2. Click **Share** (top right)
3. Enter email addresses of stakeholders
4. Set permissions: View only OR Allow resharing

---

## POWER BI BEST PRACTICES FOR THIS PROJECT

1. **Use Import mode** for this dataset (2,000 rows — very fast)
2. **Connect to analytics views** (`analytics.vw_*`), not raw fact tables
3. **Create a Date table** in Power BI using `dim_date` from your warehouse
4. **Mark `dim_date` as Date Table** (Modeling tab → Mark as date table)
5. **Use bookmarks** for different time period views (MTD, QTD, YTD)
6. **Enable Row Level Security (RLS)** if multiple users see different cities
7. **Optimize visuals**: Remove unnecessary fields from tooltips to speed up rendering
