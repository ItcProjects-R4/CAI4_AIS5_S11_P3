# Azure Deployment Guide
## ITC E-Commerce Data Warehouse
### Complete Step-by-Step for Beginners

---

## PREREQUISITES

Before starting, make sure you have:
- An active **Azure subscription** (free tier works for learning)
- **Azure CLI** installed: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
- **Python 3.9+** installed locally
- **ODBC Driver 18 for SQL Server** installed:
  - Windows: https://aka.ms/downloadmsodbcsql
  - Linux: `sudo apt install msodbcsql18`
  - Mac: `brew install msodbcsql18`
- **Azure Data Studio** or **SQL Server Management Studio (SSMS)** for running SQL

---

## PHASE 1 — CREATE AZURE RESOURCES

### Step 1.1 — Log into Azure Portal

1. Open your browser and go to **https://portal.azure.com**
2. Sign in with your Microsoft account
3. You will see the Azure home dashboard

---

### Step 1.2 — Create a Resource Group

A Resource Group is a logical container for all your Azure resources.

**Via Azure Portal (click-by-click):**
1. In the top search bar, type **"Resource groups"** and click it
2. Click **+ Create** (blue button, top left)
3. Fill in:
   - **Subscription**: Your subscription name
   - **Resource group name**: `rg-itc-datawarehouse`
   - **Region**: `(Europe) West Europe` *(or choose closest to Egypt: UAE North)*
4. Click **Review + create**
5. Click **Create**

**Via Azure CLI (faster):**
```bash
az login
az group create \
  --name rg-itc-datawarehouse \
  --location "westeurope"
```

---

### Step 1.3 — Create Azure SQL Server

1. In the search bar type **"SQL servers"** → Click it
2. Click **+ Create**
3. Fill in:
   - **Subscription**: Your subscription
   - **Resource group**: `rg-itc-datawarehouse`
   - **Server name**: `sql-itc-dw-server` *(must be globally unique — add your initials)*
   - **Location**: Same as resource group
   - **Authentication method**: Select **"Use SQL authentication"**
   - **Server admin login**: `itc_admin`
   - **Password**: Create a strong password (min 12 chars, uppercase, number, symbol)
   - **Confirm password**: Same password
4. Click **Review + create** → **Create**
5. Wait ~2 minutes for deployment

**Via CLI:**
```bash
az sql server create \
  --resource-group rg-itc-datawarehouse \
  --name sql-itc-dw-server \
  --location westeurope \
  --admin-user itc_admin \
  --admin-password "YourStr0ngP@ssword!"
```

---

### Step 1.4 — Create Azure SQL Database

1. In search bar type **"SQL databases"** → Click it
2. Click **+ Create**
3. Fill in:
   - **Subscription**: Your subscription
   - **Resource group**: `rg-itc-datawarehouse`
   - **Database name**: `ITC_DataWarehouse`
   - **Server**: Select the server you just created
   - **Want to use SQL elastic pool?**: No
   - **Compute + storage**: Click **"Configure database"**
     - Select **"Basic"** tier for development (5 DTUs, ~$5/month)
     - For production: Select **"Standard S3"** (100 DTUs, ~$75/month)
   - **Backup storage redundancy**: Locally-redundant (cheapest for dev)
4. Click **Review + create** → **Create**
5. Wait ~3 minutes

**Via CLI:**
```bash
az sql db create \
  --resource-group rg-itc-datawarehouse \
  --server sql-itc-dw-server \
  --name ITC_DataWarehouse \
  --service-objective S2 \
  --backup-storage-redundancy Local
```

---

### Step 1.5 — Configure Firewall Rules

By default, Azure SQL blocks ALL external connections. You must whitelist your IP.

**Via Azure Portal:**
1. Go to your SQL Server: search "SQL servers" → click `sql-itc-dw-server`
2. In the left menu, click **"Networking"**
3. Under **"Firewall rules"**, click **"+ Add your client IPv4 address"**
   - This automatically adds your current IP
4. Also add a rule for Azure services:
   - Toggle **"Allow Azure services and resources to access this server"** → **ON**
   - (This lets Azure Data Factory and other Azure services connect)
5. Click **Save**

**Via CLI (replace YOUR_IP with your actual IP from https://whatismyip.com):**
```bash
az sql server firewall-rule create \
  --resource-group rg-itc-datawarehouse \
  --server sql-itc-dw-server \
  --name AllowMyIP \
  --start-ip-address YOUR.IP.ADDRESS.HERE \
  --end-ip-address YOUR.IP.ADDRESS.HERE

# Allow Azure services
az sql server firewall-rule create \
  --resource-group rg-itc-datawarehouse \
  --server sql-itc-dw-server \
  --name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0
```

---

## PHASE 2 — RUN SQL SCRIPTS

### Step 2.1 — Connect with Azure Data Studio

1. Download Azure Data Studio: https://aka.ms/azuredatastudio
2. Open it → Click **"New Connection"**
3. Fill in:
   - **Connection type**: Microsoft SQL Server
   - **Server**: `sql-itc-dw-server.database.windows.net`
   - **Authentication type**: SQL Login
   - **User name**: `itc_admin`
   - **Password**: Your password
   - **Database**: `ITC_DataWarehouse`
4. Click **Connect**

---

### Step 2.2 — Run SQL Scripts in Order

In Azure Data Studio, open each file and press **F5** (or click Run):

```
Run in this exact order:
─────────────────────────────────────────────────────────
1.  sql/01_setup/01_database_and_schemas.sql
2.  sql/01_setup/02_raw_layer.sql
3.  sql/01_setup/03_staging_layer.sql
4.  sql/02_dimensions/04_dimension_tables.sql
5.  sql/02_dimensions/05_populate_dim_date.sql
6.  sql/03_facts/06_fact_tables.sql
7.  sql/04_indexes/07_indexes_and_constraints.sql
8.  sql/05_analytics/08_analytics_queries.sql
─────────────────────────────────────────────────────────
```

**How to open a file in Azure Data Studio:**
1. Click **File** → **Open File**
2. Navigate to your project folder
3. Select the SQL file
4. Click the **Run** button (triangle/play icon) at top

After each script, you should see a green **"Commands completed successfully"** message.

---

## PHASE 3 — RUN THE ETL PIPELINE

### Step 3.1 — Set Up Python Environment

Open a terminal (Command Prompt on Windows, Terminal on Mac/Linux):

```bash
# Navigate to your project folder
cd C:\path\to\project\etl      # Windows
# OR
cd ~/path/to/project/etl       # Mac/Linux

# Create a virtual environment
python -m venv venv

# Activate it
venv\Scripts\activate           # Windows
source venv/bin/activate        # Mac/Linux

# Install dependencies
pip install -r requirements.txt
```

---

### Step 3.2 — Configure Your Credentials

**Option A — Environment Variables (recommended, never commit passwords):**

Windows:
```cmd
set AZURE_SQL_SERVER=sql-itc-dw-server.database.windows.net
set AZURE_SQL_DATABASE=ITC_DataWarehouse
set AZURE_SQL_USERNAME=itc_admin
set AZURE_SQL_PASSWORD=YourStr0ngP@ssword!
```

Mac/Linux:
```bash
export AZURE_SQL_SERVER="sql-itc-dw-server.database.windows.net"
export AZURE_SQL_DATABASE="ITC_DataWarehouse"
export AZURE_SQL_USERNAME="itc_admin"
export AZURE_SQL_PASSWORD="YourStr0ngP@ssword!"
```

**Option B — .env file (for local dev only):**

Create a file named `.env` in the `etl/` folder:
```
AZURE_SQL_SERVER=sql-itc-dw-server.database.windows.net
AZURE_SQL_DATABASE=ITC_DataWarehouse
AZURE_SQL_USERNAME=itc_admin
AZURE_SQL_PASSWORD=YourStr0ngP@ssword!
```
> ⚠️ **IMPORTANT**: Add `.env` to `.gitignore` — never push credentials to GitHub!

---

### Step 3.3 — Test the Connection

```bash
python -c "from load import test_connection; test_connection()"
```

Expected output:
```
INFO | Azure SQL connection OK. Server time: 2025-05-26 10:30:00
```

---

### Step 3.4 — Run a Dry Run First (no DB writes)

```bash
python main_etl.py --dry-run
```

This runs the full extract and transform pipeline and prints a summary
without writing anything to the database. Verify the output looks correct.

---

### Step 3.5 — Run the Full ETL Pipeline

```bash
python main_etl.py
```

Expected output:
```
============================================================
ITC DATA WAREHOUSE ETL — STARTED 2025-05-26T10:30:00Z
============================================================
STEP DONE: Extract CSV in 0.3s
STEP DONE: Clean & Validate Data in 1.2s
STEP DONE: Load Raw Layer in 4.5s
STEP DONE: Load Staging Layer in 3.1s
STEP DONE: Build dim_customer in 0.2s
STEP DONE: Load dim_customer in 2.3s
STEP DONE: Build dim_product in 0.1s
STEP DONE: Load dim_product in 0.8s
STEP DONE: Build fact_order_items in 0.5s
STEP DONE: Load fact_order_items in 6.2s
STEP DONE: Build fact_order_summary in 0.3s
STEP DONE: Load fact_order_summary in 3.4s
STEP DONE: Build fact_monthly_product_performance in 0.2s
STEP DONE: Load fact_monthly_product_performance in 1.1s
============================================================
ETL PIPELINE COMPLETE in 24.2s
  Source rows     : 2,000
  Clean rows      : 2,000
  Customers loaded: 1,283
  Products loaded : 100
  Fact rows loaded: 2,000
============================================================
```

---

## PHASE 4 — OPTIONAL: AZURE DATA FACTORY (ADF)

Azure Data Factory automates and schedules your ETL pipeline on Azure.

### Step 4.1 — Create a Data Factory

1. Search **"Data factories"** in Azure Portal → **+ Create**
2. Fill in:
   - **Resource group**: `rg-itc-datawarehouse`
   - **Name**: `adf-itc-datawarehouse`
   - **Region**: Same as SQL server
   - **Version**: V2
3. Click **Review + create** → **Create**

### Step 4.2 — Create a Pipeline

1. Open the Data Factory → Click **"Open Azure Data Factory Studio"**
2. Click **"New pipeline"**
3. Add a **"Copy data"** activity for the CSV → Azure Blob Storage
4. Add a **"Stored procedure"** activity for ETL transformations
5. Set a **Trigger** → **"New/Edit"** → Schedule (e.g., daily at 2 AM)

> For a full ADF walkthrough: https://docs.microsoft.com/azure/data-factory/

---

## PHASE 5 — CONNECT POWER BI

### Step 5.1 — Download Power BI Desktop

Download from: https://powerbi.microsoft.com/desktop

### Step 5.2 — Connect to Azure SQL

1. Open Power BI Desktop
2. Click **"Get data"** → Search **"Azure SQL database"** → **Connect**
3. Fill in:
   - **Server**: `sql-itc-dw-server.database.windows.net`
   - **Database**: `ITC_DataWarehouse`
   - **Data Connectivity mode**: **Import** (for dashboards up to ~1M rows)
     OR **DirectQuery** (for always-fresh data, slower)
4. Click **OK**
5. Authentication:
   - Select **"Database"**
   - Username: `itc_admin`
   - Password: Your password
6. Click **Connect**

### Step 5.3 — Select Tables for Import

In the Navigator window, select:
- ☑ `analytics.vw_monthly_revenue`
- ☑ `analytics.vw_product_performance`
- ☑ `analytics.vw_city_performance`
- ☑ `analytics.vw_customer_360`
- ☑ `dw.dim_date`
- ☑ `dw.dim_customer`
- ☑ `dw.dim_product`
- ☑ `dw.dim_geography`
- ☑ `dw.fact_order_items`

Click **Load**.

### Step 5.4 — Set Up Relationships (if not auto-detected)

Go to **Model view** (left sidebar, relationship icon):

Verify these relationships exist (drag to create if missing):
```
dim_date.date_key          ──── fact_order_items.order_date_key
dim_customer.customer_sk   ──── fact_order_items.customer_sk
dim_product.product_sk     ──── fact_order_items.product_sk
dim_geography.geography_sk ──── fact_order_items.geography_sk
```

---

## PHASE 6 — OPTIONAL: AZURE SYNAPSE ANALYTICS

For datasets > 10M rows, migrate to Azure Synapse Dedicated SQL Pool:

```bash
# Create Synapse workspace
az synapse workspace create \
  --name synapse-itc-dw \
  --resource-group rg-itc-datawarehouse \
  --storage-account your-storage-account \
  --file-system synapse-fs \
  --sql-admin-login-user synapse_admin \
  --sql-admin-login-password "YourStr0ngP@ssword!" \
  --location westeurope
```

Key differences for Synapse SQL:
- Replace `IDENTITY(1,1)` with `IDENTITY(1,1)` (same syntax)
- Add `WITH (DISTRIBUTION = HASH(customer_sk))` to fact tables
- Replace `TOP N` with `FETCH FIRST N ROWS ONLY`
- Add `OPTION (LABEL = 'query_name')` for monitoring

---

## COMMON ERRORS AND FIXES

| Error | Cause | Fix |
|-------|-------|-----|
| `Login failed for user 'itc_admin'` | Wrong password or username | Double-check credentials; reset password in Azure Portal → SQL server → Reset password |
| `Cannot open server... firewall` | Your IP not whitelisted | Azure Portal → SQL Server → Networking → Add your IP |
| `pyodbc.Error: IM002 ODBC Driver not found` | ODBC driver missing | Install "ODBC Driver 18 for SQL Server" from Microsoft |
| `SSL connection failed` | Old TLS version | In connection string, set `Encrypt=yes;TrustServerCertificate=no` |
| `Conversion failed when converting VARCHAR to INT` | Bad data in CSV | Re-run dry-run; check cleaning logs for type errors |
| `Violation of UNIQUE KEY constraint` | Duplicate natural keys in dimension | Check source data for duplicates; the ETL `drop_duplicates()` should catch this |
| `The Azure SQL database has reached its size quota` | Database full | Upgrade tier in Azure Portal → SQL Database → Configure |
| `Timeout expired` | Large load on Basic tier | Increase `connection_timeout` in config.py; or upgrade to Standard S2+ |
| Power BI: `Expression.Error: The column was not found` | Table/column renamed | In Power BI: Home → Transform data → Refresh, or update the query |

---

## COST ESTIMATION (Azure, as of 2025)

| Resource | Tier | Estimated Monthly Cost |
|----------|------|----------------------|
| Azure SQL Database | Basic (5 DTU) | ~$5 USD |
| Azure SQL Database | Standard S2 (50 DTU) | ~$37 USD |
| Azure SQL Database | Standard S3 (100 DTU) | ~$75 USD |
| Azure Data Factory | Pay-per-use | ~$1–5 USD (for this dataset size) |
| Azure Blob Storage | LRS | ~$0.50 USD |
| **Total (dev)** | Basic | **~$6 USD/month** |
| **Total (prod)** | Standard S3 + ADF | **~$80 USD/month** |

**Cost tip**: Stop/pause resources when not in use:
```bash
# Pause SQL Database (deallocates compute, storage still billed)
az sql db update \
  --resource-group rg-itc-datawarehouse \
  --server sql-itc-dw-server \
  --name ITC_DataWarehouse \
  --service-objective Free
```
