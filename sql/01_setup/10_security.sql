-- =============================================================================
-- تعديل متوافق مع Azure SQL ومراعاة التنفيذ السابق وسياسة كلمات المرور
-- =============================================================================

-- 1. إنشاء المجموعات (Roles) إذا لم تكن موجودة
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'db_itc_etl')
    CREATE ROLE db_itc_etl;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'db_itc_bi_reader')
    CREATE ROLE db_itc_bi_reader;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'db_itc_analyst')
    CREATE ROLE db_itc_analyst;
GO

-- 2. إعطاء الصلاحيات للمجموعات
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::raw       TO db_itc_etl;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::staging   TO db_itc_etl;
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dw        TO db_itc_etl;
GRANT SELECT                          ON SCHEMA::analytics TO db_itc_etl;
GRANT EXECUTE                         ON SCHEMA::dw        TO db_itc_etl;
GO

GRANT SELECT ON SCHEMA::dw        TO db_itc_bi_reader;
GRANT SELECT ON SCHEMA::analytics TO db_itc_bi_reader;
GO

GRANT SELECT  ON SCHEMA::dw        TO db_itc_analyst;
GRANT SELECT  ON SCHEMA::analytics TO db_itc_analyst;
GRANT EXECUTE ON SCHEMA::analytics TO db_itc_analyst;
GO

-- 3. إنشاء المستخدمين بكلمات مرور جديدة معقدة ومطابقة لسياسات Azure
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'itc_etl_user')
BEGIN
    EXEC('CREATE USER itc_etl_user WITH PASSWORD = ''Super$ecret#2026A!''');
END;
GO
ALTER ROLE db_itc_etl ADD MEMBER itc_etl_user;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'powerbi_reader')
BEGIN
    EXEC('CREATE USER powerbi_reader WITH PASSWORD = ''Super$ecret#2026B!''');
END;
GO
ALTER ROLE db_itc_bi_reader ADD MEMBER powerbi_reader;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'itc_analyst')
BEGIN
    EXEC('CREATE USER itc_analyst WITH PASSWORD = ''Super$ecret#2026C!''');
END;
GO
ALTER ROLE db_itc_analyst ADD MEMBER itc_analyst;
GO

-- 4. منع الصلاحيات (Denies) للمجموعات لتأمين البيانات الخام
DENY SELECT ON SCHEMA::raw     TO db_itc_bi_reader;
DENY SELECT ON SCHEMA::raw     TO db_itc_analyst;
DENY SELECT ON SCHEMA::staging TO db_itc_bi_reader;
DENY SELECT ON SCHEMA::staging TO db_itc_analyst;
GO

-- 5. حماية عمود الإيميل (بشرط التأكد من وجود الجدول أولاً)
IF OBJECT_ID('dw.dim_customer', 'U') IS NOT NULL
BEGIN
    EXEC('DENY SELECT ON dw.dim_customer (email) TO db_itc_bi_reader;');
    EXEC('ALTER TABLE dw.dim_customer ALTER COLUMN email ADD MASKED WITH (FUNCTION = ''email()'');');
    EXEC('GRANT UNMASK ON dw.dim_customer TO db_itc_etl;');
END
ELSE
BEGIN
    PRINT 'Table dw.dim_customer does not exist yet. Skipping column-level security and masking.';
END
GO

-- 6. كود التأكيد لعرض المستخدمين والصلاحيات
SELECT 
    r.name AS role_name, 
    m.name AS member_name
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE r.name LIKE 'db_itc%';
GO