-- =============================================================================
-- FILE: 05_populate_dim_date.sql
-- PURPOSE: Stored procedure to populate dw.dim_date from 2019-01-01 to
--          2030-12-31 (4018 rows). Run once after table creation.
-- =============================================================================

USE ITC_DataWarehouse;
GO

CREATE OR ALTER PROCEDURE dw.usp_populate_dim_date
    @start_date DATE = '2019-01-01',
    @end_date   DATE = '2030-12-31'
AS
BEGIN
    SET NOCOUNT ON;

    -- Clear and reload for idempotence
    TRUNCATE TABLE dw.dim_date;

    DECLARE @current_date DATE = @start_date;

    WHILE @current_date <= @end_date
    BEGIN
        INSERT INTO dw.dim_date (
            date_key, full_date, day_of_month, day_name, day_of_week,
            day_of_year, week_of_year, month_number, month_name,
            month_name_short, quarter_number, quarter_name,
            year_number, year_month, year_quarter,
            is_weekend, is_weekday, is_leap_year, days_in_month
        )
        VALUES (
            -- date_key: YYYYMMDD integer
            CAST(FORMAT(@current_date, 'yyyyMMdd') AS INT),
            @current_date,
            DAY(@current_date),
            DATENAME(WEEKDAY, @current_date),
            DATEPART(WEEKDAY, @current_date),
            DATEPART(DAYOFYEAR, @current_date),
            DATEPART(ISO_WEEK, @current_date),
            MONTH(@current_date),
            DATENAME(MONTH, @current_date),
            LEFT(DATENAME(MONTH, @current_date), 3),
            DATEPART(QUARTER, @current_date),
            'Q' + CAST(DATEPART(QUARTER, @current_date) AS CHAR(1)),
            YEAR(@current_date),
            FORMAT(@current_date, 'yyyy-MM'),
            CAST(YEAR(@current_date) AS CHAR(4)) + '-Q'
                + CAST(DATEPART(QUARTER, @current_date) AS CHAR(1)),
            -- is_weekend: 1 if Saturday(7) or Sunday(1)
            CASE WHEN DATEPART(WEEKDAY, @current_date) IN (1,7) THEN 1 ELSE 0 END,
            -- is_weekday
            CASE WHEN DATEPART(WEEKDAY, @current_date) IN (1,7) THEN 0 ELSE 1 END,
            -- is_leap_year
            CASE WHEN (YEAR(@current_date) % 4 = 0
                       AND (YEAR(@current_date) % 100 <> 0
                            OR YEAR(@current_date) % 400 = 0))
                 THEN 1 ELSE 0 END,
            -- days_in_month
            DAY(EOMONTH(@current_date))
        );

        SET @current_date = DATEADD(DAY, 1, @current_date);
    END;

    DECLARE @row_count INT = (SELECT COUNT(*) FROM dw.dim_date);
    PRINT 'dim_date populated: ' + CAST(@row_count AS VARCHAR) + ' rows.';
END;
GO

-- Execute immediately
EXEC dw.usp_populate_dim_date;
GO
