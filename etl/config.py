# =============================================================================
# FILE: config.py
# PURPOSE: Central configuration for all ETL scripts.
#          Real credentials must NEVER be committed to source control.
#          In production: load from Azure Key Vault or environment variables.
# =============================================================================

import os

# ─────────────────────────────────────────────────────────────────────────────
# AZURE SQL DATABASE CONNECTION
# Replace placeholder values with your actual Azure SQL credentials.
# Best practice: set these as environment variables or Azure Key Vault secrets.
# ─────────────────────────────────────────────────────────────────────────────
AZURE_SQL = {
    "server":   os.getenv("AZURE_SQL_SERVER",   "sql-itc-dw-server.database.windows.net"),
    "database": os.getenv("AZURE_SQL_DATABASE",  "ITC_DataWarehouse"),
    "username": os.getenv("AZURE_SQL_USERNAME",  "itc_etl_user"),
    "password": os.getenv("AZURE_SQL_PASSWORD",  "YOUR_PASSWORD_HERE"),
    "driver":   "{ODBC Driver 18 for SQL Server}",
    "port":     1433,
    "encrypt":  "yes",
    "trust_server_certificate": "no",
    "connection_timeout": 30,
}

# SQLAlchemy connection string (used by pandas .to_sql())
def get_sqlalchemy_url() -> str:
    from urllib.parse import quote_plus
    params = quote_plus(
        f"DRIVER={AZURE_SQL['driver']};"
        f"SERVER=tcp:{AZURE_SQL['server']},{AZURE_SQL['port']};"
        f"DATABASE={AZURE_SQL['database']};"
        f"UID={AZURE_SQL['username']};"
        f"PWD={AZURE_SQL['password']};"
        f"Encrypt={AZURE_SQL['encrypt']};"
        f"TrustServerCertificate={AZURE_SQL['trust_server_certificate']};"
        f"Connection Timeout={AZURE_SQL['connection_timeout']};"
    )
    return f"mssql+pyodbc:///?odbc_connect={params}"

# pyodbc connection string (used by direct SQL execution)
def get_pyodbc_conn_str() -> str:
    return (
        f"DRIVER={AZURE_SQL['driver']};"
        f"SERVER=tcp:{AZURE_SQL['server']},{AZURE_SQL['port']};"
        f"DATABASE={AZURE_SQL['database']};"
        f"UID={AZURE_SQL['username']};"
        f"PWD={AZURE_SQL['password']};"
        f"Encrypt={AZURE_SQL['encrypt']};"
        f"TrustServerCertificate={AZURE_SQL['trust_server_certificate']};"
        f"Connection Timeout={AZURE_SQL['connection_timeout']};"
    )

# ─────────────────────────────────────────────────────────────────────────────
# FILE PATHS
# ─────────────────────────────────────────────────────────────────────────────
import pathlib

BASE_DIR        = pathlib.Path(__file__).parent.parent   # project root
RAW_DATA_DIR    = BASE_DIR / "data" / "raw"
PROCESSED_DIR   = BASE_DIR / "data" / "processed"
LOG_DIR         = BASE_DIR / "logs"
SQL_DIR         = BASE_DIR / "sql"

SOURCE_CSV      = RAW_DATA_DIR / "ITC_ecommerce_2000_rows.csv"

# ─────────────────────────────────────────────────────────────────────────────
# ETL SETTINGS
# ─────────────────────────────────────────────────────────────────────────────
ETL_BATCH_SIZE  = 500       # Rows per SQL bulk insert batch
ETL_LOG_LEVEL   = "INFO"    # DEBUG | INFO | WARNING | ERROR

# ─────────────────────────────────────────────────────────────────────────────
# BUSINESS RULES (used by transform layer)
# ─────────────────────────────────────────────────────────────────────────────
PRICE_BANDS = {
    "Budget":     (0,    500),
    "Mid-Range":  (500,  2000),
    "Premium":    (2000, 4000),
    "Luxury":     (4000, float("inf")),
}

CITY_TO_GEOGRAPHY = {
    "Cairo":       1,
    "Giza":        2,
    "Alexandria":  3,
    "Mansoura":    4,
    "Tanta":       5,
}

DEFAULT_CHANNEL_SK = 1   # 'Online Store' — assign until source has channel data
