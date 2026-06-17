# Beginner's Complete Walkthrough
## From Zero to Running Power BI Dashboard — Step by Step

This guide assumes you have **no prior Azure experience**. Every click is documented.

---

## PART A — WHAT YOU NEED BEFORE STARTING (30 minutes)

### A1. Create a Free Azure Account
1. Go to https://azure.microsoft.com/free
2. Click **"Start free"**
3. Sign in with a Microsoft account (or create one)
4. Enter a phone number for verification
5. Enter a credit card *(you will NOT be charged — free tier gives you $200 credit)*
6. Click **"Sign up"**
7. You are now in the Azure Portal at https://portal.azure.com

---

### A2. Install Required Software on Your Computer

Install these tools (click each link, download, run installer — all defaults are fine):

| Tool | Purpose | Download Link |
|------|---------|---------------|
| **Azure CLI** | Create Azure resources from terminal | https://aka.ms/installazurecliwindows (Windows) or `brew install azure-cli` (Mac) |
| **ODBC Driver 18** | Python → Azure SQL connection | https://aka.ms/downloadmsodbcsql |
| **Azure Data Studio** | Run SQL scripts visually | https://aka.ms/azuredatastudio |
| **Python 3.11+** | Run ETL pipeline | https://python.org/downloads |
| **Power BI Desktop** | Build dashboards | https://powerbi.microsoft.com/desktop |

**How to verify Python is installed correctly**:
Open a terminal (Command Prompt on Windows, Terminal on Mac) and type:
```
python --version
```
You should see: `Python 3.11.x` (or higher). If you see an error, restart your computer after installing Python.

---

### A3. Download This Project

Unzip `ITC_DataWarehouse_Complete_Solution.zip` to a folder you can remember,
for example: `C:\Users\YourName\Desktop\ITC_DataWarehouse\`

You should see these folders inside:
```
ITC_DataWarehouse/
  ├── sql/
  ├── etl/
  ├── docs/
  └── README.md
```

---

## PART B — CREATE AZURE RESOURCES (45 minutes, mostly waiting)

### B1. Open Azure Portal and Navigate
1. Go to https://portal.azure.com
2. You see the **Home** screen with icons for different Azure services
3. Everything you create will live here

---

### B2. Create a Resource Group (2 minutes)

Think of a Resource Group as a folder that holds all your project's Azure resources.

1. In the top search bar (says "Search resources, services, and docs..."), type: **resource groups**
2. Click **"Resource groups"** in the dropdown
3. Click the blue **"+ Create"** button (top left)
4. **Subscription**: Leave as-is (your subscription name)
5. **Resource group name**: Type exactly `rg-itc-datawarehouse`
6. **Region**: Select `(Europe) West Europe`
   > If you're in Egypt, `UAE North` or `West Europe` are closest
7. Click **"Review + create"** (bottom left)
8. Click **"Create"**
9. Wait 10 seconds → you see "Deployment succeeded" ✓

---

### B3. Create an Azure SQL Server (5 minutes)

The "server" is the container that holds your database.

1. Search bar → type **"SQL servers"** → click it
2. Click **"+ Create"**
3. Fill in these fields:
   - **Subscription**: Your subscription (leave as-is)
   - **Resource group**: Click dropdown → select `rg-itc-datawarehouse`
   - **Server name**: `sql-itc-dw-server-YOUR_INITIALS`
     *(e.g. `sql-itc-dw-server-am` — must be globally unique across all Azure)*
   - **Location**: `West Europe`
   - **Authentication method**: Click **"Use SQL authentication"**
   - **Server admin login**: `itc_admin`
   - **Password**: Create a strong password like `ITC@dmin#2025!`
     *(must have uppercase, lowercase, number, and symbol)*
   - **Confirm password**: Same password
4. Click **"Review + create"**
5. Click **"Create"**
6. A progress screen appears — wait 2–3 minutes
7. You see **"Your deployment is complete"** ✓

> **Write down your server name and password somewhere safe — you'll need them in every step below.**

---

### B4. Create the Database (5 minutes)

1. Search bar → type **"SQL databases"** → click it
2. Click **"+ Create"**
3. Fill in:
   - **Subscription**: Your subscription
   - **Resource group**: `rg-itc-datawarehouse`
   - **Database name**: `ITC_DataWarehouse`
   - **Server**: Click "Select a server" → choose the server you just created
   - **Want to use SQL elastic pool?**: **No**
   - **Workload environment**: **Development** (cheaper tier)
4. Click **"Configure database"** (under Compute + Storage):
   - Click **"Looking for basic, standard, premium?"** link
   - Select **"Standard"**
   - Move the slider to **S2 (50 DTUs)**
   - Click **"Apply"**
5. Back on the main form, click **"Review + create"**
6. Click **"Create"**
7. Wait 3–5 minutes → "Your deployment is complete" ✓

---

### B5. Allow Your Computer to Connect (Firewall) (2 minutes)

Azure SQL blocks all external connections by default. You must whitelist your IP.

1. Search bar → **"SQL servers"** → click your server name
2. In the left menu, click **"Networking"**
3. Under **"Firewall rules"**, click **"+ Add your client IPv4 address"**
   - Azure automatically detects your IP and adds it
4. Under **"Exceptions"**, toggle **"Allow Azure services and resources to access this server"** → **ON**
5. Click **"Save"** (top of page)
6. You see "Firewall settings saved" ✓

---

## PART C — SET UP THE DATABASE SCHEMA (30 minutes)

### C1. Connect Azure Data Studio to Your Database

1. Open **Azure Data Studio**
2. Click **"New Connection"** (or press Ctrl+N)
3. Fill in:
   - **Connection type**: Microsoft SQL Server
   - **Server**: `sql-itc-dw-server-YOUR_INITIALS.database.windows.net`
     *(replace with your server name — find it on the Azure SQL server page)*
   - **Authentication type**: SQL Login
   - **User name**: `itc_admin`
   - **Password**: Your password
   - **Database**: Click the dropdown → type `ITC_DataWarehouse`
   - **Trust server certificate**: ☑ Check this box (if shown)
4. Click **"Connect"**
5. You see a green dot and your server listed in the left panel ✓

---

### C2. Run SQL Scripts in Order

For each script below:
1. In Azure Data Studio: **File** → **Open File** → navigate to the sql/ folder
2. Click the green **▶ Run** button at the top of the file
3. Wait for the "Commands completed successfully" message
4. Then open the next script

**Run these files in this exact order:**

```
📁 sql/01_setup/
   ✅ 01_database_and_schemas.sql    ← Creates 4 schemas
   ✅ 02_raw_layer.sql               ← Creates raw table
   ✅ 03_staging_layer.sql           ← Creates staging table
   ✅ 10_security.sql                ← Creates users and roles

📁 sql/02_dimensions/
   ✅ 04_dimension_tables.sql        ← Creates 5 dimension tables
   ✅ 05_populate_dim_date.sql       ← Fills date dimension (4,018 rows)

📁 sql/03_facts/
   ✅ 06_fact_tables.sql             ← Creates 3 fact tables
   ✅ 09_stored_procedures.sql       ← Creates 7 ETL stored procedures

📁 sql/04_indexes/
   ✅ 07_indexes_and_constraints.sql ← Adds performance indexes

📁 sql/05_analytics/
   ✅ 08_analytics_queries.sql       ← Creates analytics views + queries
```

**If you see a red error message**, check:
- Are you connected to `ITC_DataWarehouse` (not `master`)? Check the database name in the connection bar
- Did you run the scripts in order? Script 06 needs script 04 to run first

---

## PART D — RUN THE ETL PIPELINE (20 minutes)

### D1. Open a Terminal

- **Windows**: Press `Win + R`, type `cmd`, press Enter
- **Mac**: Press `Cmd + Space`, type `terminal`, press Enter

---

### D2. Navigate to the ETL Folder

```cmd
cd C:\Users\YourName\Desktop\ITC_DataWarehouse\etl
```
*(Replace the path with wherever you unzipped the project)*

---

### D3. Create a Python Virtual Environment

```cmd
python -m venv venv
```

Then activate it:
- **Windows**: `venv\Scripts\activate`
- **Mac/Linux**: `source venv/bin/activate`

You should see `(venv)` appear at the start of your terminal prompt.

---

### D4. Install Dependencies

```cmd
pip install -r requirements.txt
```

This downloads pandas, SQLAlchemy, pyodbc and other libraries. Wait 1–2 minutes.

---

### D5. Set Your Database Credentials

**Windows** (type each line, press Enter):
```cmd
set AZURE_SQL_SERVER=sql-itc-dw-server-YOUR_INITIALS.database.windows.net
set AZURE_SQL_DATABASE=ITC_DataWarehouse
set AZURE_SQL_USERNAME=itc_admin
set AZURE_SQL_PASSWORD=ITC@dmin#2025!
```

**Mac/Linux**:
```bash
export AZURE_SQL_SERVER="sql-itc-dw-server-YOUR_INITIALS.database.windows.net"
export AZURE_SQL_DATABASE="ITC_DataWarehouse"
export AZURE_SQL_USERNAME="itc_admin"
export AZURE_SQL_PASSWORD="ITC@dmin#2025!"
```

---

### D6. Test the Connection

```cmd
python -c "from load import test_connection; test_connection()"
```

✅ Expected: `INFO | Azure SQL connection OK. Server time: 2025-xx-xx xx:xx:xx`

❌ If you see an error:
- `Login failed`: Check your username/password in step D5
- `Firewall`: Re-do step B5 with your current IP (it may have changed)
- `ODBC Driver not found`: Re-install ODBC Driver 18 from step A2

---

### D7. Run a Dry Run (no database writes)

```cmd
python main_etl.py --dry-run
```

This tests all cleaning and transformation logic without touching the database.
You should see a summary of the data with 2,000 rows.

---

### D8. Run the Full ETL

```cmd
python main_etl.py
```

Watch the output. Expected completion in ~30 seconds:

```
STEP DONE: Extract CSV in 0.3s
STEP DONE: Clean & Validate Data in 1.2s
STEP DONE: Load Raw Layer in 4.5s
...
ETL PIPELINE COMPLETE in 28s
  Source rows     : 2,000
  Clean rows      : 2,000
  Customers loaded: 1,283
  Products loaded : 100
  Fact rows loaded: 2,000
```

---

### D9. Verify Data Loaded

Go back to **Azure Data Studio** and run:
```sql
SELECT COUNT(*) AS customer_count FROM dw.dim_customer;   -- Should be 1,283
SELECT COUNT(*) AS product_count  FROM dw.dim_product;    -- Should be 100
SELECT COUNT(*) AS fact_rows      FROM dw.fact_order_items; -- Should be 2,000
SELECT SUM(net_revenue) AS total_revenue FROM dw.fact_order_items; -- ~10,079,584
```

If you see the expected numbers, your data warehouse is loaded! ✓

---

## PART E — CONNECT POWER BI (20 minutes)

### E1. Open Power BI Desktop

1. Open **Power BI Desktop**
2. If it asks you to sign in, sign in with your Microsoft account

---

### E2. Connect to Azure SQL

1. Click **"Get data"** (in the Home ribbon)
2. In the search box, type **"Azure SQL"**
3. Click **"Azure SQL database"** → **Connect**
4. Fill in:
   - **Server**: `sql-itc-dw-server-YOUR_INITIALS.database.windows.net`
   - **Database** (optional, but enter it): `ITC_DataWarehouse`
   - **Data Connectivity mode**: **Import**
5. Click **OK**
6. A credentials dialog appears:
   - Click **"Database"** tab (left side)
   - **User name**: `powerbi_reader`
   - **Password**: `PbI$R3adOnly2025!` *(from 10_security.sql)*
7. Click **Connect**

---

### E3. Select Tables

A **Navigator** window shows all tables. Check these boxes:

```
☑ analytics  →  vw_monthly_revenue
☑ analytics  →  vw_product_performance
☑ analytics  →  vw_city_performance
☑ analytics  →  vw_customer_360
☑ dw         →  dim_date
☑ dw         →  dim_customer
☑ dw         →  dim_product
☑ dw         →  dim_geography
☑ dw         →  fact_order_items
```

Click **"Load"** (bottom right). Wait ~30 seconds for data to import.

---

### E4. Create Your First Chart (Revenue Trend)

1. In the right panel, click the **Line chart** icon
2. A blank chart appears on the canvas
3. Drag **`dim_date[year_month]`** to the **X-axis** field
4. Drag **`fact_order_items[net_revenue]`** to the **Y-axis** field
   *(Power BI will auto-sum it)*
5. You now have a monthly revenue trend chart!

---

### E5. Create a KPI Card (Total Revenue)

1. Click empty space on canvas
2. Click the **Card** visual icon (rectangle with a number)
3. Drag **`fact_order_items[net_revenue]`** to the **Fields** box
4. In the Format panel, set:
   - **Display units**: Millions
   - **Value decimal places**: 2
5. You now have a "Total Revenue: EGP 10.08M" card

---

### E6. Save and Publish

1. Press `Ctrl+S` → save as `ITC_Dashboard.pbix` to your desktop
2. Click **"Publish"** in the Home ribbon
3. Sign in if prompted
4. Select **"My workspace"**
5. Click **"Select"**
6. Wait for "Success!" → click the link to open in browser

---

## PART F — COMMON ERRORS AND HOW TO FIX THEM

| What you see | What it means | How to fix it |
|--------------|---------------|---------------|
| `Login failed for user 'itc_admin'` | Wrong password | Azure Portal → SQL servers → your server → Reset password |
| `Cannot open server ... firewall` | Your IP changed | Azure Portal → SQL server → Networking → Add your client IP → Save |
| `ModuleNotFoundError: No module named 'pyodbc'` | ODBC not installed | Re-run `pip install pyodbc` after installing ODBC Driver 18 |
| `Data source not found` in Power BI | Server name typo | Re-check the `.database.windows.net` address |
| SQL script runs but no output shown | Script ran successfully | "Commands completed successfully" in the bottom tab means success |
| Azure Data Studio shows red X on connection | Connection dropped | Right-click server → Disconnect → Connect again |
| `ValueError: Cannot convert...` in ETL | Data type issue | Run `python main_etl.py --dry-run` to see which column fails |
| Power BI says "Relationship inactive" | Date table not marked | In Power BI: click dim_date table → Table tools → Mark as date table |

---

## CONGRATULATIONS!

You have successfully:
- ✅ Created an enterprise Azure SQL Data Warehouse
- ✅ Designed and deployed a Star Schema with 5 dimensions + 3 fact tables
- ✅ Loaded 2,000 real e-commerce records through a production-quality ETL pipeline
- ✅ Built analytical SQL queries across 7 business domains
- ✅ Connected Power BI for live dashboard creation

**Your data warehouse stores EGP 10.08 million in revenue across 1,283 customers,
100 products, 5 Egyptian cities, and 4 years of sales history.**

---

## NEXT STEPS

| Goal | Action |
|------|--------|
| Run ETL on a schedule | Set up Azure Data Factory (see `config/adf_pipeline.json`) |
| Load new data monthly | Use `python incremental_load.py` instead of full reload |
| Add more data sources | Add new CSV columns → update staging DDL → add fields to facts |
| Share dashboard | Publish to Power BI Service → Share with colleagues |
| Scale to millions of rows | Migrate to Azure Synapse (see `docs/architecture.md` Section 5) |
| Secure production deployment | Run `sql/01_setup/10_security.sql` to set up proper users |
