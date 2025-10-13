USE [QUALITY_OF_CARE_Staging]
GO

/****** Object:  StoredProcedure [dbo].[usp_Export_CareConnect_RGHSContractMembers]    Script Date: 10/13/2025 9:20:15 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO
















-- =============================================
-- Author:		Laura
-- Create date: 10/16/2024
-- Description:	Create RGHS contracted members extract to send to CareConnect.  Modified from usp_Export_CareConnect_ContractMembers
-- 10/28/2024: LR	Create report of RGHS members who's last name has 8647 in it.  This indicates this is an RGHS employee and a different MRN may need to be used.  While this information is being investigated
--					the member will NOT be included in the roster file.  Also, this stored procedure may need to be modified to include the correct MRN
-- 11/06/2024: LR	Add code to use correct MRNs for RGHS members who are also employees after it's been reviewed by the business.
--					Add code to make sure RGHS members who have been reviewed are included in the RGHS member roster
--					Add Jen H's email to receive list of RGHS members who need to have their MRNs researched
-- 11/07/2024: LR	Changing how members are put into #RGHSMembers table. Some members aren't in QUALITY_OF_CARE_DM..PATIENT_CONTRACT_INSURANCE table.  
--						They are still active RGHS members and need to be included on file
-- 12/03/2024: LR	Added correct MRNs given by Jen H
-- 12/04/2024: LR	Per ticket 19093 & RRH adjusting an MRN for a member.  
--					Chatted with Jen H about code that removes certain members from file that was started with Marina's original stored procedure.  She doesn't have a reason why
--					people should be excluded
-- 01/06/2025: LR	Added correct MRN to use for RGHS member
-- 01/07/2025: LR	Ticket 19514, RRH asked if the leading zeroes for MRNs can be removed
-- 02/03/2025: LR	checking to make sure external codes are numeric before removing leading zeroes
-- 02/03/2025: LR	Ticket 19754: RRH Employee (HVN) roster would be modified to only include members who are attributed to employed RRH PCPs
-- 02/10/2025: LR/TB using table to get correct MRN
-- 03/03/2025: LR	There are some members with 8647 in the last name who do not have a medical chart so the MRN field should be blank.  Adding code to make sure that is the case
-- =============================================
-- NOTE:
--	1) Member appears as many times as RRH MRNs he/she has in MapExternalIndv
--	2) Historically we had VIA MRNs with and without leading zeros - for the purpose of this extract they are all standardised  to 10 characters
--	3) Output file GRIPA_Membership_YYYYMMDD.txt is a tab-delimited, stored in the share \\Portland741\Gripa_IN\

-- =============================================
CREATE PROCEDURE [dbo].[usp_Export_CareConnect_RGHSContractMembers] 
AS
BEGIN
	 --SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

		DECLARE @ProcName varchar(100)
		DECLARE @ErrSeverity INT
		DECLARE @PlaceAtWhichErrorOccurred varchar(300)
		DECLARE @ErrMsg NVARCHAR(4000)
		DECLARE @ERROR varchar(300)
		DECLARE @eSubject varchar(100)
		DECLARE @eBody varchar(4000)
		DECLARE @Body nvarchar(4000)
		DECLARE @qry nvarchar(max)		
		DECLARE @YEARMO INT

		SELECT @YEARMO=(SELECT MAX(YEARMO) FROM [Claims_DM].[dbo].[MembMthsFact])

		SELECT @ProcName = 'usp_Export_CareConnect_RGHSContractMembers'

		--INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		--VALUES (@ProcName, 'START',getdate(),'SP Started')


		IF OBJECT_ID('TEMPDB.DBO.#GRIPA_EMP') IS NOT NULL DROP TABLE #GRIPA_EMP

		SELECT NPI,MED_PLAN,Termination_Date,GROUPPRACTICENAME, UPPER(LASTNAME+','+FIRSTNAME) NAME, 
		EMPLOYEE=CASE WHEN HOSPITAL_EMPLOYEE IS NOT NULL THEN 'EMPLOYED' ELSE 'GRIPA-PRIVATE' END, PROVTYPE, STATUS, INACTIVEDATE
		INTO #GRIPA_EMP
		FROM (
			SELECT C.NPI,MED_PLAN,C.FIRSTNAME,C.LASTNAME,GROUPPRACTICENAME,DEGREE,PROVTYPE,C.STATUS,INACTIVEDATE,Termination_Date,HOSPITAL_EMPLOYEE,
				ROW_ID=ROW_NUMBER() OVER(PARTITION BY C.NPI ORDER BY C.STATUS,Termination_Date DESC,INACTIVEDATE DESC) 
			FROM [CRM_GRIPA_Extracts].[dbo].[GRIPA_Provider] C
		JOIN [CRM_GRIPA_Extracts].[dbo].[GRIPA_MedPlan] M ON M.CONTACTID=C.CONTACTID and med_plan like 'gripa%' and Termination_Date='12/31/2399'
		LEFT JOIN [CRM_GRIPA_Extracts].[dbo].[GRIPA_OfficeGroupPractice] E ON E.CONTACTID=C.CONTACTID 
																			--AND E.PrimaryOffice=1  
																			AND E.PrimaryOffice IN ('1','Yes') 
																			AND E.ProviderInOGP='ACTIVE') Q
		WHERE Q.NPI IS NOT NULL AND ROW_ID=1 --AND Termination_Date='12/31/2399' --( OR Termination_Date BETWEEN @MSR_STARTDATE AND @MSR_ENDDATE)

		CREATE INDEX NIDX_GE ON #GRIPA_EMP(NPI)

---- create table of RGHS contracted members
---- The roster input file must contain a snapshot of the entire roster population on a given date, known as the effective date
---- Every patient in the population should appear in the file, and patients who are not in the population should not appear in the file.
/**** NOTE: 
A member could be listed more than once in this table.  The reason is because some people have more than one ContractName and/or LOB and that information needs to be broken 
in order to be put in the correct files later in the process
*****/

		--INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		--VALUES (@ProcName, 'START',getdate(),'INSERT INTO #RGHSMembers table')

			IF OBJECT_ID('TEMPDB.dbo.#RGHSMembers') IS NOT NULL 
			DROP TABLE #RGHSMembers
/*
			SELECT 
				P.PatientID,
				[Last Name] = P.LastName,
				[First Name] = P.FirstName,
				[Middle Name] = P.MiddleName,
				[Legal Sex] = CASE WHEN P.Gender = 'Male' THEN 'M' WHEN P.Gender = 'Female' THEN 'F' WHEN P.Gender = 'U' THEN 'U' ELSE 'OTH' END,
				[Date of Birth]	= CONVERT(varchar(8),P.Birthdate,112),
				[Social Security Number] = P.SSN,
				[Address] = P.Address_Line1,
				[Address Second Line] = P.Address_Line2,
				P.City,
				P.[State],
				[Zip Code] = P.PostalCode,
				[Phone Number] = P.Phone_Primary,
				--ROW_ID = ROW_NUMBER() OVER(PARTITION BY P.PatientID ORDER BY ContractName ),
				P.PatientStatus,
				DIM.LOB,
				DIM.ContractName
			into #RGHSMembers
			FROM PATIENTS P WITH(NOLOCK)
				JOIN QUALITY_OF_CARE_DM..PATIENT_CONTRACT_INSURANCE PCI WITH(NOLOCK) ON P.PatientId = PCI.PatientID
				JOIN QUALITY_OF_CARE_DM..DIM_CONTRACT_INSURANCE Dim WITH(NOLOCK) ON Dim.ContractInsuranceKey = PCI.ContractInsuranceKey
															AND Dim.IsContracted = 1
			WHERE PCI.IsRowCurrent = 1
				AND Dim.ContractName in ('RGHS') 
				AND Dim.IsContracted = 1
				AND P.PatientStatus = 'Active'	-- Exclude deceased
*/
---- Need to redo how gathering RGHS members
-- some members aren't in QUALITY_OF_CARE_DM..PATIENT_CONTRACT_INSURANCE table.  They are still active RGHS members and need to be included on file
			SELECT 
				P.PatientID,
				[Last Name] = P.LastName,
				[First Name] = P.FirstName,
				[Middle Name] = P.MiddleName,
				[Legal Sex] = CASE WHEN P.Gender = 'Male' THEN 'M' WHEN P.Gender = 'Female' THEN 'F' WHEN P.Gender = 'U' THEN 'U' ELSE 'OTH' END,
				[Date of Birth]	= CONVERT(varchar(8),P.Birthdate,112),
				[Social Security Number] = P.SSN,
				[Address] = P.Address_Line1,
				[Address Second Line] = P.Address_Line2,
				P.City,
				P.[State],
				[Zip Code] = P.PostalCode,
				[Phone Number] = P.Phone_Primary,
				--ROW_ID = ROW_NUMBER() OVER(PARTITION BY P.PatientID ORDER BY ContractName ),
				P.PatientStatus,
				DIM.LOB,
				DIM.ContractName
			into #RGHSMembers
			FROM PATIENTS P WITH(NOLOCK)
				JOIN claims_dm.dbo.MembMthsFact m on P.PatientID = M.PatientID
				JOIN QUALITY_OF_CARE_DM..DIM_CONTRACT_INSURANCE Dim WITH(NOLOCK) ON Dim.ContractInsuranceKey = M.ContractInsuranceKey
															AND Dim.IsContracted = 1
	 --ticket 19754: include members who are attributed to employed RRH PCPs
				JOIN [GRIPA-DB-6].QUALITY_OF_CARE_DM.dbo.PATIENT_OTHER_PROVIDER PAT ON M.PATIENTID = PAT.PATIENTID AND PAT.RELATIONSHIPTYPE='PRIMARY' AND PAT.ISROWCURRENT=1
				JOIN [GRIPA-DB-6].QUALITY_OF_CARE_DM.dbo.DIM_PROVIDER PROV ON PAT.PROVIDERKEY=PROV.PROVIDERKEY AND PROV.ISROWCURRENT=1 
				JOIN #GRIPA_EMP GE ON PROV.NPI=GE.NPI AND GE.EMPLOYEE='Employed'
			WHERE 
				m.yearmo =  @YEARMO
				AND Dim.ContractName in ('RGHS') 
				AND Dim.IsContracted = 1
				AND P.PatientStatus = 'Active'	-- Exclude deceased		


		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #RGHSMembers table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO #ProviderAttribution_staging table')

			---- some members are attributed to multiple providers.  want to have just one provider
			---- create table of contracted members and the provider's they are attributed to
			IF OBJECT_ID('TEMPDB.dbo.#ProviderAttribution_staging') IS NOT NULL 
			DROP TABLE #ProviderAttribution_staging

			select DISTINCT POP.PatientID, ProviderKey = MAX(POP.ProviderKey)
			into #ProviderAttribution_staging
			from quality_of_care_dm.dbo.PATIENT_OTHER_PROVIDER POP
				JOIN #RGHSMembers A on POP.PatientID = A.PatientID
			where RelationshipEndDate > GETDATE()
				AND POP.IsRowCurrent = 1
				AND RelationshipType = 'Primary'
			GROUP BY POP.PatientID


		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #ProviderAttribution_staging table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO #ProviderAttribution table')

			-- create table of contracted members and the provider's they are attributed to
			IF OBJECT_ID('TEMPDB.dbo.#ProviderAttribution') IS NOT NULL 
			DROP TABLE #ProviderAttribution

			select DISTINCT PA.PatientID, PA.ProviderKey, DP.NPI, DP.FirstName, DP.MiddleName, DP.LastName
			into #ProviderAttribution
			from #RGHSMembers A
				JOIN #ProviderAttribution_staging PA on A.PatientID = PA.PatientID
				JOIN QUALITY_OF_CARE_DM.dbo.DIM_PROVIDER DP on PA.ProviderKey = DP.ProviderKey


		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #ProviderAttribution table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO #PayerPatientID table')


			---- create table of contracted members for their unique identifiers from the payers
			IF OBJECT_ID('TEMPDB.dbo.#PayerPatientID') IS NOT NULL 
			DROP TABLE #PayerPatientID

			SELECT PatientID, 
			PayerPatientID , 
			SubscriberID,
			ContractName,
			LOB,
			ROW_ID = ROW_NUMBER() OVER(PARTITION BY PatientID, ContractName ORDER BY PatientID )
			into #PayerPatientID
			FROM (
				select DISTINCT M.PatientID, 
				PayerPatientID = CASE WHEN DataSys like 'RGHS%' AND PayerPatientID LIKE 'EUI%' THEN SUBSTRING(PayerPatientID, 4, LEN(PayerPatientID)) WHEN DataSys = 'MVP' THEN PayerPatientID ELSE PayerPatientID END , 
				SubscriberID = PayerSubscriber + PayerRelation,
				DC.ContractName,
				DC.LOB
				-- select *
				from [Claims_DM].[dbo].[MembMthsFact] M
					JOIN #RGHSMembers A on M.PatientID = A.PatientID
					JOIN quality_of_care_dm.dbo.DIM_CONTRACT_INSURANCE DC on M.ContractInsuranceKey = DC.ContractInsuranceKey
				where M.YearMo = @YearMo
					AND (DataSys like 'RGHS%')
				) x
				----select * from #PayerPatientID

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #PayerPatientID table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO #ExternalCodeCheck table')

			---- get the latest externalCode 
			IF OBJECT_ID('TEMPDB.dbo.#ExternalCodeCheck') IS NOT NULL 
			DROP TABLE #ExternalCodeCheck

			SELECT DISTINCT
				PatientID,
				[Last Name],
				[First Name],
				[Middle Name],
				[Legal Sex],
				[Date of Birth],
				[Social Security Number],
				[Address],
				[Address Second Line],
				City,
				[State],
				[Zip Code],
				[Phone Number],
				externalCode = ISNULL(RIGHT('0000000000'+vw.externalCode,10),''),
				vw.lastupdDate,
				LOB,
				ContractName,
				ExternalCodePriority_ROW_ID = ROW_NUMBER() OVER(PARTITION BY C.PatientID ORDER BY PatientID, LastUpdDate Desc )
			into #ExternalCodeCheck
			FROM #RGHSMembers C
				JOIN vw_MapExternalIndv vw ON C.PatientID = vw.IndividualID
								AND vw.TypeDesc IN ('VIA_MRN','RGHS','CLARITY MRN')
								AND vw.ExternalCode NOT LIKE 'EUI%'
								AND vw.[Status] = 'Active'
			----WHERE C.ROW_ID = 1

		-- 20250107 per ticket 19514, removing leading zeroes for MRNs
		UPDATE E SET externalCode = externalCode * 1
		from #ExternalCodeCheck E
		where ISNUMERIC(externalCode) = 1


		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #ExternalCodeCheck table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO #CareConnect_RGHSMembers table ')

			---- get list of ACQA members who are also part of CareConnect (AKA EPIC, clarity)			
			IF OBJECT_ID('TEMPDB.dbo.#CareConnect_RGHSMembers') IS NOT NULL 
			DROP TABLE #CareConnect_RGHSMembers

			SELECT DISTINCT 
				Pts.PatientID,
				Pts.[Last Name],
				Pts.[First Name],
				Pts.[Middle Name],
				Pts.[Legal Sex],
				Pts.[Date of Birth],
				Pts.[Social Security Number],
				Pts.[Address],
				Pts.[Address Second Line],
				Pts.City,
				Pts.[State],
				Pts.[Zip Code],
				Pts.[Phone Number],
				[Person ID] = externalCode,
				LOB,
				ContractName
			into #CareConnect_RGHSMembers
			FROM #ExternalCodeCheck pts
			where ExternalCodePriority_ROW_ID = 1

/* 
20250303  There are some members with 8647 in the last name who do not have a clinical chart.  In this instance the MRN fields needs to be blank
*/
			UPDATE CC
			SET [Person ID] = CASE 
								WHEN PatientID = 20061204 AND [Person ID] = 41160135 THEN ''
								WHEN PatientID = 20103064 AND [Person ID] = 41603036 THEN ''
								WHEN PatientID = 14551713 AND [Person ID] = 40961280 THEN ''
								WHEN PatientID = 14610541 AND [Person ID] = 40787269 THEN ''
								ELSE [Person ID]
							END
			FROM #CareConnect_RGHSMembers CC

	
/* 
20241106 Some members are RRH employees and can have an MRN that isn't the correct to use
These are manual updates to ensure the correct MRNs are used
THIS LIST WILL GROW
DO NOT INCLUDE LEADING ZEROES!
*/
-- 20250211 - using a table to use correct MRNs
			UPDATE CC
			SET [Person ID] = CASE
									WHEN R.PatientID IS NOT NULL THEN CorrectExternalCode
									ELSE [Person ID]
								END
								-- select *
			FROM #CareConnect_RGHSMembers CC
				LEFT JOIN Quality_of_care_staging.dbo.RGHS_MRN_Corrections R on CC.PatientID = R.PatientID

			--UPDATE #CareConnect_RGHSMembers
			--SET [Person ID] = CASE 
			----	11/06/2024, Added
			--						WHEN PatientID = 11484287 THEN '1465343'
			--						WHEN PatientID = 11545066 THEN '5004015'
			--						WHEN PatientID = 11562477 THEN '5574973'
			--						WHEN PatientID = 11970669 THEN '6099097'
			--						WHEN PatientID = 12030807 THEN '2008704'
			--						WHEN PatientID = 12490871 THEN '5459110'
			--						WHEN PatientID = 12955282 THEN '141067'
			--						WHEN PatientID = 13073340 THEN '41101212'
			--						WHEN PatientID = 13268241 THEN '1619741'
			--						WHEN PatientID = 13595014 THEN '40298059'
			--						WHEN PatientID = 14261298 THEN '1278423'
			--						WHEN PatientID = 14545729 THEN '40902681'
			--						WHEN PatientID = 20029461 THEN '3046075'
			--						WHEN PatientID = 20029904 THEN '7274028'
			--						WHEN PatientID = 20068365 THEN '8577744'
			--						WHEN PatientID = 20122757 THEN '40348241'
			--						WHEN PatientID = 20215097 THEN '40545231'
			--					-- added 12/3/2024
			--						WHEN PatientID = 12115001 THEN '41156864'
			--						WHEN PatientID = 12426346 THEN '3314117'
			--					-- added 12/4/2024
			--						WHEN PatientID = 13463644 THEN '2211595'
			--					-- added 01/06/2025
			--						WHEN PatientID = 11636901 THEN '7915117'
			--					-- added 02/04/2025
			--						WHEN PatientID = 12491299 THEN '40331986'
			--						WHEN PatientID = 11840303 THEN '8433367'
			--						WHEN PatientID = 13276404 THEN '5803802'
			--						WHEN PatientID = 13273195 THEN '40154920'
			--						ELSE [Person ID]
			--					END
			

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #CareConnect_RGHSMembers')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'Delete from #RGHSMembers table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'Delete from #RGHSMembers table')

		--INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		--VALUES (@ProcName, 'START',getdate(),'INSERT INTO #HistoricalPersonID table')

			-- create table of ExternalCodes that are still active but don't have the latest LastUpdDate
			-- it's possible more than one ExternalCode will be inserted.
			-- code is designed to allow mutiple ExternalCodes per patientID but not the same ExternalCode per patientID with a different TypeDesc
			-- as of 20240809, ExternalCodes (MRN) won't be placed into any field.  Don't want to delete code in case it's needed in the future
			-- 202040816, putting all active RGHSMRNs in #ExternalCodeCheck table.  This table won't be needed
			/*
			IF OBJECT_ID('TEMPDB.dbo.#HistoricalPersonID') IS NOT NULL 
			DROP TABLE #HistoricalPersonID

			SELECT DISTINCT
				PatientID,
				externalCode = ISNULL(RIGHT('0000000000'+vw.externalCode,10),'')
			into #HistoricalPersonID
			FROM #RGHSMembers C
				JOIN vw_MapExternalIndv vw ON C.PatientID = vw.IndividualID
								AND vw.TypeDesc IN ('VIA_MRN','RGHS','CLARITY MRN')
								AND vw.ExternalCode NOT LIKE 'EUI%'
			WHERE NOT EXISTS (SELECT 1 FROM #CareConnect_RGHSMembers AC
									WHERE AC.PatientID = vw.IndividualID
										AND AC.[Person ID] = vw.ExternalCode)
			*/

			/*
			[Payer_PatientID] = STUFF(( SELECT   '~'
															+ CAST(Y.PayerPatientID AS VARCHAR)
											from #PayerPatientID y
												   WHERE    A.PATIENTID = Y.PATIENTID
												   ORDER BY A.PATIENTID
												 FOR
												   XML PATH('')
												 ), 1, 1, ''),
			[SubscriberID] = STUFF(( SELECT   '~'
															+ CAST(Y.SubscriberID AS VARCHAR)
											from #PayerPatientID y
												   WHERE    A.PATIENTID = Y.PATIENTID
												   ORDER BY A.PATIENTID
												 FOR
												   XML PATH('')
												 ), 1, 1, '')
			*/

		--INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		--VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #HistoricalPersonID table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO #CareConnect_RGHSContractMembers_FileToRRH_staging table')

			----- create table to hold all ACQA Members with their unqiue IDs from the payers
			IF OBJECT_ID('TEMPDB.dbo.#CareConnect_RGHSContractMembers_FileToRRH_staging') IS NOT NULL 
			DROP TABLE #CareConnect_RGHSContractMembers_FileToRRH_staging

			CREATE TABLE 	#CareConnect_RGHSContractMembers_FileToRRH_staging
			( 
				[PatientID] [int] NULL,
				[Person ID] [varchar](50) NULL,
				[Historical Person ID] [varchar](50) NULL,
				[Last Name] [varchar](100) NULL,
				[First Name] [varchar](100) NULL,
				[Middle Name] [varchar](100) NULL,
				[Legal Sex] [varchar](50) NULL,
				[Date Of Birth] [varchar](10) NULL,
				[Social Security Number] [varchar](11) NULL,
				[Address] [varchar](100) NULL,
				[Address Second Line] [varchar](100) NULL,
				[City] [varchar](50) NULL,
				[State] [varchar](2) NULL,
				[Zip Code] [varchar](10) NULL,
				[Phone Number] [varchar](20) NULL,
				[LOB] [varchar](250) NULL,
				[ContractName] [varchar](50) NULL,
				[ProviderNPI] [varchar](10) NULL,
				[Provider Last Name] [varchar](100) NULL,
				[Provider First Name] [varchar](100) NULL,
				[Provider Middle Name] [varchar](100) NULL,
				[Provider Full Name] [varchar](100) NULL,
				[RGHSMRN] [varchar](100) NULL
			)

			INSERT INTO #CareConnect_RGHSContractMembers_FileToRRH_staging ([PatientID],[Person ID],[Last Name],[First Name],[Middle Name],[Legal Sex],[Date Of Birth],[Social Security Number],[Address],[Address Second Line],[City],[State],[Zip Code],[Phone Number],[LOB],[ContractName],[ProviderNPI],[Provider Last Name],[Provider First Name],[Provider Middle Name],[Provider Full Name],[RGHSMRN])
			SELECT DISTINCT
			A.PatientID,
			[Person ID] = PayerPatientID,
			A.[Last Name],
			A.[First Name],
			A.[Middle Name],
			A.[Legal Sex],
			A.[Date of Birth],
			A.[Social Security Number],
			A.[Address],
			A.[Address Second Line],
			A.City,
			A.[State],
			A.[Zip Code],
			A.[Phone Number],
			---- there are some members who are not in the latest claims roster but we are still showing being an ACQA member.  Picking LOB & ContractName from PayerPatientID first, then picking LOB & ContractName from #A
			LOB = COALESCE(P.LOB, A.LOB),
			ContractName = COALESCE (P.ContractName, A.ContractName),
			[Provider NPI] = PA.NPI, 
			[Provider Last Name] = PA.LastName,
			[Provider First Name] = PA.FirstName, 
			[Provider Middle Name] = PA.MiddleName,
			[Provider Full Name] = PA.FirstName + ' ' + PA.MiddleName + ' ' + PA.LastName,
			RGHSMRN = AC.[Person ID]
			/*STUFF(( SELECT   '~'
															+ CAST(Y.externalCode AS VARCHAR)
											from #ExternalCodeCheck y
												   WHERE    A.PATIENTID = Y.PATIENTID
												   ORDER BY A.PATIENTID
												 FOR
												   XML PATH('')
												 ), 1, 1, '')
												 */
			--into #check
			-- select count(*)
			FROM #RGHSMembers A 
				LEFT JOIN #CareConnect_RGHSMembers AC on A.PatientID = AC.PatientID
			---- Per EPIC want the payer's unique ID to be used in Person ID field
				LEFT JOIN #PayerPatientID P on A.PatientID = P.PatientID 
								and Row_ID = 1
				LEFT JOIN #ProviderAttribution PA on A.PatientID = PA.PatientID


		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO #CareConnect_RGHSContractMembers_FileToRRH_staging table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'Update to #CareConnect_RGHSContractMembers_FileToRRH_staging table')

			----- update any members who happen to have a second unique ID with the same payer/LOB combination
			UPDATE S
			SET [Historical Person ID] = PayerPatientID
			from #CareConnect_RGHSContractMembers_FileToRRH_staging S
				JOIN  #PayerPatientID P on S.PatientID = P.PatientID 
								and Row_ID = 2

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'FINISH',getdate(),'Update to #CareConnect_RGHSContractMembers_FileToRRH_staging table')

		INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
		VALUES (@ProcName, 'START',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH table')

			----- 8/5/5024, ticket 17363: Repurposing the CareConnect_RGHSContractMembers_FileToRRH & CareConnect_RGHSContractMembers_FileToRRH_SENT tables for the ACQA flag update
			---- as of 8/9/2024: RRH_MRN will house Payer PatientID; HistoricalMRN will house PayerPatientID IF a patient has multiple PayerPatientIDs per Contract/LOB combination
			---- as of 8/16/2024: RRH_MRN field will house all active RGHSMRNs; Payer_PatientID will hold information from Person ID field (which is the unique ID from the payer)
			---- as of 9/23/2024: RRH_MRN field will house latest lastupdDate only
			TRUNCATE TABLE CareConnect_RGHSContractMembers_FileToRRH

			--/*
			--saving code in case need to add these fields into file
			----[Payer_PatientID] = STUFF(( SELECT   '~'
			----                                                + CAST(Y.PayerPatientID AS VARCHAR)
			----								from #PayerPatientID y
			----                                       WHERE    A.PATIENTID = Y.PATIENTID
			----                                       ORDER BY A.PATIENTID
			----                                     FOR
			----                                       XML PATH('')
			----                                     ), 1, 1, ''),
			----[SubscriberID] = STUFF(( SELECT   '~'
			----                                                + CAST(Y.SubscriberID AS VARCHAR)
			----								from #PayerPatientID y
			----                                       WHERE    A.PATIENTID = Y.PATIENTID
			----                                       ORDER BY A.PATIENTID
			----                                     FOR
			----                                       XML PATH('')
			----                                     ), 1, 1, '')
			--*/
 /*
08/26/2024 only inserting records into CareConnect_RGHSContractMembers_FileToRRH table where [Person ID] (Payer_PatientID) IS NOT NULL OR Last Name doesn't have 8647 in it
This will allow time for the records to be looked up and have action taken on them
*/
			INSERT INTO CareConnect_RGHSContractMembers_FileToRRH(PatientID,Payer_PatientID, LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary, LOB,ContractName, ProviderNPI, ProviderLastName, ProviderFirstName, ProviderMiddleName,[ProviderFullName],RRH_MRN)
			SELECT DISTINCT
			[PatientID],
			[Person ID],
			[Last Name],
			[First Name],
			[Middle Name],
			[Legal Sex],
			[Date Of Birth],
			[Social Security Number],
			[Address],
			[Address Second Line],
			[City],
			[State],
			[Zip Code],
			[Phone Number],
			[LOB],
			[ContractName],
			[ProviderNPI],
			[Provider Last Name],
			[Provider First Name],
			[Provider Middle Name],
			[Provider Full Name],
			RGHSMRN
			FROM #CareConnect_RGHSContractMembers_FileToRRH_staging
			WHERE [Person ID] IS NOT NULL

-- 20250211 - using a table to use correct MRNs
			DELETE C
			-- select *
			FROM CareConnect_RGHSContractMembers_FileToRRH C
			WHERE [LastName] LIKE '8647%' -- these are RGHS employees.  Need to investigate if the correct MRN is being used
			-- these are PatientID for RGHS employees where the MRN has been researched and the correct MRN is being used.  THIS LIST WILL GROW.
				AND PatientID NOT IN (SELECT PatientID FROM Quality_of_care_staging.dbo.RGHS_MRN_Corrections)

		--	DELETE C
		--	-- select *
		--	FROM CareConnect_RGHSContractMembers_FileToRRH C
		--	WHERE [LastName] LIKE '8647%' -- these are RGHS employees.  Need to investigate if the correct MRN is being used
		---- these are PatientID for RGHS employees where the MRN has been researched and the correct MRN is being used.  THIS LIST WILL GROW.
		--		AND PatientID NOT IN (
		--		--	11/06/2024, Added
		--								11484287,
		--								11545066,
		--								11562477,
		--								11970669,
		--								12030807,
		--								12490871,
		--								12955282,
		--								13073340,
		--								13268241,
		--								13595014,
		--								14261298,
		--								14545729,
		--								20029461,
		--								20029904,
		--								20068365,
		--								20122757,
		--								20215097,
		--				-- added 12/3/2024
		--								12115001,
		--								12426346,
		--				-- added 12/4/2024
		--								20535506,
		--				-- added 01/06/2025
		--								11636901,
		--				-- added 02/04/2025
		--								 12491299,
		--								 11840303,
		--								 13276404,
		--								 13273195
		--							)

			INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
			VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH table')

	/*
	08/26/2024 inserting records into CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID table where [Person ID] (Payer_PatientID) IS  NULL
	This will allow someone to look at the records and taken action on them
	*/
			INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
			VALUES (@ProcName, 'START',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID table')

			TRUNCATE TABLE CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID

			INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID(PatientID,PayerPatientID, LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary, LOB,ContractName, ProviderNPI, ProviderLastName, ProviderFirstName, ProviderMiddleName,[ProviderFullName],RRH_MRN)
			SELECT DISTINCT
			[PatientID],
			[Person ID],
			[Last Name],
			[First Name],
			[Middle Name],
			[Legal Sex],
			[Date Of Birth],
			[Social Security Number],
			[Address],
			[Address Second Line],
			[City],
			[State],
			[Zip Code],
			[Phone Number],
			[LOB],
			[ContractName],
			[ProviderNPI],
			[Provider Last Name],
			[Provider First Name],
			[Provider Middle Name],
			[Provider Full Name],
			RGHSMRN
			FROM #CareConnect_RGHSContractMembers_FileToRRH_staging
			WHERE [Person ID] IS NULL

			INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
			VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID table')

			INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
			VALUES (@ProcName, 'START',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_RHGS_Employees table')

			TRUNCATE TABLE CareConnect_RGHSContractMembers_FileToRRH_RHGS_Employees

			INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_RHGS_Employees(PatientID,PayerPatientID, LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary, LOB,ContractName, ProviderNPI, ProviderLastName, ProviderFirstName, ProviderMiddleName,[ProviderFullName],RRH_MRN)
			SELECT DISTINCT
			[PatientID],
			[Person ID],
			[Last Name],
			[First Name],
			[Middle Name],
			[Legal Sex],
			[Date Of Birth],
			[Social Security Number],
			[Address],
			[Address Second Line],
			[City],
			[State],
			[Zip Code],
			[Phone Number],
			[LOB],
			[ContractName],
			[ProviderNPI],
			[Provider Last Name],
			[Provider First Name],
			[Provider Middle Name],
			[Provider Full Name],
			RGHSMRN
			FROM #CareConnect_RGHSContractMembers_FileToRRH_staging
			WHERE [last name] LIKE '8647%' 

			INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
			VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_RHGS_Employees table')

			 ----checking to see if there are blank records in the Person ID field.  This field can't be blank
			IF (select count(*) from quality_of_care_staging.dbo.CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID) > 1
			BEGIN

	
				SELECT @ERROR = 'There are blank records in the Person ID (Payer_PatientID) field in the CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID table.'

					----PRINT  @ErrMsg   
					----RAISERROR ( @ERROR, 16, 1 )

					INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
					VALUES (@ProcName, 'ERROR',getdate(), @ERROR)

				
					SELECT @Body = '<p>There are blank records in the Person ID (Payer_PatientID) field in the CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID table.<br/><br/><br/>			
											SELECT * FROM QUALITY_OF_CARE_STAGING.DBO.CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID <br/><br/><br/>	
											An IT ticket should be created in order to investigate if merges need to be happen.'

					
					SELECT @qry = 'SET NOCOUNT ON;
					
								SELECT ''RRH_MRN'',''PatientID'',''PayerPatientID'',''HistoricalPersonID'',''LastName'',''FirstName'',''MiddleName'',''Gender'',''DOB'',''SSN'',''Address_Line1'',''Address_Line2'',''City'',''State'',''PostalCode'',''Phone_Primary'',''LOB'',''ContractName'',''ProviderNPI'',''ProviderLName'',''ProviderFName'',''ProviderMiddleName'',''ProvFullName''
									UNION ALL
								SELECT RRH_MRN,PatientID = convert(varchar(100),PatientID),PayerPatientID,[Historical Person ID],LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary,LOB,ContractName,ProviderNPI,ProviderLastName,ProviderFirstName,ProviderMiddleName,ProviderFullName
								FROM QUALITY_OF_CARE_STAGING.DBO.CareConnect_RGHSContractMembers_FileToRRH_Blank_PayerPatientID'

					SELECT @eSubject = CASE 
						WHEN @@SERVERNAME like '%TEST%' THEN 'TEST: ' 
						WHEN @@SERVERNAME like '%PROD%' THEN 'PROD: '
						ELSE '' END + @ProcName + ' failed'

					SELECT @eBody = @ProcName + ' '+@ERROR

					EXEC msdb.dbo.sp_send_dbmail
						@profile_name	= 'sqlmail',
						@recipients		= 'GRIPADBA@rochesterregional.org',
						@subject		= 'usp_Export_CareConnect_RGHSContractMembers FAILURE',
						@body			= @Body,
						@body_format = 'HTML'--,
						/* 10/08/2024 can't attach report.  Too big */
						----@Query = @qry,
						----@query_result_header = 0,
						----@exclude_query_output = 1,
						----@append_query_error = 1,
						----@attach_query_result_as_file = 1,
						----@query_attachment_filename = 'Blank PayerPatientID Field.csv',
						----@query_result_separator = ',',
						----@query_result_no_padding = 1

/*
Want to insert records that are going to be sent to RRH to be inserted into CareConnect_RGHSContractMembers_FileToRRH_SENT table.
This will allow historical look back on who was sent to RRH and at what time.
*/
				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'START',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_SENT table')

					INSERT CareConnect_RGHSContractMembers_FileToRRH_SENT(PatientID,Payer_PatientID,LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary, LOB, ContractName, ProviderNPI, ProviderLastName, ProviderFirstName, ProviderMiddleName,SubscriberID,[ProviderFullName],RRH_MRN)
					SELECT PatientID,
							Payer_PatientID,
							LastName,
							FirstName,
							MiddleName,
							Gender,DOB,
							SSN,
							Address_Line1,
							Address_Line2,
							City,[State],
							PostalCode,
							Phone_Primary, 
							LOB, 
							ContractName, 
							ProviderNPI, 
							ProviderLastName, 
							ProviderFirstName, 
							ProviderMiddleName,
							SubscriberID,
							[ProviderFullName],
							RRH_MRN
					FROM CareConnect_RGHSContractMembers_FileToRRH

				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_SENT table')


				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'FINISH',getdate(),'SP Finished')

			END

			---- checking to see if there are records where that last name has 8647 in the last name.  This indicates this is an RGHS employee and a different MRN may need to be used.  
			---- While this information is being investigated the member will NOT be included in the roster file.  
			IF (select count(*) from quality_of_care_staging.dbo.CareConnect_RGHSContractMembers_FileToRRH_RHGS_Employees) > 1
			BEGIN
				SELECT @ERROR = 'There are RGHS employee records Investigation needs to be done on correct MRN to use'

					----PRINT  @ErrMsg   
					----RAISERROR ( @ERROR, 16, 1 )

					INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
					VALUES (@ProcName, 'ERROR',getdate(), @ERROR)

					
					SELECT @Body = '<p>There are RGHS employee records. Investigation needs to be done on correct MRN to use.'

					
					SELECT @qry = 'SET NOCOUNT ON;
					
								SELECT ''RRH_MRN'',''PatientID'',''PayerPatientID'',''HistoricalPersonID'',''LastName'',''FirstName'',''MiddleName'',''Gender'',''DOB'',''SSN'',''Address_Line1'',''Address_Line2'',''City'',''State'',''PostalCode'',''Phone_Primary'',''LOB'',''ContractName'',''ProviderNPI'',''ProviderLName'',''ProviderFName'',''ProviderMiddleName'',''ProvFullName''
									UNION ALL
								SELECT RRH_MRN,PatientID = convert(varchar(100),PatientID),PayerPatientID,[Historical Person ID],LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary,LOB,ContractName,ProviderNPI,ProviderLastName,ProviderFirstName,ProviderMiddleName,ProviderFullName
								FROM QUALITY_OF_CARE_STAGING.DBO.CareConnect_ContractMembers_FileToRRH_RGHS_Employees'

					SELECT @eSubject = CASE 
						WHEN @@SERVERNAME like '%TEST%' THEN 'TEST: ' 
						WHEN @@SERVERNAME like '%PROD%' THEN 'PROD: '
						ELSE '' END + @ProcName + ' failed'

					SELECT @eBody = @ProcName + ' '+@ERROR

					EXEC msdb.dbo.sp_send_dbmail
						@profile_name	= 'sqlmail',
						@recipients		= 'GRIPADBA@rochesterregional.org;Jennifer.Hajecki@rochesterregional.org',
						@subject		= 'RGHS Employees in RGHS CareConnect Roster',
						@body			= @Body,
						@body_format = 'HTML',
						@Query = @qry,
						@query_result_header = 0,
						@exclude_query_output = 1,
						@append_query_error = 1,
						@attach_query_result_as_file = 1,
						@query_attachment_filename = 'RGHSEmployeesInRGHSCareConnectRoster.txt', -- using .txt file in order to maintain zeroes for MRNs
						@query_result_separator = '	',
						@query_result_no_padding = 1

/*
Want to insert records that are going to be sent to RRH to be inserted into CareConnect_RGHSContractMembers_FileToRRH_SENT table.
This will allow historical look back on who was sent to RRH and at what time.
*/
				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'START',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_SENT table')

					INSERT CareConnect_RGHSContractMembers_FileToRRH_SENT(PatientID,Payer_PatientID,LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary, LOB, ContractName, ProviderNPI, ProviderLastName, ProviderFirstName, ProviderMiddleName,SubscriberID,[ProviderFullName],RRH_MRN)
					SELECT PatientID,
							Payer_PatientID,
							LastName,
							FirstName,
							MiddleName,
							Gender,DOB,
							SSN,
							Address_Line1,
							Address_Line2,
							City,[State],
							PostalCode,
							Phone_Primary, 
							LOB, 
							ContractName, 
							ProviderNPI, 
							ProviderLastName, 
							ProviderFirstName, 
							ProviderMiddleName,
							SubscriberID,
							[ProviderFullName],
							RRH_MRN
					FROM CareConnect_RGHSContractMembers_FileToRRH

				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_SENT table')


				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'FINISH',getdate(),'SP Finished')
			END
			ELSE
			BEGIN

				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'START',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_SENT table')

					-------------------------------------------
					----	Save records that are sent to RRH
					---- as of 8/16/2024: RRH_MRN field will house all active RGHSMRNs; Payer_PatientID will hold information from Person ID field (which is the unique ID from the payer)
					---- for records with insert dates of 8/9/2024, the RRH_MRN field held Payer_PatientID information.  At this time, it's what was requested from RRH & EPIC.  Don't want to update in order to avoid confusion when looking at data in future
					-------------------------------------------
					INSERT CareConnect_RGHSContractMembers_FileToRRH_SENT(PatientID,Payer_PatientID,LastName,FirstName,MiddleName,Gender,DOB,SSN,Address_Line1,Address_Line2,City,[State],PostalCode,Phone_Primary, LOB, ContractName, ProviderNPI, ProviderLastName, ProviderFirstName, ProviderMiddleName,SubscriberID,[ProviderFullName],RRH_MRN)
					SELECT PatientID,
							Payer_PatientID,
							LastName,
							FirstName,
							MiddleName,
							Gender,DOB,
							SSN,
							Address_Line1,
							Address_Line2,
							City,[State],
							PostalCode,
							Phone_Primary, 
							LOB, 
							ContractName, 
							ProviderNPI, 
							ProviderLastName, 
							ProviderFirstName, 
							ProviderMiddleName,
							SubscriberID,
							[ProviderFullName],
							RRH_MRN
					FROM CareConnect_RGHSContractMembers_FileToRRH

					------- File
					----SELECT [Person ID] = RRH_MRN,
					----[Historical Person ID] = HistoricalMRN,
					----[Last Name] = LastName,
					----[First Name] = FirstName,
					----[Middle Name] = MiddleName,
					----[Legal Sex] = Gender,
					----[Date of Birth] = DOB,
					----[Social Security Number] = SSN,
					----[Address] = Address_Line1,
					----[Address Second Line] = Address_Line2,
					----City,
					----[State],
					----[Zip Code] = PostalCode,
					----[Phone Number] = Phone_Primary
					----FROM CareConnect_RGHSContractMembers_FileToRRH

				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'FINISH',getdate(),'INSERT INTO CareConnect_RGHSContractMembers_FileToRRH_SENT table')

				INSERT INTO QUALITY_OF_CARE_MFG.dbo.RUN_LOG (ProcedureName, Check_Point, RunTime, [Message])
				VALUES (@ProcName, 'FINISH',getdate(),'SP Finished')
			END



END

GO


