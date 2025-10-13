USE [Reporting]
GO

/****** Object:  StoredProcedure [dbo].[EmployedPCP_Outpatient_Procedures]    Script Date: 10/13/2025 9:14:53 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO






CREATE PROCEDURE [dbo].[EmployedPCP_Outpatient_Procedures]
AS
BEGIN
/* HISTORY
08/13/2025 -- Creation - copy of radiology report
08/14/2025 -- adding deletion of records based on certain procedure codes
08/28/2025 -- adding deletion of records for certain places of service
*/

	DECLARE @MSR_STARTDATE DATETIME
	DECLARE @MSR_STARTDATE_Claims DATETIME
	DECLARE @MSR_ENDDATE DATETIME
	DECLARE @MSR_START_YRMO VARCHAR(6)
	DECLARE @MSR_START_Claims_YRMO VARCHAR(6)
	DECLARE @MSR_END_YRMO VARCHAR(6)
	DECLARE @POP_RELATIONSHIPDATE VARCHAR(8)

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

	--select @MSR_STARTDATE_Claims, @MSR_ENDDATE

IF OBJECT_ID('TEMPDB.DBO.#GRIPA_EMP') IS NOT NULL DROP TABLE #GRIPA_EMP


--/*********** Gathering provider information from vAlign ***********************/
--/*20240625 LR */
---- Ignore the 2 years all together and just use valign for active/inactive during timeframe of report.  i.e. if a provider termed on 2/2/24, they should be in network for reporting period 1/1/24 through 4/30/24, 
---- unless you can make specific to their actual term date…(in before 2/2, out after 2/3)
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
							and med_plan like 'gripa%' --and Termination_Date='12/31/2399'
			LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_SPECIALTY] GS ON GS.CONTACTID=C.CONTACTID AND PRIMARYSPEC='Yes'
			LEFT JOIN [GRIPA-DB-6].[CRM_GRIPA_Extracts].[dbo].[GRIPA_OfficeGroupPractice] E ON E.CONTACTID=C.CONTACTID 
					AND E.PrimaryOffice='Yes' 
					--AND E.ProviderInOGP='ACTIVE'
		--WHERE C.[Status] = 'Active'
		) Q
WHERE Q.NPI IS NOT NULL 
	AND ROW_ID=1 

-- insert independent APPs into #GRIPA_EMP table
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


--- adding facilities to #RRH_EMP
insert into #RRH_EMP([Name], NPI, Employed, DentalStaff2023,[Hospital Employee], [PRIMARY SPECIALTY],[PRIMARY PRACTICE NAME ])
select [FacilityName] = Facility, NPI, Employed = 'Y', DentalStaff2023 = 'Y',[Hospital Employee] = 'Y',[PRIMARYSPECIALTY] = 'Facility',[PRIMARYPRACTICENAME] = Facility
--from [GRIPA-DB-6].[Excellus_Extract].[dbo].InNetworkFacilities
-- select *
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



----- Members of Excellus, MVP all LOBS attributed to Employed Physicians who has visited any Employed provider
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
		--PCP_SPECIALTY=UPPER(RE.[PRIMARY SPECIALTY]),
		--PRACTICE_GROUP=RE.[PRIMARY PRACTICE NAME],
		PCP_SPECIALTY=UPPER(S.SpecialtyName),
		PRACTICE_GROUP=G.GroupName,
		PROV.NPI,
		--PCP_Employee_Flag = MAX(CASE WHEN RE.NPI IS NOT NULL THEN 'IN NETWORK' ELSE 'OUT OF NETWORK' END), 					-- MSOW
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

--- NEED TO CREATE CODE TO CHECK FOR NEW FACILITIES

---- get all radiology visits for members in #POP_STG table for 2024 claims
if object_id('tempdb..#OutpatientSurgery') is not null
DROP TABLE #OutpatientSurgery

SELECT  IDENTITY( INT,1,1 ) AS 'RowNum'
		,C.ClaimIDPayer
		,C.PatientIDPayer
		,C.PATIENTID
       ,PROVIDERFULLNAME
	   ,P.ClaimsProviderID
	   ,Provider_Specialty = rfd.spec_desc
       ,b.DiagnosisCodeDescription
       ,OutpatientSurgery_DATE = D1.DATE
	   ,C.ProcedureCode
	   ,DP.[ProcedureCodeDescription]
	   ,PlaceOfServiceCodeDescription
	   ,Bill_Prov_Desc = cast(null as varchar(500))
	   ,Bill_Prov_NPI = cast(null as varchar(500))
INTO    #OutpatientSurgery
-- select top 100 *
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
	AND D1.[Date] BETWEEN @MSR_STARTDATE_Claims AND @MSR_ENDDATE-- had a radiology claim within reporting period
	AND P.ProviderFullName IS NOT NULL
	AND C.PatientID <> -1 -- no unknown patients
	AND (C.ProcedureCode between '10021' and '69990')
GROUP BY C.ClaimIDPayer
		,C.PATIENTID
		,C.PatientIDPayer
       ,PROVIDERFULLNAME
	   ,P.ClaimsProviderID
       ,D1.DATE
       ,b.DiagnosisCodeDescription
	   ,C.ProcedureCode
	   ,DP.ProcedureDescription
	   ,DP.[ProcedureCodeDescription]
	   ,PlaceOfServiceCodeDescription
	   ,rfd.spec_desc
HAVING  SUM(VISITCOUNTER) >= 1 OR SUM(ServiceCounter)>=1

-- deleting procedure codes that aren't really in the correct range
DELETE 
FROM #OutpatientSurgery
where ProcedureCodeDescription IN (SELECT ProcedureCodeDescription FROM Reporting.dbo.RRHLeakage_OutpatientProcedures_Exclusions)


----- get billing information so Jen H can fill in more information
if object_id('tempdb..#Billing_Info') is not null
DROP TABLE #Billing_Info

---- can't find how created CLAIMS_EXTRACT_2024 table.  doesn't have a claim in table that i need
--- going to take info from DB-4

select distinct O.*,
ClaimsExtract_PatientIDPayer = c.pat_id,
ClaimsExtract_bill_prov = c.bill_prov,
ClaimsExtract_AdmDate = c.adm_date, 
ClaimsExtract_DisDate = c.dis_date,
ClaimsExtract_ClaimIDPayer = c.claim_id_payor,
ClaimsExtract_BillProvDesc = C.Bill_Prov_Desc,
ClaimsExtract_BillProvNPI = C.Bill_Prov_NPI
INTO #Billing_Info
from #OutpatientSurgery O 
	JOIN Reporting.dbo.RRHLeakage_BillingInformation C with (nolock) on O.PatientIDPayer = C.pat_id
															AND O.OutpatientSurgery_DATE = C.adm_date
															AND O.ClaimIDPayer = C.claim_ID_Payor

--select DISTINCT O.*, 
--ClaimsExtract_PatientID = C.PatientID, 
--ClaimsExtract_ClaimIDPayer = C.claim_ID_Payor, 
--ClaimsExtract_FromDate = C.from_date, 
--ClaimsExtract_BillProvDesc = C.Bill_Prov_Desc, 
--ClaimsExtract_BillProvNPI = C.Bill_Prov_NPI
--INTO #Billing_Info
--from #OutpatientSurgery O 
--	JOIN reporting.dbo.CLAIMS_EXTRACT_2024 C on O.PatientID = C.PatientID
--															AND O.OutpatientSurgery_DATE = C.from_date
--															AND O.ClaimIDPayer = C.claim_ID_Payor


CREATE INDEX NIDX_BillingInfo ON #Billing_Info(ClaimIDPayer)

UPDATE O SET Bill_Prov_Desc = C.ClaimsExtract_BillProvDesc, Bill_Prov_NPI = C.ClaimsExtract_BillProvNPI
from #OutpatientSurgery O 
	JOIN #Billing_Info C on O.PatientIDPayer = C.ClaimsExtract_PatientIDPayer
							AND O.OutpatientSurgery_DATE = C.ClaimsExtract_AdmDate
							AND O.ClaimIDPayer = C.ClaimsExtract_ClaimIDPayer


---- get all ED/OBs visits for members in #POP_STG table for 2024 claims
if object_id('tempdb..#Report_Staging') is not null
DROP TABLE #Report_Staging

SELECT RowNum
	,E.PATIENTID 
	,NPI = ClaimsProviderID
    ,PROVIDERFULLNAME = MAX(CASE 
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME <> '' THEN GE2.[NAME]						-- vAlign
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='Y' THEN RE.NAME									-- MSOW		
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='N' THEN RE.NAME									-- MSOW									
								WHEN SP.NPI IS NOT NULL AND SP.[Name] <> '' THEN SP.NAME			-- NPI Registry
								ELSE E.PROVIDERFULLNAME																		-- Claims
							END)
	,Provider_Specialty = MAX(CASE 																									
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME <> '' THEN GE2.SPECIALTYNAME						-- vAlign
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='Y' THEN RE.[PRIMARY SPECIALTY]							-- MSOW
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='N' THEN RE.[PRIMARY SPECIALTY]							-- MSOW
								WHEN SP.NPI IS NOT NULL  AND SP.[Name] <> ''  THEN SP.SPECIALTY		-- NPI Registry	
								--WHEN E.Provider_Specialty IN ('OTHER SPECIALTY CODE','PHYSICIAN ASSISTANT','NURSE PRACTITIONER')  AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription
								--WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME IS NULL AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription
								ELSE E.Provider_Specialty 
							END)
	,Provider_Specialty_Source = MAX(CASE  
								WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME <> '' THEN 'vAlign'													
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='Y' THEN 'MSOW'						
								WHEN RE.NPI IS NOT NULL AND RE.EMPLOYED='N' THEN 'MSOW'						 
								WHEN SP.NPI IS NOT NULL  AND SP.[Name] <> ''  THEN 'NPI Registry'						
								--WHEN E.Provider_Specialty IN ('OTHER SPECIALTY CODE','PHYSICIAN ASSISTANT','NURSE PRACTITIONER') AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN 'Claims'
								--WHEN GE2.NPI IS NOT NULL AND GE2.SPECIALTYNAME IS NULL AND E.PlaceOfServiceCodeDescription IN ('49: Independent Clinic','20: Urgent Care Facility') THEN E.PlaceOfServiceCodeDescription
								ELSE 'Claims'
							END)
    --,DiagnosisCodeDescription
    ,OutpatientSurgery_DATE 
	,ProcedureCode
	,[ProcedureCodeDescription]
	,EMPLOYEE_FLAG = ISNULL(GE.Employee,'Non-GRIPA')
	,Attributed_Provider = P.PCP
	,Attributed_Provider_Specialty = P.PCP_SPECIALTY
	,Attributed_Provider_Practice_Group = P.PRACTICE_GROUP	
	,PlaceOfServiceCodeDescription
	,Bill_Prov_Desc = CASE 
							WHEN ISNULL(Bill_Prov_Desc,'') IN ('BEAUMONT MEDICAL GROUP') THEN 'BEAUMONT MEDICAL GROUP'
							WHEN ISNULL(Bill_Prov_Desc,'') IN ('FOUNDATION RADIOLOGY GRP') THEN 'FOUNDATION RADIOLOGY GRP'
							WHEN ISNULL(Bill_Prov_Desc,'') IN ('ITS Proxy All Remaining Services','Primary Care Specialities, ITS Nonpar','Primary Care Specialties, ITS InNet Prov','Remaining Specialties, ITS InNet') THEN 'ITS Proxy'
							WHEN ISNULL(Bill_Prov_Desc,'') IN ('RELA HOSPITAL') THEN 'RELA HOSPITAL'
							ELSE ISNULL(Bill_Prov_Desc,'')
						END
	,Bill_Prov_NPI = CASE 
						WHEN ISNULL(Bill_Prov_Desc,'') IN ('Kevin B Wynne') THEN '1598752784'
						ELSE ISNULL(Bill_Prov_NPI,'')
						END 
	,IN_OUT_Network = CAST(null as VARCHAR(100))
	--,IN_OUT_Network = MIN(CASE
	--							WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) AND GE.[Status] = 'Active'  THEN 'IN NETWORK'
	--							WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) 
	--												AND GE2.[Status] = 'Inactive' 
	--												AND convert(date,GE.InactiveDate) between @MSR_STARTDATE and @MSR_ENDDATE THEN 'IN NETWORK'
	--							WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
	--							WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
	--							WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
	--							WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
	--							WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
	--							WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
	--							ELSE 'OUT OF NETWORK'
	--						END)
INTO #Report_Staging
FROM #OutpatientSurgery E
	JOIN #POP_STG P on E.PatientID = P.PatientID
	LEFT JOIN #GRIPA_EMP GE on P.NPI = GE.NPI  -- get PCPs attributed to members
	LEFT JOIN #GRIPA_EMP GE2 on GE2.NPI = E.ClaimsProviderID  -- get providers who performed the service
	LEFT JOIN #RRH_EMP RE ON RE.NPI = E.ClaimsProviderID 
	LEFT JOIN #RRH_EMP RE2 ON RE2.NPI = E.Bill_Prov_NPI -- get billing NPI 
	LEFT JOIN #NPI_SP SP on SP.NPI = E.ClaimsProviderID
GROUP BY RowNum,E.PATIENTID
	--,DiagnosisCodeDescription
    ,OutpatientSurgery_DATE 
	,ProcedureCode
	,[ProcedureCodeDescription]
	,ISNULL(GE.Employee,'Non-GRIPA')
	,P.PCP
	,ClaimsProviderID
	,P.PCP_SPECIALTY
	,P.PRACTICE_GROUP
	,PlaceOfServiceCodeDescription
	,ISNULL(Bill_Prov_Desc,'')
	,ISNULL(Bill_Prov_NPI,'')
ORDER BY E.PatientID, OutpatientSurgery_DATE

--- find records where multiple procedure codes & dos
if object_id('tempdb..#Dup_Proc_DOS') is not null
DROP TABLE #Dup_Proc_DOS

select PatientID, ProcedureCode, OutpatientSurgery_DATE
INTO #Dup_Proc_DOS
from #Report_Staging
group by PatientID, ProcedureCode, OutpatientSurgery_DATE
having count(*) > 1


--- for those records with same procedure code & DOS, if bill_prov_NPI does NOT equal NPI then remove
if object_id('tempdb..#Dup_Proc_DOS_Remove') is not null
DROP TABLE #Dup_Proc_DOS_Remove

select R.*
into #Dup_Proc_DOS_Remove
from #Report_Staging R
	JOIN #Dup_Proc_DOS D on R.PatientID = D.PatientID
							and R.ProcedureCode = D.ProcedureCode
							and R.OutpatientSurgery_DATE = D.OutpatientSurgery_DATE
where R.NPI <> R.Bill_Prov_NPI

-- delete records from #Report_Staging that have been determined to be removed based on #Dup_Proc_DOS_Remove table
DELETE R
-- select R.*
FROM #Report_Staging R
	JOIN #Dup_Proc_DOS_Remove D on R.RowNum = D.RowNum


--- look for records where have multiple records of procedure code and DOS AND bill_prov_NPI equals NPI
-- if the above is true and bill_prov_desc is in InNetworks table, keep

--- need to get updated list of duplicate records after first round of duplicates was removed from #Report_Staging table
--- find records where multiple procedure codes & dos
if object_id('tempdb..#Dup_Proc_DOS_2ndRound') is not null
DROP TABLE #Dup_Proc_DOS_2ndRound

select PatientID, ProcedureCode, OutpatientSurgery_DATE
INTO #Dup_Proc_DOS_2ndRound
from #Report_Staging
group by PatientID, ProcedureCode, OutpatientSurgery_DATE
having count(*) > 1


--- need to get updated list of records that should be removed from #Report_Staging table
--- these records are duplicate records for the same patient with same procedure code & DOS, the bill_prov_NPI equals NPI AND the value in the bill_prov_desc is NOT in the RRHLeakage_Facilities table
if object_id('tempdb..#Dup_Proc_DOS_Remove_2ndRound') is not null
DROP TABLE #Dup_Proc_DOS_Remove_2ndRound

select R.*
into #Dup_Proc_DOS_Remove_2ndRound
from #Dup_Proc_DOS_2ndRound D
	JOIN #Report_Staging R on D.PatientID = R.PatientID
							AND D.ProcedureCode = R.ProcedureCode
							AND D.OutpatientSurgery_DATE = R.OutpatientSurgery_DATE
	 LEFT JOIN RRHLeakage_Facilities F on R.Bill_Prov_NPI = F.NPI
where F.Facility IS NULL
	--and d.patientid = 11472082
	--and d.OutpatientSurgery_DATE = '2024-02-23 00:00:00.000'
	--and d.procedurecode = '72170'

-- delete records from #Report_Staging that have been determined to be removed based on #Dup_Proc_DOS_Remove table
DELETE R
-- select R.*
FROM #Report_Staging R
	JOIN #Dup_Proc_DOS_Remove_2ndRound D on R.RowNum = D.RowNum
	

--- 8/4/2025 -- removing because employee_flag is based on billing information so need to keep Attributed_Provider_Practice_Group values as is
---- Set any record with Employee_Flag = 'NON-GRIPA' to have an unknown practice
---- these are for members who have a non-GRIPA provider attributed to them
--UPDATE R SET Attributed_Provider_Practice_Group = 'UNKNOWN'
--from #Report_Staging R 
--where EMPLOYEE_FLAG = 'Non-GRIPA'


-- if billing_Prov_desc is 'unknown' AND NPI is NOT blank AND NPI = bill_prov_NPI then fill in with providerfullname
UPDATE R SET Bill_Prov_Desc = R2.PROVIDERFULLNAME
-- select *
from #Report_Staging R 
	JOIN #Report_Staging R2 on R.RowNum = R2.RowNum
								AND R.bill_prov_NPI = R2.NPI
where R.bill_prov_desc IN ('','<UNKNOWN>')
	and R.bill_prov_NPI NOT IN ('','<UNKNOWN>')

-- if billing_Prov_desc is 'unknown' AND NPI is blank then fill in with providerfullname
UPDATE R SET Bill_Prov_NPI = NPI,
		Bill_Prov_Desc = PROVIDERFULLNAME
-- select *
from #Report_Staging R 
where bill_prov_desc IN ('','<UNKNOWN>')
	and bill_prov_NPI IN ('','<UNKNOWN>')

	
--- If Bill_Prov_Desc IN ('','<UNKNOWN>') AND  bill_prov_NPI <> '' look at NPI DB in order to name
UPDATE R
SET Bill_Prov_Desc = COALESCE(SP.[Name],SP.ORG_Name)
-- select *
from #Report_Staging R 
	JOIN #NPI_SP SP on R.bill_prov_NPI = SP.NPI
where bill_prov_desc IN ('','<UNKNOWN>')
	and bill_prov_NPI <> ''

--- Need to update In_Out_Network field after all other updates to bill_prov_desc & bill_Prov_NPI are complete
-- if update is done before this, then In_Out_Network field won't match what is in the bill_prov_desc & bill_Prov_NPI  fields
if object_id('tempdb..#Report_Staging_In_Out_Network_NonBlank_Prov_NPI') is not null
DROP TABLE #Report_Staging_In_Out_Network_NonBlank_Prov_NPI

select E.RowNum, 
	E.PatientID,
	E.ProcedureCode,
	E.OutpatientSurgery_DATE,
	E.Bill_Prov_desc,
	E.Bill_Prov_NPI,
	IN_OUT_Network = MIN(CASE
								WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) AND GE.[Status] = 'Active'  THEN 'IN NETWORK'
								WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) 
													AND GE.[Status] = 'Inactive' 
													AND convert(date,GE.InactiveDate) between @MSR_STARTDATE and @MSR_ENDDATE THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								ELSE 'OUT OF NETWORK'
							END)
into #Report_Staging_In_Out_Network_NonBlank_Prov_NPI
from #Report_Staging E
	LEFT JOIN #GRIPA_EMP GE on E.Bill_Prov_NPI = GE.NPI  -- get billing provider NPI
	LEFT JOIN #RRH_EMP RE ON RE.NPI = E.Bill_Prov_NPI 
	LEFT JOIN #NPI_SP SP on SP.NPI = E.Bill_Prov_NPI
WHERE E.Bill_Prov_NPI <> ''
GROUP BY E.RowNum, 
	E.PatientID,
	E.ProcedureCode,
	E.OutpatientSurgery_DATE,
	E.Bill_Prov_desc,
	E.Bill_Prov_NPI

UPDATE E
SET IN_OUT_Network = R.IN_OUT_Network
from #Report_Staging E
	JOIN #Report_Staging_In_Out_Network_NonBlank_Prov_NPI R on E.PatientID = R.PatientID
							and E.OutpatientSurgery_DATE = R.OutpatientSurgery_DATE
							and E.ProcedureCode = R.ProcedureCode
							and E.RowNum = R.RowNum


--- Need to update In_Out_Network field after all other updates to bill_prov_desc & bill_Prov_NPI are complete
-- if update is done before this, then In_Out_Network field won't match what is in the bill_prov_desc & bill_Prov_NPI  fields
if object_id('tempdb..#Report_Staging_In_Out_Network_Blank_Prov_NPI') is not null
DROP TABLE #Report_Staging_In_Out_Network_Blank_Prov_NPI

select E.RowNum, 
	E.PatientID,
	E.ProcedureCode,
	E.OutpatientSurgery_DATE,
	E.Bill_Prov_desc,
	E.Bill_Prov_NPI,
	IN_OUT_Network = MIN(CASE
								WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) AND GE.[Status] = 'Active'  THEN 'IN NETWORK'
								WHEN GE.EMPLOYEE IN ( 'GRIPA-PRIVATE', 'EMPLOYED' ) 
													AND GE.[Status] = 'Inactive' 
													AND convert(date,GE.InactiveDate) between @MSR_STARTDATE and @MSR_ENDDATE THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'Y' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'Y' AND RE.[Hospital Employee] = 'N' THEN 'IN NETWORK'
								WHEN RE.DentalStaff2023 = 'Y'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								WHEN RE.DentalStaff2023 = 'N'  AND RE.Employed = 'N' AND RE.[Hospital Employee] = 'N' THEN 'OUT OF NETWORK'
								ELSE 'OUT OF NETWORK'
							END)
into #Report_Staging_In_Out_Network_Blank_Prov_NPI
from #Report_Staging E
	LEFT JOIN #GRIPA_EMP GE on E.Bill_Prov_NPI = GE.NPI  -- get billing provider NPI
	LEFT JOIN #RRH_EMP RE ON RE.NPI = E.Bill_Prov_NPI 
	LEFT JOIN #NPI_SP SP on SP.NPI = E.Bill_Prov_NPI
WHERE (E.Bill_Prov_NPI = ''
	OR E.Bill_Prov_NPI is null)
GROUP BY E.RowNum, 
	E.PatientID,
	E.ProcedureCode,
	E.OutpatientSurgery_DATE,
	E.Bill_Prov_desc,
	E.Bill_Prov_NPI

UPDATE E
SET IN_OUT_Network = R.IN_OUT_Network
from #Report_Staging E
	JOIN #Report_Staging_In_Out_Network_Blank_Prov_NPI R on E.PatientID = R.PatientID
							and E.OutpatientSurgery_DATE = R.OutpatientSurgery_DATE
							and E.ProcedureCode = R.ProcedureCode
							and E.RowNum = R.RowNum

---- update lable of bill_prov_Desc based on permanent table
UPDATE E
SET Bill_Prov_Desc = D.Billing_Provider_Description
-- select *
from #Report_Staging E
	JOIN RRHLeakage_Provider_Description D on E.bill_prov_NPI = D.Billing_Provider_NPI

TRUNCATE TABLE RRHLeakage_OutpatientProcedures

INSERT INTO RRHLeakage_OutpatientProcedures(PATIENTID,NPI, Facility,/*Provider_Specialty,[Primary Dx],*/PlaceOfServiceCodeDescription,OutpatientSurgery_DATE,Procedure_Code,[ProcedureCodeDescription],EMPLOYEE_FLAG,Attributed_Provider,Attributed_Provider_Specialty,Attributed_Provider_Practice_Group,Billing_Provider_Description,Billing_Provider_NPI,IN_OUT_Network)
------------ Results for excel
select DISTINCT PATIENTID 
	,NPI
    ,Facility = PROVIDERFULLNAME
	--,Provider_Specialty 
    --,[Primary Dx] = DiagnosisCodeDescription
	,PlaceOfServiceCodeDescription
    ,OutpatientSurgery_DATE 
	,ProcedureCode
	,[ProcedureCodeDescription]
	,EMPLOYEE_FLAG
	,Attributed_Provider
	,Attributed_Provider_Specialty
	,Attributed_Provider_Practice_Group
	,Bill_Prov_Desc
	,Bill_Prov_NPI
	,IN_OUT_Network
from #Report_Staging

--- Per Jen H 08/07/2025, these providers should always be marked as out of network
UPDATE R
SET IN_OUT_Network = 'OUT OF NETWORK'
-- select *
FROM RRHLeakage_OutpatientProcedures R
WHERE NPI IN ('1023232741','10871550293','1427380161','1801853932','1801024674','1043278479','1215127253')

-- Per Jen H 8/28/2025, ALWAYS remove claims from these places of service
delete R
--select *
from RRHLeakage_OutpatientProcedures R
where PlaceOfServiceCodeDescription IN ('02: Telehealth','21: Inpatient Hospital','23: Emergency Room','25: Birthing Center','33: Custodial Care','50: Fed. Qualified Health Center',
'61: Inpatient Rehab','72: Rural Health Clinic','99: Other Facility')

END
GO


