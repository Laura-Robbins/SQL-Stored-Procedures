USE [Reporting]
GO

/****** Object:  StoredProcedure [dbo].[usp_InternalReportsAlert_Execllus_CE]    Script Date: 3/12/2026 7:57:44 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO



--EXECUTE [dbo].[usp_InternalReportsAlert_Execllus_CE]


CREATE   PROCEDURE [dbo].[usp_InternalReportsAlert_Execllus_CE]
AS
BEGIN
    SET NOCOUNT ON;


IF OBJECT_ID('dbo.Audit_Results_Excellus') IS NULL
BEGIN
    CREATE TABLE dbo.Audit_Results_Excellus (
        MeasureKey VARCHAR(10),
        Contract VARCHAR(100),
        LOB VARCHAR(100),
        MeasureName VARCHAR(300),
        IssueType VARCHAR(50),
        Prev_Num VARCHAR(100), Cur_Num VARCHAR(100),
        Prev_Den VARCHAR(100), Cur_Den VARCHAR(100),
        Prev_Rate VARCHAR(100), Cur_Rate VARCHAR(100)
    );
END
TRUNCATE TABLE dbo.Audit_Results_Excellus;

DECLARE @LatestRun DATETIME = (SELECT MAX(INSERTDATE) FROM dbo.Internal_Excellus_CE_Rates_History_2025);
DECLARE @PreviousRun DATETIME = (SELECT MAX(INSERTDATE) FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE < @LatestRun);

--SELECT @LatestRun, @PreviousRun --2026-03-06 09:13:50.830, 2026-03-05 07:30:22.137

INSERT INTO dbo.Audit_Results_Excellus (MeasureKey, Contract, LOB, MeasureName, IssueType, Prev_Num, Cur_Num, Prev_Den, Cur_Den, Prev_Rate, Cur_Rate)
SELECT 
    curr.PERFORMANCEMEASUREKEY, curr.CONTRACTNAME, curr.LOB, curr.SERVICEMETRICNAME AS MeasureName,
    'DATA CHANGE',
    MAX(prev.NUMERATOR), MAX(curr.NUMERATOR),
    MAX(prev.DENOMINATOR), MAX(curr.DENOMINATOR),
    MAX(prev.RATE), MAX(curr.RATE)
FROM (SELECT * FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @LatestRun) curr
INNER JOIN (SELECT * FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @PreviousRun) prev
    ON curr.PERFORMANCEMEASUREKEY = prev.PERFORMANCEMEASUREKEY 
    AND curr.CONTRACTNAME = prev.CONTRACTNAME 
    AND curr.LOB = prev.LOB
WHERE --(curr.NUMERATOR <> prev.NUMERATOR OR curr.DENOMINATOR <> prev.DENOMINATOR OR curr.RATE <> prev.RATE) 
--AND 
curr.PERCENTILE_25_RATE IS NOT NULL
GROUP BY curr.PERFORMANCEMEASUREKEY, curr.CONTRACTNAME, curr.LOB, curr.SERVICEMETRICNAME


INSERT INTO dbo.Audit_Results_Excellus (MeasureKey, Contract, LOB, IssueType, Prev_Num, Cur_Num, Prev_Den, Cur_Den, Prev_Rate, Cur_Rate)
SELECT 
    ISNULL(curr.PERFORMANCEMEASUREKEY, prev.PERFORMANCEMEASUREKEY),
    ISNULL(curr.CONTRACTNAME, prev.CONTRACTNAME),
    ISNULL(curr.LOB, prev.LOB),
    CASE WHEN curr.PERFORMANCEMEASUREKEY IS NULL THEN 'DROPPED FROM RUN' ELSE 'NEW MEASURE ADDED' END,
    prev.NUMERATOR, curr.NUMERATOR,
    prev.DENOMINATOR, curr.DENOMINATOR,
    prev.RATE, curr.RATE
FROM (SELECT * FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @LatestRun) curr
FULL OUTER JOIN (SELECT * FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @PreviousRun) prev
    ON curr.PERFORMANCEMEASUREKEY = prev.PERFORMANCEMEASUREKEY 
    AND curr.CONTRACTNAME = prev.CONTRACTNAME 
    AND curr.LOB = prev.LOB
WHERE (curr.PERFORMANCEMEASUREKEY IS NULL OR prev.PERFORMANCEMEASUREKEY IS NULL)
AND 
   (
        (curr.PERFORMANCEMEASUREKEY IS NULL AND prev.PERCENTILE_25_RATE IS NOT NULL) 
        OR 
        (prev.PERFORMANCEMEASUREKEY IS NULL)
    );

	--SELECT * FROM dbo.Audit_Results_Excellus
	--UPDATE A
	--SET A.Cur_Rate = '58.34%'
	--FROM dbo.Audit_Results_Excellus A
	--WHERE MeasureKey = 128
	--AND Contract = 'Excellus ACQA'
	--AND LOB = 'Commercial'

DECLARE @TotalPrevCount INT = (SELECT COUNT(*) FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @PreviousRun);
DECLARE @TotalCurrCount INT = (SELECT COUNT(*) FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @LatestRun);

DECLARE @TotalPrevCountRatesUsed INT = (SELECT COUNT(*) FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @PreviousRun AND PERCENTILE_25_RATE IS NOT NULL);
DECLARE @TotalCurrCountRatesUsed INT = (SELECT COUNT(*) FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @LatestRun AND PERCENTILE_25_RATE IS NOT NULL);

UPDATE dbo.Audit_Results_Excellus SET Contract = CASE WHEN Contract = 'Excellus ACQA' THEN 'Excellus' ELSE Contract END 

--DECLARE @DATEKEY INT = (SELECT MAX(DATEKEY) FROM dbo.Internal_Execllus_CE_Rates_History_2025 WHERE INSERTDATE = @LatestRun);

DECLARE @DATEKEY INT = (SELECT MAX(DATEKEY) FROM dbo.Internal_Excellus_CE_Rates_History_2025 WHERE INSERTDATE = @LatestRun);
DECLARE @ENDDATE DATETIME = (SELECT CAST(CONVERT(VARCHAR(10),DATE,101) AS DATETIME) FROM QUALITY_OF_CARE_DM..DIM_DATE WHERE DATEKEY=@DATEKEY)
DECLARE @MSR_STARTDATE DATETIME = DATEADD(MONTH,-12,@ENDDATE)+1

--SELECT @MSR_STARTDATE, @ENDDATE

DECLARE @xml NVARCHAR(MAX);
DECLARE @body NVARCHAR(MAX);

IF EXISTS (SELECT 1 FROM dbo.Audit_Results_Excellus)
BEGIN
    SET @xml = CAST(( 
        SELECT 
            td = MeasureKey, '', 
            td = Contract, '', 
            td = LOB, '',
            td = MeasureName, '',
            td = ISNULL(Prev_Num, '0'), '', 
            td = ISNULL(Cur_Num, '0'), '', 
            td = ISNULL(Prev_Den, '0'), '', 
            td = ISNULL(Cur_Den, '0'), '', 
            td = ISNULL(Prev_Rate, '0%'), '', 
            td = ISNULL(Cur_Rate, '0%'), '',
            (
                SELECT 
                    CASE 
                        WHEN Prev_Rate IS NULL OR Cur_Rate IS NULL THEN 'background-color: #FFFFFF;'
                        WHEN ABS(CAST(REPLACE(Cur_Rate, '%', '') AS DECIMAL(18,2)) - CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,2))) >= 5.0 THEN 'background-color: #FFC7CE; color: #9C0006; font-weight: bold;'
                        WHEN ABS(CAST(REPLACE(Cur_Rate, '%', '') AS DECIMAL(18,2)) - CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,2))) >= 2.0 THEN 'background-color: #FFEB9C; color: #9C6500;'
                        ELSE 'background-color: #C6EFCE; color: #006100;'
                    END AS [@style],
                    CASE 
                        WHEN Prev_Rate IS NOT NULL AND Cur_Rate IS NOT NULL 
                        THEN CAST(CAST((CAST(REPLACE(Cur_Rate, '%', '') AS DECIMAL(18,4)) - CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,4))) AS DECIMAL(18,2)) AS VARCHAR(20)) + '%'
                        ELSE 'N/A' 
                    END AS [text()]
                FOR XML PATH('td'), TYPE
            ), ''
        FROM dbo.Audit_Results_Excellus
        FOR XML PATH('tr'), ELEMENTS ) AS NVARCHAR(MAX));

    SET @body = '<html><style>
                table { border-collapse: collapse; font-family: Calibri, sans-serif; font-size: 13px; }
                th { background-color: #4472C4; color: white; padding: 8px; border: 1px solid #000; }
                td { padding: 8px; border: 1px solid #ccc; text-align: center; }
                </style><body>


                <h3>Quality Measure Integrity Report - Excellus Continuous Enrollment</h3>

				<div class="title-secondary">Measurement Year Rates - 2025</div>

				<div class="parameters">
                    Latest Report Parameters: ' + CONVERT(VARCHAR, @MSR_STARTDATE, 107) + ' to ' + CONVERT(VARCHAR, @ENDDATE, 107) + '
                </div>

                <p><b>Run Comparison:</b><br>
				    Previous Run: ' + CONVERT(VARCHAR, @PreviousRun, 100) + ' — <b>' + CAST(@TotalPrevCount AS VARCHAR(20))  + ' Total Rows — <b>' + CAST(@TotalPrevCountRatesUsed AS VARCHAR(20))+ ' Rows With Current Measurement Year Rates<br>
                    Latest Run: ' + CONVERT(VARCHAR, @LatestRun, 100) + ' — <b>' + CAST(@TotalCurrCount AS VARCHAR(20))+ ' Total Rows — <b>' + CAST(@TotalCurrCountRatesUsed AS VARCHAR(20)) + ' Rows With Current Measurement Year Rates</p>
 
                <table border="1">
                <tr>
                    <th>Key</th><th>Contract</th><th>LOB</th><th>MeasureName</th>
                    <th>Prev Num</th><th>Cur Num</th><th>Prev Den</th><th>Cur Den</th>
                    <th>Prev Rate</th><th>Cur Rate</th><th>Rate Diff</th>
                </tr>'
                + REPLACE(REPLACE(@xml, '&lt;', '<'), '&gt;', '>') + '</table></body></html>';


    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'sqlmail',
        @recipients = 'William.Apps@rochesterregional.org; Jennifer.Hajecki@rochesterregional.org; Sharon.Polak@rochesterregional.org; GRIPADBA@rochesterregional.org',
        @subject = 'DATA ALERT (Excellus CE): Integrity Report Info',
        @body = @body,
        @body_format = 'HTML'
END


SET @xml = NULL;
SET @body = NULL;


SET @xml = CAST(( 
    SELECT 
        td = MeasureKey, '', td = Contract, '', td = LOB, '',td = MeasureName, '',
        td = Prev_Rate, '', td = Cur_Rate, '',
        td = CAST(CAST(ABS(CAST(REPLACE(Cur_Rate, '%', '') AS DECIMAL(18,4)) - CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,4))) AS DECIMAL(18,2)) AS VARCHAR(20)) + '%', ''
    FROM dbo.Audit_Results_Excellus
    WHERE IssueType = 'DATA CHANGE'
      AND ABS(CAST(REPLACE(Cur_Rate, '%', '') AS DECIMAL(18,4)) - CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,4))) > (CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,4)) * 0.10)
      AND CAST(REPLACE(Prev_Rate, '%', '') AS DECIMAL(18,4)) <> 0
    FOR XML PATH('tr'), ELEMENTS ) AS NVARCHAR(MAX));

IF @xml IS NOT NULL
BEGIN
    SET @body = '<html><style>
                table { border-collapse: collapse; font-family: Calibri, sans-serif; }
                th { background-color: #C00000; color: white; padding: 6px; border: 1px solid #000; }
                td { padding: 6px; border: 1px solid #ccc; text-align: center; }
                </style><body>
                <h2 style="color: #C00000;">URGENT: Significant Rate Variance</h2>
                <p><b>Data Timestamps:</b><br>
                   Previous Run: ' + CONVERT(VARCHAR, @LatestRun, 100) + '<br>
                   Latest Run: ' + CONVERT(VARCHAR, @PreviousRun, 100) + '</p>
                <table>
                <tr><th>Measure</th><th>Contract</th><th>LOB</th><th>MeasureName</th><th>Prev Rate</th><th>Cur Rate</th><th>Point Diff</th></tr>'
                + REPLACE(@xml, ' < ', '<') + '</table></body></html>';

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = 'sqlmail',
        @recipients = 'William.Apps@rochesterregional.org',
        @subject = 'CRITICAL (Excellus CE): >10% Rate Change Detected',
        @body = @body,
        @body_format = 'HTML',
        @importance = 'High';
END

END
GO


