USE [Reporting]
GO

/****** Object:  StoredProcedure [dbo].[EmployedPCPSpecialtyVisitUsageReport]    Script Date: 10/13/2025 9:14:43 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO





-- ===================================================================================
-- Author:		Laura R
-- Create date: 04/02/2025
-- Description:	
--	Members of Excellus & MVP across all LOBs (Commercial, Medicaid, Medicare Advantage) 
-- who are attributed to a GRIPA Primary Care Provider and have had an Office visit IN or OUT of network

--20250716	Laura	Part of ticket 20998 Kelly wants time period of report to be January - June 2025.  Manually assigning dates to parameters
-- 20250731 Laura	Reverting @MSR_ENDDATE back to case statement
--					Creating @POP_RELATIONSHIPDATE variable to determine date when looking at Patient_Other_provider table in creation of #pop_stg table
-- 20250805 Laura	Adding code to determine in/out of network based on billing info
-- 2025-09-29 LR: Part of ticket 19956, bringing provider specialty code from claims.  However, will still be using provider specialty in order to delete information from #Report_Staging
--		Provider specialty codes come from claims and do not necessarily match CMS specialty codes.
-- ===================================================================================

CREATE PROCEDURE [dbo].[EmployedPCPSpecialtyVisitUsageReport]
AS
BEGIN

	DECLARE @MSR_STARTDATE DATETIME
	DECLARE @MSR_STARTDATE_Claims DATETIME
	DECLARE @MSR_ENDDATE DATETIME
	DECLARE @MSR_START_YRMO VARCHAR(6)
	DECLARE @MSR_START_Claims_YRMO VARCHAR(6)
	DECLARE @MSR_END_YRMO VARCHAR(6)
	DECLARE @POP_RELATIONSHIPDATE VARCHAR(8)

	-- create case statement to determine values of variables
	-- report will be run every quarter but not the end of the traditional quarter.  Need to wait a month for previous months' claims to be received from payers
	-- create case statement to determine values of variables
	-- report will be run every quarter but not the end of the traditional quarter.  Need to wait a month for previous months' claims to be received from payers
	SET @MSR_ENDDATE = 
					CASE
							WHEN MONTH(GETDATE()) = 5 THEN '03/31/' + CONVERT(VARCHAR(4),YEAR(GETDATE()))
							WHEN MONTH(GETDATE()) = 8 THEN '06/30/' + CONVERT(VARCHAR(4),YEAR(GETDATE()))
							WHEN MONTH(GETDATE()) = 11 THEN '10/31/' + CONVERT(VARCHAR(4),YEAR(GETDATE()))
							WHEN MONTH(GETDATE()) = 2 THEN '12/31/' + CONVERT(VARCHAR(4),YEAR(GETDATE())-1) -- when running data in Feb, need to get information from previous year
							ELSE DATEADD(d, -1, DATEADD(m, DATEDIFF(m, 0, GETDATE()) + 1, 0))
						END 

	SET @POP_RELATIONSHIPDATE = 
					CASE
							WHEN MONTH(GETDATE()) = 2 THEN  CONVERT(VARCHAR(4),YEAR(GETDATE())-1) + '1231'-- when running data in Feb, need to get information from previous year
							ELSE  CONVERT(VARCHAR(4),YEAR(GETDATE())) + '1231'
						END 
		
	-- create start date based on value of end date
	-- value will be 3 months previous to the end date value for providers
	SET @MSR_STARTDATE =  DATEADD(mm, DATEDIFF(mm, 0, @MSR_ENDDATE) - 3, 0)
	-- value will be rolling 12 months for claims
	SET @MSR_STARTDATE_Claims = DATEADD(mm, DATEDIFF(mm, 0, @MSR_ENDDATE) - 11, 0) 	
	SET @MSR_START_YRMO = CONVERT(VARCHAR(6),@MSR_STARTDATE,112)	
	SET @MSR_START_Claims_YRMO = CONVERT(VARCHAR(6),@MSR_STARTDATE_Claims,112)
	SET @MSR_END_YRMO = CONVERT(VARCHAR(6),@MSR_ENDDATE,112)

	--select @MSR_STARTDATE_Claims, @MSR_ENDDATE

IF OBJECT_ID('TEMPDB.DBO.#GRIPA_EMP') IS NOT NULL 
DROP TABLE #GRIPA_EMP


----/*********** Gathering provider information from vAlign ***********************/
----/*20240625 LR */
------ Ignore the 2 years all together and just use valign for active/inactive during timeframe of report.  i.e. if a provider termed on 2/2/24, they should be in network for reporting period 1/1/24 through 4/30/24, 
------ unless you can make specific to their actual term date…(in before 2/2, out after 2/3)
SELECT DISTINCT Q.NPI,
	Q.MED_PLAN,
	Q.Termination_Date,
	GROUPPRACTICENAME = ISNULL(Q.GROUPPRACTICENAME,''), 
	[NAME] = UPPER(Q.LASTNAME+','+Q.FIRSTNAME) , 
	Q.SPECIALTYNAME,
	EMPLOYEE=CASE WHEN Q.HOSPITAL_EMPLOYEE IS NOT NULL THEN 'EMPLOYED' ELSE 'GRIPA-PRIVATE' END, 
	Q.PROVTYPE, 
	Q.[STATUS], 
	Q.INACTIVEDATE
INTO #GRIPA_EMP
FROM (
		SELECT DISTINCT C.NPI,MED_PLAN,C.FIRSTNAME,C.LASTNAME,GS.SPECIALTYNAME,GROUPPRACTICENAME,DEGREE,PROVTYPE,C.STATUS,INACTIVEDATE,
			Termination_Date,HOSPITAL_EMPLOYEE,
			ROW_ID=ROW_NUMBER() OVER(PARTITION BY C.NPI ORDER BY C.STATUS,Termination_Date DESC,INACTIVEDATE DESC) 
		FROM [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_Provider] C
			JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_MedPlan] M ON M.CONTACTID=C.CONTACTID 
							and med_plan like 'gripa%' 
			LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_SPECIALTY] GS ON GS.CONTACTID=C.CONTACTID AND PRIMARYSPEC='Yes'
			LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_OfficeGroupPractice] E ON E.CONTACTID=C.CONTACTID 
					AND E.PrimaryOffice='Yes' 
					--AND E.ProviderInOGP='ACTIVE'
		--WHERE C.[Status] = 'Active'
		) Q
WHERE Q.NPI IS NOT NULL 
	AND ROW_ID=1 

---- insert independent APPs into #GRIPA_EMP table
INSERT INTO #GRIPA_EMP(NPI,MED_PLAN,Termination_Date,GROUPPRACTICENAME,[NAME],SPECIALTYNAME,EMPLOYEE,PROVTYPE,[STATUS],INACTIVEDATE)
SELECT DISTINCT  C.NPI,
		MED_PLAN = 'GRIPA',
		Termination_Date,
		GROUPPRACTICENAME,
		[NAME] = UPPER(C.FIRSTNAME+','+C.LASTNAME), 
		GS.SPECIALTYNAME,
		EMPLOYEE=CASE WHEN HOSPITAL_EMPLOYEE IS NOT NULL THEN 'EMPLOYED' ELSE 'GRIPA-PRIVATE' END, 
		--DEGREE,
		PROVTYPE,
		C.[STATUS],
		INACTIVEDATE
FROM [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_Provider] C
	JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_MedPlan] M ON M.CONTACTID=C.CONTACTID 
					and med_plan like 'gripa%' --and Termination_Date='12/31/2399'
	LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_SPECIALTY] GS ON GS.CONTACTID=C.CONTACTID AND PRIMARYSPEC='Yes'
	LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_OfficeGroupPractice] E ON E.CONTACTID=C.CONTACTID 
			AND E.PrimaryOffice='Yes' 
where Med_plan in ('GRIPA','GRIPA Midlevel') -- must have med plans of GRIPA & GRIPA Midlevel
		AND Termination_Date = '2399-12-31 00:00:00.000' -- both med_plans must have a termination date of 12/31/2399
GROUP BY  C.NPI,
		Termination_Date,
		GROUPPRACTICENAME,
		 UPPER(C.FIRSTNAME+','+C.LASTNAME), 
		GS.SPECIALTYNAME,
		CASE WHEN HOSPITAL_EMPLOYEE IS NOT NULL THEN 'EMPLOYED' ELSE 'GRIPA-PRIVATE' END, 
		PROVTYPE,
		C.[STATUS],
		INACTIVEDATE
having count(distinct Med_plan) = 2


-- there are some providers won't have a GRIPA medplan
-- in order for the easier maintenance, Jen H will put the provider in vAlign (NPI & primary specialty, first & last name) but will mark provider as inactive
INSERT INTO #GRIPA_EMP(NPI,MED_PLAN,Termination_Date,GROUPPRACTICENAME,[NAME],SPECIALTYNAME,EMPLOYEE,PROVTYPE,[STATUS],INACTIVEDATE)
SELECT DISTINCT  C.NPI,
		MED_PLAN = 'GRIPA',
		Termination_Date,
		GROUPPRACTICENAME = '',
		[NAME] = UPPER(C.FIRSTNAME+','+C.LASTNAME), 
		GS.SPECIALTYNAME,
		EMPLOYEE=CASE WHEN HOSPITAL_EMPLOYEE IS NOT NULL THEN 'EMPLOYED' ELSE 'GRIPA-PRIVATE' END, 
		PROVTYPE,
		C.[STATUS],
		INACTIVEDATE
FROM [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_Provider] C
	LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_MedPlan] M ON M.CONTACTID=C.CONTACTID 
					--and med_plan like 'gripa%' 
	LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_SPECIALTY] GS ON GS.CONTACTID=C.CONTACTID AND PRIMARYSPEC='Yes'
	LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_OfficeGroupPractice] E ON E.CONTACTID=C.CONTACTID 
			--AND E.PrimaryOffice='Yes' 
where C.[Status] = 'Inactive'
GROUP BY  C.NPI,
		Termination_Date,
		GROUPPRACTICENAME,
		 UPPER(C.FIRSTNAME+','+C.LASTNAME), 
		GS.SPECIALTYNAME,
		CASE WHEN HOSPITAL_EMPLOYEE IS NOT NULL THEN 'EMPLOYED' ELSE 'GRIPA-PRIVATE' END, 
		PROVTYPE,
		C.[STATUS],
		INACTIVEDATE


CREATE INDEX NIDX_GE ON #GRIPA_EMP(NPI)


-- export from MSOW
IF OBJECT_ID('TEMPDB.DBO.#RRH_EMP') IS NOT NULL DROP TABLE #RRH_EMP

CREATE TABLE [dbo].[#RRH_EMP](
	[NAME] [varchar](501) NULL,
	[NPI] [varchar](250) NULL,
	[EMPLOYED] [varchar](250) NULL,
	[DentalStaff2023] [varchar](2) NULL,
	[Hospital Employee] [varchar](2) NULL,
	[PRIMARY SPECIALTY] [varchar](250) NULL,
	[TRANSLATED DEGREE] [varchar](250) NULL,
	[DEGREE CATEGORY] [varchar](250) NULL,
	[PRIMARY PRACTICE NAME] [varchar](500) NULL
)

INSERT INTO #RRH_EMP
SELECT NAME=UPPER([PROVIDER LAST NAME]+','+[PROVIDER FIRST NAME]),
	NPI,
	EMPLOYED,
	DentalStaff2023,
	[Hospital Employee],
	[PRIMARY SPECIALTY],
	[TRANSLATED DEGREE],
	[DEGREE CATEGORY],
	[PRIMARY PRACTICE NAME]
--INTO #RRH_EMP
FROM [GRIPA-DB-6].[Excellus_Extract].[dbo].[MMSW]


--- adding in-network facilities to #RRH_EMP
insert into #RRH_EMP([Name], NPI, Employed, DentalStaff2023,[Hospital Employee], [PRIMARY SPECIALTY],[PRIMARY PRACTICE NAME ])
select [FacilityName] = Facility, NPI, Employed = 'Y', DentalStaff2023 = 'Y',[Hospital Employee] = 'Y',[PRIMARYSPECIALTY] = 'Facility',[PRIMARYPRACTICENAME] = Facility
--from [GRIPA-DB-6].[Excellus_Extract].[dbo].InNetworkFacilities
FROM Reporting.dbo.RRHLeakage_Facilities
WHERE IN_OUT_Network = 'In Network'

-- get information for specialty providers from NPI registry
IF OBJECT_ID('TEMPDB.DBO.#NPI_SP') IS NOT NULL DROP TABLE #NPI_SP
SELECT NPI,NAME,ORG_NAME,SPECIALTY
INTO #NPI_SP
FROM (
		SELECT NPI,
		[Name] = CASE WHEN LEN([Provider Last Name (Legal Name)])>1 OR LEN([Provider First Name])>1
							THEN UPPER([Provider Last Name (Legal Name)]+','+[Provider First Name]) 
					ELSE [Provider Organization Name (Legal Business Name)] 
				END,
		ORG_NAME = ISNULL([Provider Organization Name (Legal Business Name)],'') , 
		SPECIALTY = SUBSTRING(PROVIDER_TAXONOMY_DESCRIPTION,CHARINDEX('/',PROVIDER_TAXONOMY_DESCRIPTION,1)+1,100) ,
		ROW_ID=ROW_NUMBER() OVER(PARTITION BY NPI ORDER BY S.MEDICARE_SPECIALTY_CODE DESC) 
		FROM [gripa-db-10].[cds_staging].[dbo].[NPI_REGISTRY] N
			LEFT JOIN [gripa-db-10].[cds_staging].[DBO].[NPI_TAXONOMY_SPECIALTY_CWT] S ON N.[Healthcare Provider Taxonomy Code_1]=S.PROVIDER_TAXONOMY_CODE
		) A
WHERE ROW_ID=1

--select *
--from #gripa_emp
--where [name] like '%MORSE,DIANE%'

------- Members of Excellus, MVP all LOBS attributed to Employed Physicians who has visited any Employed provider
IF OBJECT_ID('TEMPDB..#POP_STG') IS NOT NULL
DROP TABLE #POP_STG
SELECT PATIENTID,
	CONTRACTNAME,
	LOB,
	PCP,
	PCP_SPECIALTY,
	PRACTICE_GROUP,
	NPI
INTO #POP_STG
FROM
(
		SELECT M.PATIENTID,
		CONTRACTNAME,
		LOB,
		PCP= UPPER(PROV.LASTNAME+','+PROV.FIRSTNAME),
		PCP_SPECIALTY=UPPER(S.SpecialtyName),
		PRACTICE_GROUP=G.GroupName,
		PROV.NPI,
		ROW_ID=ROW_NUMBER() OVER(PARTITION BY M.PATIENTID ORDER BY M.YEARMO DESC)
		-- select prov.*
		FROM [GRIPA-DB-6].CLAIMS_DM.DBO.MEMBMTHSFACT M 
		JOIN [GRIPA-DB-6].CLAIMS_DM.DBO.DIM_CONTRACT_INSURANCE C ON M.CONTRACTINSURANCEKEY=C.CONTRACTINSURANCEKEY
		--JOIN [GRIPA-DB-6].[Claims_DM].[dbo].[Dim_Patient] P ON P.PATIENTID=M.PATIENTID
		JOIN [GRIPA-DB-6].QUALITY_OF_CARE_DM.dbo.PATIENT_OTHER_PROVIDER PAT ON M.PATIENTID = PAT.PATIENTID 
																	AND PAT.RELATIONSHIPTYPE='PRIMARY' 
																	--AND PAT.ISROWCURRENT=1
																	AND @POP_RELATIONSHIPDATE BETWEEN RELATIONSHIPSTARTDATE AND RELATIONSHIPENDDATE
		JOIN [GRIPA-DB-6].QUALITY_OF_CARE_DM.dbo.DIM_PROVIDER PROV ON PAT.PROVIDERKEY=PROV.PROVIDERKEY AND PROV.ISROWCURRENT=1 
		JOIN [GRIPA-DB-6].QUALITY_OF_CARE_DM.dbo.DIM_SPECIALTY S ON PROV.SPECIALTYKEY = S.SPECIALTYKEY
		JOIN [GRIPA-DB-6].QUALITY_OF_CARE_DM.dbo.DIM_GROUP G ON PROV.GROUPKEY = G.GROUPKEY
		--JOIN #RRH_EMP RE ON PROV.NPI=RE.NPI AND RE.EMPLOYED='Y'
		WHERE-- CONTRACTNAME='RGHS'
			CONTRACTNAME IN ('EXCELLUS ACQA','MVP') 
		--AND ISCONTRACTED=1
			AND M.YEARMO BETWEEN @MSR_START_Claims_YRMO AND @MSR_END_YRMO
) A
WHERE ROW_ID=1


---- get all ED visits for members in #POP_STG table for 2024 claims
if object_id('tempdb..##Office_VISITS') is not null
DROP TABLE ##Office_VISITS

SELECT  C.ClaimIDPayer
		,C.PATIENTID
       ,PROVIDERFULLNAME
	   ,P.ClaimsProviderID
	   ,Provider_Specialty_Code = rfd.spec_Code
	   ,Provider_Specialty = rfd.spec_desc
       ,b.DiagnosisCodeDescription
       ,Office_Visit_DATE = D1.DATE
	   ,C.ProcedureCode
	   ,DP.[ProcedureCodeDescription]
	   ,PlaceOfServiceCodeDescription
	   ,Bill_Prov_Desc = cast(null as varchar(500))
	   ,Bill_Prov_NPI = cast(null as varchar(500))
INTO    ##Office_VISITS
 --select top 100 *
FROM    CLAIMS_DM..CLAIMSFACT C with (nolock) 
        JOIN CLAIMS_DM..DIM_CLAIMSPROVIDER P  with (nolock) ON C.RENDERINGPROVIDERKEY = DIMCLAIMSPROVIDERKEY
        JOIN CLAIMS_DM..DIM_DATE D1  with (nolock) ON FROMDATEKEY = D1.DATEKEY  
		--- 20240531 part of ticket 16512 need to join to this table so can get PlaceOfServiceCode
		JOIN CLAIMS_DM.DBO.Dim_PlaceOfService POS  with (nolock)
                        ON POS.PlaceOfServiceKey = c.PlaceOfServiceKey
        --JOIN CLAIMS_DM..DIM_DATE D2 ON TODATEKEY = D2.DATEKEY
        LEFT JOIN	Claims_DM..v_BridgeDiagnosis_to_DimDiagnosis B  ON B.DiagnosisBridgeKey = c.DiagnosisBridgeKey
														AND b.DiagnosisOrder = 1
		JOIN Claims_DM.dbo.Dim_HCG hcg on c.HCGKey = hcg.HCGKey
		JOIN #POP_STG PP ON PP.PATIENTID = C.PATIENTID 
		LEFT JOIN [Claims_DM].[dbo].[Dim_Procedure] DP on C.ProcedureKey = DP.ProcedureKey
		JOIN Claims_dm.dbo.rft_SPEC_DES rfd on c.RenderingAttSpec = rfd.spec_code
WHERE   HCG.CLAIMTYPE<>'RX'  -- no pharmacy claims
	--and C.PatientID = 14003562
	AND D1.[Date] BETWEEN @MSR_STARTDATE_Claims AND @MSR_ENDDATE-- had a Office visit within reporting period
	AND C.PatientID <> -1 -- no unknown patients
	AND C.ProcedureCode IN ( -- new patient
							'99201','99202','99203','99204','99205',
							-- established patients
							'99211','99212','99213','99214','99215'
							)
	AND C.RenderingAttSpec NOT IN ('001','008','011','037','038') 
GROUP BY C.ClaimIDPayer
		,C.PATIENTID
       ,PROVIDERFULLNAME
	   ,P.ClaimsProviderID
       ,D1.DATE
       ,b.DiagnosisCodeDescription
	   --,COALESCE(L.PayerAcuityIndicator, MA.PayerAcuityIndicator, '')
	   ,C.ProcedureCode
	   ,DP.[ProcedureCodeDescription]
	   ,PlaceOfServiceCodeDescription
	   ,rfd.spec_desc
	   ,rfd.spec_Code
HAVING  SUM(VISITCOUNTER) >= 1 OR SUM(ServiceCounter)>=1


----- get billing information so Jen H can fill in more information
if object_id('tempdb..#Billing_Info') is not null
DROP TABLE #Billing_Info

select DISTINCT O.*, 
ClaimsExtract_PatientID = C.PatientID, 
ClaimsExtract_ClaimIDPayer = C.claim_ID_Payor, 
ClaimsExtract_FromDate = C.from_date, 
ClaimsExtract_BillProvDesc = C.Bill_Prov_Desc, 
ClaimsExtract_BillProvNPI = C.Bill_Prov_NPI
INTO #Billing_Info
from ##Office_VISITS O 
	JOIN reporting.dbo.RRH_Leakage_CLAIMS_EXTRACT C on O.PatientID = C.PatientID
															AND O.Office_Visit_DATE = C.from_date
															AND O.ClaimIDPayer = C.claim_ID_Payor
order by Office_Visit_DATE

CREATE INDEX NIDX_BillingInfo ON #Billing_Info(ClaimIDPayer)

UPDATE O SET Bill_Prov_Desc = C.ClaimsExtract_BillProvDesc, Bill_Prov_NPI = C.ClaimsExtract_BillProvNPI
from ##Office_VISITS O 
	JOIN #Billing_Info C on O.PatientID = C.ClaimsExtract_PatientID
							AND O.Office_Visit_DATE = C.ClaimsExtract_FromDate
							AND O.ClaimIDPayer = C.ClaimsExtract_ClaimIDPayer


---- create staging table in order to rollup some fields
if object_id('tempdb..#Report_Staging') is not null
DROP TABLE #Report_Staging

SELECT DISTINCT 
	E.PATIENTID 
	,NPI = ClaimsProviderID
    ,PROVIDERFULLNAME = MAX(CASE 
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME <> '' THEN GE2.[NAME]						-- vAlign
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='Y' THEN RE.NAME									-- MSOW		
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='N' THEN RE.NAME									-- MSOW									
								WHEN SP.NPI IS NOT NULL THEN SP.NAME														-- NPI Registry
								ELSE E.PROVIDERFULLNAME																		-- Claims
							END)
	,Provider_Specialty_Code
	/* Looking for certain places of service first
	Per conversation with Jen H
	I am thinking that we should change for all urgent care and independent clinics, no matter what the specialty is....
	since most are either Emergency med or work in a pcp office and work part time in urgent care
	*/	
	,Provider_Specialty = MAX(CASE 
								WHEN E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription	-- Claims																									
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME <> '' THEN GE2.SPECIALTYNAME														-- vAlign
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='Y' THEN RE.[PRIMARY SPECIALTY]							-- MSOW
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='N' THEN RE.[PRIMARY SPECIALTY]							-- MSOW
								WHEN SP.NPI IS NOT NULL  AND SP.SPECIALTY IS NOT NULL THEN SP.SPECIALTY							-- NPI Registry	
								WHEN E.Provider_Specialty IN ('OTHER SPECIALTY CODE','PHYSICIAN ASSISTANT','NURSE PRACTITIONER')  AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME IS NULL AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription
								ELSE E.Provider_Specialty 
							END)
	,Provider_Specialty_Source = MAX(CASE  
								WHEN E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN 'Claims'
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME <> '' THEN 'vAlign'													
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='Y' THEN 'MSOW'						
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='N' THEN 'MSOW'						 
								WHEN SP.NPI IS NOT NULL  AND SP.SPECIALTY IS NOT NULL THEN 'NPI Registry'						
								WHEN E.Provider_Specialty IN ('OTHER SPECIALTY CODE','PHYSICIAN ASSISTANT','NURSE PRACTITIONER') AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN 'Claims'
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME IS NULL AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription
								ELSE 'Claims'
							END)
    ,DiagnosisCodeDescription
    ,Office_Visit_DATE 
	,ProcedureCode
	,EMPLOYEE_FLAG = ISNULL(GE.Employee,'Non-GRIPA')
	,Attributed_Provider = P.PCP
	,Attributed_Provider_Specialty = P.PCP_SPECIALTY
	,Attributed_Provider_Practice_Group = P.PRACTICE_GROUP
	,PlaceOfServiceCodeDescription
	,Bill_Prov_Desc
	,Bill_Prov_NPI
	,IN_OUT_Network = MIN(CASE
								WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) AND GE2.[Status] = 'Active' THEN 'IN NETWORK'
								WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) 
													AND GE2.[Status] = 'Inactive' 
													AND convert(date,GE2.InactiveDate) between @MSR_STARTDATE and @MSR_ENDDATE THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								--- billing info								
								WHEN RE2.DentalStaff2023 = 'Y'  AND RE2.Employed = 'Y' AND RE2.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE2.DentalStaff2023 = 'Y'  AND RE2.Employed = 'N' AND RE2.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE2.DentalStaff2023 = 'N'  AND RE2.Employed = 'Y' AND RE2.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE2.DentalStaff2023 = 'Y'  AND RE2.Employed = 'Y' AND RE2.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE2.DentalStaff2023 = 'Y'  AND RE2.Employed = 'N' AND RE2.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								WHEN RE2.DentalStaff2023 = 'N'  AND RE2.Employed = 'N' AND RE2.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								ELSE 'OUT OF NETWORK'
							END)
INTO #Report_Staging
FROM ##Office_VISITS E
	JOIN #POP_STG P on E.PatientID = P.PatientID
	LEFT JOIN #GRIPA_EMP GE on P.NPI = GE.NPI  -- get PCPs attributed to members
	LEFT JOIN #GRIPA_EMP GE2 on GE2.NPI = E.ClaimsProviderID  -- get providers who performed the service
	LEFT JOIN #RRH_EMP RE ON RE.NPI = E.ClaimsProviderID 
	LEFT JOIN #RRH_EMP RE2 ON RE2.NPI = E.Bill_Prov_NPI -- get billing NPI 
	LEFT JOIN #NPI_SP SP on SP.NPI = E.ClaimsProviderID
--where E.patientID = 11471524
--11625015--13112271--13919378--12675940--13734110--11469318--11728635
-- observation stay
--where E.PatientID = 14003562
--where E.PatientID <= 12157039
--where E.PatientID between 12157040 and 13618605
--where E.PatientID > 13618605
GROUP BY E.PATIENTID
	,DiagnosisCodeDescription
    ,Office_Visit_DATE 
	,ProcedureCode
	,ISNULL(GE.Employee,'Non-GRIPA')
	,P.PCP
	,ClaimsProviderID
	,Provider_Specialty_Code
	,P.PCP_SPECIALTY
	,P.PRACTICE_GROUP
	,PlaceOfServiceCodeDescription
	,Bill_Prov_Desc
	,Bill_Prov_NPI
ORDER BY E.PatientID, Office_Visit_DATE

-- Set any record with Employee_Flag = 'NON-GRIPA' to have an unknown practice
-- these are for members who have a non-GRIPA provider attributed to them
UPDATE R SET Attributed_Provider_Practice_Group = 'UNKNOWN'
from #Report_Staging R 
where EMPLOYEE_FLAG = 'Non-GRIPA'

--- Per discussions with Jen H & Kelly, remove preadmission visits from report
DELETE R
from #Report_Staging R 
where DiagnosisCodeDescription like '%Z01.818%'


--- Exclude PCPs
DELETE R
FROM #Report_Staging R 
WHERE Provider_Specialty IN ('GENERAL PRACTICE','FAMILY PRACTICE','FAMILY MEDICINE','INTERNAL MEDICINE','PEDIATRIC MEDICINE','GERIATRIC MEDICINE','PEDIATRICS') 


------- Data validation report
--if object_id('tempdb..##Report_Staging2') is not null
--DROP TABLE ##Report_Staging2

TRUNCATE TABLE RRHLeakage_OfficeVisits

INSERT INTO RRHLeakage_OfficeVisits(PATIENTID,NPI,PROVIDERFULLNAME,Provider_Specialty,Provider_Specialty_Source,DiagnosisCodeDescription,PlaceOfServiceCodeDescription,Office_Visit_DATE,ProcedureCode,EMPLOYEE_FLAG,Attributed_Provider,Attributed_Provider_Specialty,Attributed_Provider_Practice_Group,Bill_Prov_Desc,Bill_Prov_NPI,IN_OUT_Network)
SELECT DISTINCT PATIENTID 
	,NPI
    ,PROVIDERFULLNAME
	,Provider_Specialty = CASE 
								WHEN ISNULL(Provider_Specialty,'') IN ('Nurse Practitioner - Acute Care','Nurse Practitioner, Acute Care') THEN 'Acute Care'
								WHEN ISNULL(Provider_Specialty,'') IN ('Anesthesiology, Addiction Medicine','Anesthesiology/Addiction Medicine','Family Medicine, Addiction Medicine') THEN 'Addiction Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Allergy and Immunology/Allergy') THEN 'Allergy'
								WHEN ISNULL(Provider_Specialty,'') IN ('Allergy and Immunology','Allergy and Immunology/Clinical & Laboratory Immunology','Internal Medicine, Allergy & Immunology') THEN 'Allergy/Immunology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Anesthesiology/Pediatric Anesthesiology','Nurse Anesthetist, Certified Registered') THEN 'Anesthesiology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Advanced Heart Failure and Transplant Cardiology','CARDIOLOGY, ADVANCED HF  & TRANSPLANT') THEN 'Cardiology, Advanced HF & Transplant'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Interventional Cardiology') THEN 'Cardiology, Interventional'
								WHEN ISNULL(Provider_Specialty,'') IN ('Cardiology', 'cardiovascular disease','Internal Medicine, Cardiovascular Disease') THEN 'Cardiovascular Disease'
								WHEN ISNULL(Provider_Specialty,'') IN ('Chiropractor','Chiropractor, Independent Medical Examiner','Chiropractor, Neurology','Chiropractor, Nutrition','Chiropractor, Orthopedic','Chiropractor, Pediatric Chiropractor','Chiropractor, Rehabilitation','Chiropractor, Sports Physician') THEN 'Chiropractic'
								WHEN ISNULL(Provider_Specialty,'') IN ('CLINICAL PSYCHOLOGIST','Psychologist','Psychologist - Clinical','Psychologist, Clinical') THEN 'Clinical Psychology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Clinic/Center, Multi-Specialty  ','Clinic/Center, Rural Health','Facilty', 'Facility','Federally Qualified Health Center (FQHC)') THEN 'Clinic/Center/Facility'
								WHEN ISNULL(Provider_Specialty,'') IN ('Nurse Practitioner, Community Health') THEN 'Community Health'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Critical Care Medicine','Nurse Practitioner, Critical Care Medicine','Psychiatry & Neurology/Neurocritical Care') THEN 'Critical Care'
								WHEN ISNULL(Provider_Specialty,'') IN ('Dentist','Ophthalmology, Dental Providers/Dentist') THEN 'DENTISTRY - GENERAL'
								WHEN ISNULL(Provider_Specialty,'') IN ('Allopathic & Osteopathic Physicians, Dermatology, MOHS-Micrographic Surgery','Dermatology, Procedural Dermatology') THEN 'Dermatology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Dermatology, Dermapathology','Pathology, Dermapathology') THEN 'Dermatopathology'
								WHEN ISNULL(Provider_Specialty,'') IN ('RADIOLOGY','Radiology, Diagnostic Radiology') THEN 'Diagnostic Radiology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Clinical Cardiatric Electrophysiology') THEN 'Electrophysiology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Emergency Medicine, Emergency Medical Services', 'Emergency Medicine, Medical Toxicology','Emergency Medicine, Sports Medicine') THEN 'Emergency Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Endocrinology, Diabetes & Metabolism') THEN 'Endocrinology'								
								--WHEN ISNULL(Provider_Specialty,'') IN () THEN 'Facility'
								WHEN ISNULL(Provider_Specialty,'') IN ('Family Practice', 'Family Medicine','Nurse Practitioner - Family','Nurse Practitioner, Family') THEN 'Family Medicine'
								--WHEN ISNULL(Provider_Specialty,'') IN ('Family Practice', 'Family Medicine','Nurse Practitioner - Family','Nurse Practitioner, Family') THEN 'Female Pelvic Medicine & Reconstructive Surgery'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Gastroenterology') THEN 'Gastroenterology'
								WHEN ISNULL(Provider_Specialty,'') IN ('General Acute Care Hospital','General Acute Care Hospital, Children','General Acute Care Hospital, Critical Access','General Acute Care Hospital/Rural') THEN 'General Acute Care Hospital'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery','Surgery - Surgery') THEN 'General Surgery'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Geriatric Medicine','Nurse Practitioner, Gerontology') THEN 'Geriatric Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Obstetrics & Gynecology, Gynecologic Oncology') THEN 'Gynecologic Oncology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Obstetrics & Gynecology, Gynecology') THEN 'Gynecology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Hematology') THEN 'Hematology'
								WHEN ISNULL(Provider_Specialty,'') IN ('HEMATOLOGY/ONCOLOGY', 'HEMATOLOGY AND ONCOLOGY','Internal Medicine, Hematology & Oncology') THEN 'Hematology and Oncology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Hospice and Palliative Medicine', 'Hospice and palliative care',' Psychiatry & Neurology, Hospice & Palliative Medicine','Surgery/Hospice and Palliative Medicine, Family Practice','Surgery/Hospice and Palliative Medicine, Internal Medicine',' Psychiatry & Neurology') THEN 'Hospice and Palliative Care'
								WHEN ISNULL(Provider_Specialty,'') IN ('Undersea and Hyperbaric Medicine ') THEN 'Hyperbaric Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Allopathic & Osteopathic Physicians, Internal Medicine','Family Medicine, Adult Medicine','Nurse Practitioner - Adult Health','Nurse Practitioner, Adult Health','Nurse Practitioner, Primary Care') THEN 'INTERNAL MEDICINE'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Infectious Disease') THEN 'Infectious Disease'
								WHEN ISNULL(Provider_Specialty,'') IN ('Obstetrics & Gynecology, Maternal & Fetal Medicine') THEN 'Maternal And FetaL Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Clinical Genetics') THEN 'Medical Genetics'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Medical Oncology') THEN 'MEDICAL ONCOLOGY'
								WHEN ISNULL(Provider_Specialty,'') IN ('Nurse Midwife', 'Advanced Practice Midwife', 'Midwife','Midwife, Certified Nurse') THEN 'Midwife'
								WHEN ISNULL(Provider_Specialty,'') IN ('Nurse Practitioner, Perinatal') THEN 'Neonatal And Perinatal Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Nuclear Medicine, Nuclear Cardiology') THEN 'Nuclear Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('End-Stage Renal Disease (ESRD) Treatment','Internal Medicine, Nephrology') THEN 'Nephrology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Psychiatry and Neurology - Neurology', 'NEUROLOGY','Psychiatry and Neurology -  Neurology with Special Qualifications in Child Neurology',' Psychiatry & Neurology, Clinical Neurophysiology',' Psychiatry & Neurology, Neurology',' Psychiatry & Neurology, Neurology with Special Qualifications in Child Neurology','Psychiatry and Neurology, Epilepsy') THEN 'Neurology'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Neuromuscular Medicine') THEN 'Neuromusculoskeletal Medicine & OMM'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pathology, Neuropathology') THEN 'Neuropathology'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Behavioral Neurology & Neuropsychiatry') THEN 'Neuropsychology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Neurological Surgery', 'NEUROSURGERY') THEN 'Neurological Surgery'
								WHEN ISNULL(Provider_Specialty,'') IN ('Obstetrics & Gynecology, Obstetrics') THEN 'Obstetrics'
								WHEN ISNULL(Provider_Specialty,'') IN ('Obstetrics and Gynecology', 'OBSTETRICS/GYNECOLOGY','Nurse Practitioner, Obstetrics & Gynecology','Nurse Practitioner, Womenâ€™s Health','Obstetrics & Gynecology','Female Pelvic Medicine & Reconstructive Surgery','Obstetrics & Gynecology, Female Pelvic Medicine and Reconstructive Surgery') THEN 'Obstetrics and Gynecology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Ophthalmic Plastic and Reconstructive Surgery') THEN 'Oculoplastics'
								WHEN ISNULL(Provider_Specialty,'') IN ('Ophthalmology - Retina Specialist', 'OPHTHALMOLOGY','Ophthalmology, Cornea and External Diseases Specialist','Ophthalmology/Neuro-ophthalmology') THEN 'Ophthalmology'
								WHEN ISNULL(Provider_Specialty,'') IN ('OPTICIAN', 'OPTOMETRIST','Optometrist, Corneal and Contact Management','Optometrist, Low Vision Rehabilitation','Optometrist, Pediatrics') THEN 'Optometrist'
								WHEN ISNULL(Provider_Specialty,'') IN ('ORTHOPEDICS, SPINE') THEN 'Orthopedics'
								WHEN ISNULL(Provider_Specialty,'') IN (' Otolaryngology/Facial Plastic Surgery','OTOLARYNGOLOGY','Otolaryngology/Otolaryngic Allergy','Otolaryngology/Otolaryngology/Facial Plastic Surgery','Otolaryngology/Otology &Neurotology','Otolaryngology/Plastic Surgery within the Head & Neck','Otolaryngology/Sleep Medicine',' Otolaryngology ') THEN 'Otolaryngology'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Pain Medicine','Anesthesiology/Pain Medicine','Pain Medicine, Interventional Pain Medicine','Pain Medicine, Pain Medicine') THEN 'Pain Management'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pathology, Clinical Pathology/Laboratory Medicine') THEN 'Pathology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Allergy & Immunology') THEN 'Pediatric Allergy/Immunology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics - Pediatric Cardiology','Pediatrics, Pediatric Cardiology') THEN 'Pediatric Cardiology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Critical Care Medicine') THEN 'Pediatric Critical Care Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Dentist - Pediatric Dentistry') THEN 'Pediatric Dentistry'
								WHEN ISNULL(Provider_Specialty,'') IN ('Dermatology, Pediatric Dermatology') THEN 'Pediatric Dermatology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Emergency Medicine, Pediatric Emergency Medicine','Pediatrics, Pediatric Emergency Medicine') THEN 'Pediatric Emergency'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Endocrinology') THEN 'Pediatric Endocrinology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Gastroenterology') THEN 'Pediatric Gastroenterology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Hematology-Oncology') THEN 'Pediatric Hematology And Oncology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Infectious Diseases','Pediatrics, Pediatric Nephrology') THEN 'Pediatric Infectious Disease'
								WHEN ISNULL(Provider_Specialty,'') IN ('Ophthalmology/Pediatric Ophthalmology and Strabismus Specialist') THEN 'Pediatric Ophthalmology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Orthopedic Surgery, Pediatric Orthopedic Surgery') THEN 'Pediatric Orthopedics'
								WHEN ISNULL(Provider_Specialty,'') IN ('Otolaryngology/Pediatric Otolaryngology') THEN 'Pediatric Otolaryngology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Pulmonology') THEN 'Pediatric Pulmonary Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Radiology, Pediatric Radiology') THEN 'Pediatric Radiology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Rheumatology') THEN 'Pediatric Rheumatology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Pediatrics, Pediatric Transplant Hepatology') THEN 'Pediatric Transplant Hepatology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Urology, Pediatric Urology') THEN 'Pediatric Urology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Nurse Practitioner, Pediatrics','Nurse Practitioner, School','Pediatrics/Obesity Medicine') THEN 'Pediatrics'
								WHEN ISNULL(Provider_Specialty,'') IN ('Physical Medicine & Rehabilitation','Physical Medicine & Rehabilitation, Neuromuscular Medicine','Physical Medicine & Rehabilitation, Pain Medicine','Physical Medicine & Rehabilitation, Spinal Cord Injury Medicine','Physical Medicine & Rehabilitation, Sports Medicine','PHYSICAL MEDICINE AND REHABILIATION', 'PHYSICAL MEDICINE AND REHABILITATION') THEN 'Physical Medicine And Rehabilitation'
								WHEN ISNULL(Provider_Specialty,'') IN ('Physician Assistant') THEN 'Physician Assistant, Medical'
								WHEN ISNULL(Provider_Specialty,'') IN ('Physician Assistant - Surgical') THEN 'Physician Assistant, Surgical'
								WHEN ISNULL(Provider_Specialty,'') IN ('Plastic Surgery','Plastic Surgery, Plastic Surgery Within the Head and Neck','Plastic Surgery, Surgery of the Hand','Surgery/Plastic and Reconstructive Surgery','PLASTIC AND RECONSTRUCTIVE SURGERY', 'Plastic Surgery') THEN 'Plastic And Reconstructive Surgery'
								--WHEN ISNULL(Provider_Specialty,'') IN () THEN 'Plastic Surgery'
								WHEN ISNULL(Provider_Specialty,'') IN ('Podiatrist - Foot and Ankle Surgery', 'PODIATRIST','PODIATRIST','Podiatrist, Foot & Ankle Surgery','Podiatrist, Foot Surgery','Podiatrist, Primary Podiatric Medicine','Podiatrist, Public Medicine','Podiatrist, Sports Medicine','PODIATRY') THEN 'Podiatrist'
								WHEN ISNULL(Provider_Specialty,'') IN ('Preventive Medicine, Occupational Medicine','Preventive Medicine, Public Health & General Preventive Medicine','Preventive Medicine/Addiction Medicine') THEN 'Preventative Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Psychiatry and Neurology - Child and Adolescent Psychiatry', 'PSYCHIATRY',' Psychiatry & Neurology, Forensic Psychiatry',' Psychiatry & Neurology, Psychiatry',' Psychiatry & Neurology, Psychosomatic Medicine','Nurse Practitioner, Psychiatric/Mental Health','Psychiatric Unit','Clinic/Center, Mental Health') THEN 'Psychiatry'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Child & Adolescent Psychiatry') THEN 'Psychiatry, Child & Adolescent'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Geriatric Psychiatry') THEN 'Psychiatry, Geriatric'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Pulmonary Disease') THEN 'Pulmonary Disease'
								WHEN ISNULL(Provider_Specialty,'') IN ('Radiology - Radiation Oncology', 'Radiation Oncology','Radiology, Radiation Oncology') THEN 'Radiation Oncology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Radiology - Vascular and Interventional Radiology','Radiology, Vascular and Interventional Radiology') THEN 'Radiology, Vascular And Interventional'
								WHEN ISNULL(Provider_Specialty,'') IN ('Obstetrics & Gynecology, Reproductive Endocrinology') THEN 'Reproductive Endocrinology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Internal Medicine, Rheumatology') THEN 'Rheumatology'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Sleep Medicine','Ambulatory Health Care Facilities/Sleep Disorder Diagnostic','Family Medicine, Sleep Medicine','Internal Medicine, Sleep Medicine') THEN 'Sleep Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('SOCIAL WORKER','Social Worker, Clinical') THEN 'Social Work'
								WHEN ISNULL(Provider_Specialty,'') IN ('Family Medicine, Sports Medicine','Internal Medicine, Sports Medicine') THEN 'Sports Medicine'
								WHEN ISNULL(Provider_Specialty,'') IN ('Thoracic Surgery (Cardiothoracic Vascular Surgery)') THEN 'Surgery, Cardio-Thoracic'
								WHEN ISNULL(Provider_Specialty,'') IN ('Colon & Rectal Surgery','COLORECTAL SURGERY') THEN 'Surgery, Colon And Rectal'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery/Surgical Critical Care') THEN 'Surgery, Critical Care'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery, Surgery of the Hand') THEN 'Surgery, Hand'
								WHEN ISNULL(Provider_Specialty,'') IN ('Ophthalmology, Dental Providers/Dentist, Oral & Maxillofacial Surgery','Oral and Maxillofacial Surgery','ORAL SURGERY (DENTISTS ONLY)') THEN 'Surgery, Oral And Maxillofacial'
								WHEN ISNULL(Provider_Specialty,'') IN ('Orthopedic Surgery','Orthopedic Surgery, Adult Reconstructive Orthopedic Surgery','Orthopedic Surgery, Foot and Ankle Surgery','Orthopedic Surgery, Foot and Ankle Surgery',
										'Orthopedic Surgery, Hand Surgery','Orthopedic Surgery, Orthopedic Surgery of the Spine','Orthopedic Surgery, Orthopedic Trauma','Orthopedic Surgery/Sports Medicine') THEN 'Surgery, Orthopedic'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery/Pediatric Surgery') THEN 'SURGERY, Pediatric'
								WHEN ISNULL(Provider_Specialty,'') IN ('THORACIC SURGERY') THEN 'Surgery, Thoracic'
								WHEN ISNULL(Provider_Specialty,'') IN ('Transplant Surgery') THEN 'Surgery, Transplant'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery/Trauma Surgery') THEN 'Surgery, Trauma'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery, Surgical Oncology') THEN 'Surgical Oncology'
								WHEN ISNULL(Provider_Specialty,'') IN (' Psychiatry & Neurology, Vascular Neurology') THEN 'Vascular Neurology'
								WHEN ISNULL(Provider_Specialty,'') IN ('Surgery, Vascular Surgery') THEN 'Vascular Surgery'
								ELSE ISNULL(Provider_Specialty,'') 
						END
	-- field needed for data validation
	,Provider_Specialty_Source = CASE
										WHEN  ISNULL(Provider_Specialty,'') IN ('Plastic Surgery') AND Provider_Specialty_Source = 'MSOW' THEN 'Claims'
										ELSE Provider_Specialty_Source
									END
    ,DiagnosisCodeDescription
	,PlaceOfServiceCodeDescription
    ,Office_Visit_DATE 
	,ProcedureCode -- field needed for data validation
	,EMPLOYEE_FLAG
	,Attributed_Provider
	,Attributed_Provider_Specialty
	,Attributed_Provider_Practice_Group
	,Bill_Prov_Desc
	,Bill_Prov_NPI
	,IN_OUT_Network
	-- select count(*)
--into RRHLeakage_OfficeVisits
FROM #Report_Staging
--where PatientID = 11505289
--where Bill_Prov_Desc = ''
--	and Bill_Prov_NPI <> ''
--where PatientID <= 12045045
--where patientid = 11468986
--where PatientID between 12045045 and 13065045
--where PatientID between 13065046 and 20120417
--where PatientID > 20120417
--WHERE Provider_Specialty IN ('GENERAL PRACTICE','FAMILY PRACTICE','FAMILY MEDICINE','INTERNAL MEDICINE','PEDIATRIC MEDICINE','GERIATRIC MEDICINE','PEDIATRICS')
order by PatientID, Office_visit_date

--- Exclude PCPs
--- another run through of cleaning up PCPs
-- Per Jen H, she gave me a grouping for Family Medicine
-- when creating #Report_Staging2 there is a grouping for Family Medicine.  Want to not include those in the report.
DELETE R
FROM RRHLeakage_OfficeVisits R 
WHERE Provider_Specialty IN ('GENERAL PRACTICE','FAMILY PRACTICE','FAMILY MEDICINE','INTERNAL MEDICINE','PEDIATRIC MEDICINE','GERIATRIC MEDICINE','PEDIATRICS')


--- IF ProviderFullName is blank or unknown, update ProviderFullName with billing description
UPDATE R
SET ProviderFullName = ISNULL(Bill_Prov_Desc,'')
-- select *
FROM RRHLeakage_OfficeVisits R
where ProviderFullName IN ('','<UNKNOWN>')
		OR ProviderFullName IS NULL

--- potential way to fix specialty
--select distinct U.UPPNAME
--into #findMistakes
--from #Report_Staging2 R
--	CROSS APPLY (SELECT UPPNAME =  dbo.udf_ProperCase(Provider_Specialty)) U

------------ Results for excel
select DISTINCT PATIENTID 
	,NPI
    ,PROVIDERFULLNAME
	,Provider_Specialty
	,Provider_Specialty_Source
    ,DiagnosisCodeDescription
	,PlaceOfServiceCodeDescription
    ,Office_Visit_DATE = convert(varchar(10), Office_Visit_DATE, 101)
	,ProcedureCode
	,EMPLOYEE_FLAG
	,Attributed_Provider
	,Attributed_Provider_Specialty
	,Attributed_Provider_Practice_Group
	,Bill_Prov_Desc
	,Bill_Prov_NPI
	,IN_OUT_Network
from RRHLeakage_OfficeVisits

END
GO


