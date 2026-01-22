USE [Reporting]
GO

/****** Object:  StoredProcedure [dbo].[HCCPostEncounterWQ]    Script Date: 1/22/2026 10:49:55 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO







CREATE PROC [dbo].[HCCPostEncounterWQ] AS
/*
20241010 LR Creation for ticket 18413.  need help identify additions and deletions of the DX1 column (export from Care Connect)
20241024 LR Added delete statement to remove CPT codes from table
20250206 LR Put truncation of and insertion into HCCPostEncounterWQ_results table in IF statement to make sure only happens when there is data in #Dx_spilt
20250306 LR Ticket 19952: Update the HCC DX Post WQ process to remove records with * in them.  Place those records into a table in case they are needed at another time
*/

SET NOCOUNT on

--- Find records with a * in dx_Comment_1 field
-- if there is a * in this field it means data has been trunctated
-- The size of the field on RRH's size can be a max of 4000 characters.  They can't guarantee there won't be truncation
if object_id('tempdb..#FindNegativeCharIndex') is not null
drop table #FindNegativeCharIndex

select w.PAT_ENC_CSN_ID,w.dx_comment_1
	,y.*
	,charLength = len(dx_comment_1)
	,[CharIndex] = charindex('[',y.item)
	,[CharIndex2] = charindex(']',y.item)
	,[CharIndex3] = charindex(']',y.item)-charindex('[',y.item)
	,[CharIndex4] = charindex('[',y.item)+1
into #FindNegativeCharIndex
from [dbo].[HCC_Post_Encounter_WQ_CareConnectExport] w	
	outer apply reporting.[dbo].[udf_DelimitedSplit8K] (w.dx_comment_1,'|') x-- this udf has an 8000 character limit
    outer apply reporting.[dbo].[udf_DelimitedSplit8K] (x.item,'=') y
where y.Item like '%[[]%'
order by charindex(']',y.item)-charindex('[',y.item)

-- create table of records that have a negative in one of the CharIndex fields
-- These records will disrupt the process of records be putting into #Dx_spilt
if object_id('tempdb..#FindNegativeCharIndexRecords') is not null
drop table #FindNegativeCharIndexRecords

select DISTINCT PAT_ENC_CSN_ID, dx_comment_1
INTO #FindNegativeCharIndexRecords
from #FindNegativeCharIndex
where [CharIndex] < 0	
	OR CharIndex2 < 0	
	OR CharIndex3 < 0
	OR CharIndex4 < 0


-- get list of [PAT_ENC_CSN_ID] that are already in [HCC_Post_Encounter_WQ_CareConnectExport_TruncatedData]
-- don't want to have duplicate records
if object_id('tempdb..#PAT_ENC_CSN_ID') is not null
drop table #PAT_ENC_CSN_ID

select distinct PAT_ENC_CSN_ID,dx_comment_1
into #PAT_ENC_CSN_ID
from [HCC_Post_Encounter_WQ_CareConnectExport_TruncatedData]


INSERT INTO [Reporting].[dbo].[HCC_Post_Encounter_WQ_CareConnectExport_TruncatedData]([PAT_ENC_CSN_ID],[TAR_ID],[PAT_MRN_ID],[PAT_NAME],[DATE_OF_BIRTH],[WORKQUEUE_NAME],[PAYOR_NAME],[WQ_ENTRY_DATE],[WQ_EXIT_DATE],[CHARGE_MESSAGES],[ENTRY_ACT_HX],[ENTRY_ACT_USER],[REVIEW_ACT_HX],[REVIEW_ACT_USER],[DEFER_ACT_HX],[DEFER_ACT_USER],[REENTRY_ACT_HX],[REENTRY_ACT_USER],[RESUBMIT_ACT_HX],[RESUBMIT_ACT_USER],[DX_COMMENT_1])
select W.[PAT_ENC_CSN_ID]
      ,[TAR_ID]
      ,[PAT_MRN_ID]
      ,[PAT_NAME]
      ,[DATE_OF_BIRTH]
      ,[WORKQUEUE_NAME]
      ,[PAYOR_NAME]
      ,[WQ_ENTRY_DATE]
      ,[WQ_EXIT_DATE]
      ,[CHARGE_MESSAGES]
      ,[ENTRY_ACT_HX]
      ,[ENTRY_ACT_USER]
      ,[REVIEW_ACT_HX]
      ,[REVIEW_ACT_USER]
      ,[DEFER_ACT_HX]
      ,[DEFER_ACT_USER]
      ,[REENTRY_ACT_HX]
      ,[REENTRY_ACT_USER]
      ,[RESUBMIT_ACT_HX]
      ,[RESUBMIT_ACT_USER]
      ,W.[DX_COMMENT_1]
from [dbo].[HCC_Post_Encounter_WQ_CareConnectExport] w
	JOIN #FindNegativeCharIndexRecords F on W.PAT_ENC_CSN_ID = F.PAT_ENC_CSN_ID
								and W.dx_comment_1 = F.dx_comment_1
	LEFT JOIN #PAT_ENC_CSN_ID P on W.PAT_ENC_CSN_ID = P.PAT_ENC_CSN_ID
								and W.dx_comment_1 = P.dx_comment_1
where P.PAT_ENC_CSN_ID IS NULL

-- delete records from CareConnectExport table
-- don't want to mess up process when inserting into #Dx_spilt
DELETE w 
-- select *
FROM [dbo].[HCC_Post_Encounter_WQ_CareConnectExport] w
	JOIN #FindNegativeCharIndexRecords F on w.PAT_ENC_CSN_ID = F.PAT_ENC_CSN_ID
								and W.dx_comment_1 = F.dx_comment_1

-- substring LineNumber field in order to get data before and after '=>'
if object_id('tempdb..#Dx_spilt') is not null
drop table #Dx_spilt

select w.*
	,RowID = x.ItemNumber
--y.*, 
,Dx_LineNumber = x.item
	,DxTransaction = ltrim(rtrim(x.item))
	, y.ItemNumber
	, y.Item
	-- start at the first [.  end at the last ] minus one character.  replace [ with blank so it's not included in results
	,Dx = replace(substring (y.item,charindex('[',y.item)+1,charindex(']',y.item)-charindex('[',y.item)),']','')
	,DxDesc = LTRIM(RTRIM(substring(y.item,charindex(' ',y.item),999)))
	,ChangeTypeVal = case 
				when y.item like '%[[]%' and y.ItemNumber = 1 then -1 --'Delete'
				when y.item like '%[[]%' and y.ItemNumber = 2 then 1 --'Add'
			else Null
			end
into #Dx_spilt
from [dbo].[HCC_Post_Encounter_WQ_CareConnectExport] w
	outer apply reporting.[dbo].[udf_DelimitedSplit8K] (w.dx_comment_1,'|') x-- this udf has an 8000 character limit
    outer apply reporting.[dbo].[udf_DelimitedSplit8K] (x.item,'=') y
where y.Item like '%[[]%'
order by pat_enc_csn_id, RowID, Y.ItemNumber

IF (select count(*) from #Dx_spilt) > 1
			BEGIN

					TRUNCATE TABLE HCCPostEncounterWQ_results

					-- results
					-- create table to only have the records i want
					INSERT INTO HCCPostEncounterWQ_results (PAT_ENC_CSN_ID,TAR_ID,PAT_MRN_ID,PAT_NAME,DATE_OF_BIRTH,WORKQUEUE_NAME,WQ_ENTRY_DATE,WQ_EXIT_DATE,CHARGE_MESSAGES,ENTRY_ACT_HX,ENTRY_ACT_USER,REVIEW_ACT_HX,REVIEW_ACT_USER,DEFER_ACT_HX,DEFER_ACT_USER,REENTRY_ACT_HX,REENTRY_ACT_USER,RESUBMIT_ACT_HX,RESUBMIT_ACT_USER,DX_COMMENT_1,DxDesc,ChangeType,ChangeValue)
					SELECT DISTINCT
						X.PAT_ENC_CSN_ID,
						TAR_ID,
						PAT_MRN_ID,
						PAT_NAME,
						DATE_OF_BIRTH,
						WORKQUEUE_NAME,
						WQ_ENTRY_DATE,
						WQ_EXIT_DATE,
						CHARGE_MESSAGES,
						ENTRY_ACT_HX,
						ENTRY_ACT_USER,
						REVIEW_ACT_HX,
						REVIEW_ACT_USER,
						DEFER_ACT_HX,
						DEFER_ACT_USER,
						REENTRY_ACT_HX,
						REENTRY_ACT_USER,
						RESUBMIT_ACT_HX,
						RESUBMIT_ACT_USER,
						DX_COMMENT_1,
						--X.Dx,
						x.DxDesc,
						ChangeType = case
									when sum(ChangeTypeVal) < 0 then 'Delete' 
									when sum(ChangeTypeVal) > 0 then 'Add' 
									else '<no change>'
									end,
						ChangeValue = CASE
											WHEN sum(ChangeTypeVal) > 0 AND Dx_LineNumber NOT LIKE '%<blank>%' THEN substring (Dx_LineNumber,CHARINDEX(':',Dx_LineNumber)+1,LEN(Dx_LineNumber))
											ELSE ''
										END
					FROM #Dx_spilt x
						JOIN (SELECT PAT_ENC_CSN_ID, Dx
								FROM #Dx_spilt T 
								GROUP BY PAT_ENC_CSN_ID, Dx
								HAVING COUNT(*) = 1) Y on X.PAT_ENC_CSN_ID = Y.PAT_ENC_CSN_ID
														AND X.Dx = Y.Dx
					GROUP BY X.PAT_ENC_CSN_ID,
						TAR_ID,
						PAT_MRN_ID,
						PAT_NAME,
						DATE_OF_BIRTH,
						WORKQUEUE_NAME,
						WQ_ENTRY_DATE,
						WQ_EXIT_DATE,
						CHARGE_MESSAGES,
						ENTRY_ACT_HX,
						ENTRY_ACT_USER,
						REVIEW_ACT_HX,
						REVIEW_ACT_USER,
						DEFER_ACT_HX,
						DEFER_ACT_USER,
						REENTRY_ACT_HX,
						REENTRY_ACT_USER,
						RESUBMIT_ACT_HX,
						RESUBMIT_ACT_USER,
						DX_COMMENT_1,
						--X.Dx,
						x.DxDesc,
						Dx_LineNumber
					order by PAT_ENC_CSN_ID

					-- delete records that are CPT codes
					DELETE H
					from HCCPostEncounterWQ_results H
					where dxdesc like '%(CPT®)%'
						OR dxdesc like '%(CPTÂ®)%'
			END

--select *
--from #Results_Staging R
--where r.pat_enc_csn_id = '465913997' -- Type 2 diabetes mellitus without complications [E11.9]: Delete; Type 2 diabetes mellitus with diabetic chronic kidney disease [E11.22]: Add or change??
--where r.pat_enc_csn_id ='471473693' -- Malignant melanoma of right upper limb, including shoulder [C43.61]: Delete; Type 2 diabetes mellitus with diabetic neuropathy, unspecified [E11.40]: Add
--where r.pat_enc_csn_id ='463853182' -- Encounter for general adult medical examination with abnormal findings [Z00.01]: Add




/* Old results table
INSERT INTO HCCPostEncounterWQ_results
SELECT DISTINCT
	PAT_ENC_CSN_ID,
	TAR_ID,
	PAT_MRN_ID,
	PAT_NAME,
	DATE_OF_BIRTH,
	WORKQUEUE_NAME,
	WQ_ENTRY_DATE,
	WQ_EXIT_DATE,
	CHARGE_MESSAGES,
	ENTRY_ACT_HX,
	ENTRY_ACT_USER,
	REVIEW_ACT_HX,
	REVIEW_ACT_USER,
	DEFER_ACT_HX,
	DEFER_ACT_USER,
	REENTRY_ACT_HX,
	REENTRY_ACT_USER,
	RESUBMIT_ACT_HX,
	RESUBMIT_ACT_USER,
	DX_COMMENT_1,
	--Dx,
	DxDesc = STUFF(( SELECT   '|'
                                 + CAST(Y.DxDesc AS VARCHAR (4000))
								FROM #Results_Staging Y
									WHERE  X.PAT_ENC_CSN_ID = Y.PAT_ENC_CSN_ID
									ORDER BY X.PAT_ENC_CSN_ID
                                FOR
                                XML PATH('')
                                ), 1, 1, '')
FROM #Results_Staging x
--where PAT_ENC_CSN_ID = '463853182'--'477404704'
order by PAT_ENC_CSN_ID
*/

GO


