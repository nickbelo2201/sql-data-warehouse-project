-- Loading data silver layer table 'silver.crm_cust_info'
-- with normalize & remove duplicates
CREATE OR ALTER PROCEDURE silver.load_silver AS
BEGIN
DECLARE @start_time DATETIME, @end_time DATETIME, 
		@batch_start_time DATETIME, @batch_end_time DATETIME
	BEGIN TRY
	SET @batch_start_time = GETDATE()
	PRINT '================================================='
	PRINT 'Loading Data Silver Layer'
	PRINT '================================================='

	PRINT '-------------------------------------------------'
	PRINT 'Loading CRM Tables'
	PRINT '-------------------------------------------------'
	
	SET @start_time = GETDATE()
	PRINT '>> Truncating Data Table: silver.crm_cust_info'
	TRUNCATE TABLE silver.crm_cust_info;
	PRINT '>> Loading Data Into: silver.crm_cust_info'
	INSERT INTO silver.crm_cust_info(
		cst_id,
		cst_key,
		cst_firstname,
		cst_lastname,
		cst_marital_status,
		cst_gndr,
		cst_create_date)
	SELECT
	cst_id,
	cst_key,
	TRIM(cst_firstname) AS cst_firstname,
	TRIM(cst_lastname) AS cst_lastname,
	CASE WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
		 WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
		Else 'n/a'
	END cst_marital_status, -- Normalize marital status values to readable format 
	CASE WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
		 WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
		Else 'n/a'
	END cst_gndr, -- Normalize gender values to readable format
	cst_create_date
	FROM (
		-- data cleaning duplicates
		SELECT
			*, 
			ROW_NUMBER() OVER(PARTITION BY cst_id ORDER BY cst_create_date DESC) AS flag_last
		FROM bronze.crm_cust_info 
		WHERE cst_id IS NOT NULL
		) t
	WHERE flag_last = 1; -- Select the most recent record per customer
	SET @end_time = GETDATE()
	PRINT 'Loading Duration: ' + CAST((DATEDIFF(second, @start_time, @end_time)) AS NVARCHAR) + ' seconds' 
	PRINT '--------------------'

	-- Loading data silver layer table 'silver.crm_prd_info' 
	-- with Data Enrichment
	SET @start_time = GETDATE();
	PRINT '>> Truncating Data Table: silver.crm_prd_info'
	TRUNCATE TABLE silver.crm_prd_info;
	PRINT '>> Loading Data Into: silver.crm_prd_info'
	INSERT INTO silver.crm_prd_info (
		prd_id,
		cat_id,
		prd_key,
		prd_nm,
		prd_cost,
		prd_line,
		prd_start_dt,
		prd_end_dt
	)
	SELECT 
	prd_id,
	SUBSTRING(REPLACE(prd_key, '-', '_'), 1, 5) AS cat_id, -- Extract category ID
	SUBSTRING(prd_key, 7, LEN(prd_key)) AS prd_key, -- Extract procuct ID
	prd_nm,
	ISNULL(prd_cost, 0) AS prd_cost,
	CASE TRIM(UPPER(prd_line)) 
		WHEN 'M' THEN 'Mountain'
		WHEN 'R' THEN 'Road'
		WHEN 'S' THEN 'Other Sales'
		WHEN 'T' THEN 'Touring'
		ELSE 'n/a'
	END AS prd_line, -- Map product line codes to descritive values
	CAST(prd_start_dt AS DATE) AS prd_start_dt, 
	CAST(
		LEAD(prd_start_dt) OVER (PARTITION BY prd_key ORDER BY prd_start_dt)-1 
		AS DATE
	) AS prd_end_dt -- Calculated end date as one day before the next start date
	FROM bronze.crm_prd_info;
	SET @end_time = GETDATE()
	PRINT 'Loading Duration: ' + CAST((DATEDIFF(second, @start_time, @end_time)) AS NVARCHAR) + ' seconds'
	PRINT '--------------------'

	-- Loading data silver layer table 'silver.crm_sales_details'
	-- silver.crm_sales_details
	SET @start_time = GETDATE();
	PRINT '>> Truncating Data Table: silver.crm_sales_details'
	TRUNCATE TABLE silver.crm_sales_details;
	PRINT '>> Loading Data Into: silver.crm_sales_details'
	INSERT INTO silver.crm_sales_details(
		sls_ord_num, 
		sls_prd_key, 
		sls_cust_id,
		sls_orders_dt,
		sls_ship_dt,
		sls_due_dt,
		sls_sales,
		sls_quantity,
		sls_price
	)
	SELECT 
		sls_ord_num, 
		sls_prd_key, 
		sls_cust_id, 
		CASE WHEN sls_orders_dt = 0 OR LEN(sls_orders_dt) != 8 THEN NULL
			ELSE CAST(CAST(sls_orders_dt AS VARCHAR) AS DATE) -- transform date
		END AS sls_orders_dt,
		CASE WHEN sls_ship_dt = 0 OR LEN(sls_ship_dt) != 8 THEN NULL
			ELSE CAST(CAST(sls_ship_dt AS VARCHAR) AS DATE) -- transform date
		END AS sls_ship_dt,
		CASE WHEN sls_due_dt = 0 OR LEN(sls_due_dt) != 8 THEN NULL
			ELSE CAST(CAST(sls_due_dt AS VARCHAR) AS DATE) -- transform date
		END AS sls_due_dt,
		CASE WHEN sls_sales != sls_quantity * sls_price OR sls_sales IS NULL OR sls_price <= 0
			THEN sls_quantity * ABS(sls_price)
			ELSE sls_sales
		END AS sls_sales, -- recalculate sales if origin value is missing or incorrect
		sls_quantity,
		CASE WHEN sls_price IS NULL OR sls_price <= 0
			THEN sls_sales / NULLIF(sls_quantity, 0) 
			ELSE sls_price
		END AS sls_price
	FROM bronze.crm_sales_details;
	SET @end_time = GETDATE()
	PRINT 'Loading Duration: ' + CAST((DATEDIFF(second, @start_time, @end_time)) AS NVARCHAR) + ' seconds'
	PRINT '--------------------'

	PRINT '-------------------------------------------------'
	PRINT 'Loading ERP data tables'
	PRINT '-------------------------------------------------'

	-- Loading data silver layer table 'silver.erp_cust_az12'
	-- With data normalize 
	SET @start_time = GETDATE();
	PRINT '>> Truncating Data Table: silver.erp_cust_az12'
	TRUNCATE TABLE silver.erp_cust_az12;
	PRINT '>> Loading Data Into: silver.erp_cust_az12'
	INSERT INTO silver.erp_cust_az12 (cid, bdate, gen)
	SELECT
	CASE WHEN UPPER(TRIM(cid)) LIKE 'NAS%' THEN SUBSTRING(cid, 4, LEN(cid)) -- Remove 'NAS' prefix if present
		 WHEN UPPER(TRIM(cid)) LIKE 'AW%' THEN cid
		 ELSE NULL
	END AS cid,
	CASE WHEN bdate > GETDATE() THEN NULL
		ELSE bdate
	END AS bdate, -- Set future birthdays to NULL
	CASE WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE') THEN 'Female'
		 WHEN UPPER(TRIM(gen)) IN ('M', 'MALE') THEN 'Male'
		ELSE 'n/a'
	END AS gen -- Normalize gender values and handle unknow cases
	FROM bronze.erp_cust_az12;
	SET @end_time = GETDATE()
	PRINT 'Loading Duration: ' + CAST((DATEDIFF(second, @start_time, @end_time)) AS NVARCHAR) + ' seconds'
	PRINT '--------------------'

	-- Loading data silver layer table 'silver.erp_loc_a101'
	-- With data normalization
	PRINT '>> Truncating Data Table: silver.erp_loc_a101'
	TRUNCATE TABLE silver.erp_loc_a101;
	PRINT '>> Loading Data Into: silver.erp_loc_a101'
	INSERT INTO silver.erp_loc_a101 (cid, ctry)
	SELECT
	REPLACE(cid, '-', '') AS cid,
	CASE WHEN TRIM(ctry) = 'DE' THEN 'Germany'
		 WHEN TRIM(ctry) IN ('US', 'USA') THEN 'United States'
		WHEN TRIM(ctry) IS NULL or TRIM(ctry) = '' THEN 'n/a'
		ELSE ctry
	END AS ctry  -- Normalize and handle missing values or blank country codes
	FROM bronze.erp_loc_a101;
	SET @end_time = GETDATE()
	PRINT 'Loading Duration: ' + CAST((DATEDIFF(second, @start_time, @end_time)) AS NVARCHAR) + ' seconds'
	PRINT'--------------------'

	-- Loading data silver layer table 'silver.erp_px_cat_g1v2'
	-- No data transformations
	SET @start_time = GETDATE()
	PRINT '>> Truncating Data Table: silver.erp_px_cat_g1v2'
	TRUNCATE TABLE silver.erp_px_cat_g1v2;
	PRINT '>> Loading Data Into: silver.erp_px_cat_g1v2'
	INSERT INTO silver.erp_px_cat_g1v2 (id, cat, subcat, maintenance)
	SELECT 
		id, 
		cat, 
		subcat, 
		maintenance 
	FROM bronze.erp_px_cat_g1v2
	SET @end_time = GETDATE()
	PRINT ('Loading Duration: ' + CAST((DATEDIFF(second, @start_time, @end_time)) AS NVARCHAR) + ' seconds') 
	PRINT'--------------------'

	SET @batch_end_time = GETDATE()
	PRINT'================================================='
	PRINT('Loading Data Silver Layer Complete')
	PRINT'================================================='

	PRINT'-------------------------------------------------'
	PRINT('Total Load Duration: ' + CAST(DATEDIFF(second, @batch_start_time, @batch_end_time) AS NVARCHAR) + ' seconds')
	PRINT'-------------------------------------------------'
	END TRY
	BEGIN CATCH
	PRINT'================================================='
	PRINT 'ERROR OCCURED DURING LOADING SILVER LAYER'
	PRINT 'Error' + ERROR_MESSAGE();
	PRINT 'Error Message' + CAST(ERROR_MESSAGE() AS NVARCHAR)
	PRINT 'Status Message' + CAST(ERROR_STATE() AS NVARCHAR)
	PRINT'================================================='
	END CATCH
END;