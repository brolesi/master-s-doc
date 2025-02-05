 Considerando a hipótese: "A análise temporal dos sinais vitais de pacientes adultos internados em unidades de terapia intensiva do MIMIC-IV pode prever episódios de choque séptico com até 6 horas de antecedência, utilizando modelos de aprendizado de máquina" como os documentos selecionam os dados no pré-processamento?
To explore the hypothesis that time-series analysis of vital signs from adult ICU patients in MIMIC-IV can predict septic shock up to 6 hours in advance using machine learning models, the selected sources employ several preprocessing techniques. The focus is on extracting and preparing relevant time-series data and patient characteristics for effective model training and evaluation. Here is how data is selected in the preprocessing phase:
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
* **Patient Selection**:
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
--  * **Adult Patients**: The studies consistently focus on **adult patients, typically defined as those 18 years or older**[1, 2, 3, 4]. Some studies use a lower age limit of 15 [5, 6]. This is a critical first step to ensure that the models are trained on a relevant patient population.
CREATE TABLE MASTER_S_DEGREE.ADULT_PATIENTS AS
WITH
	ADULT_ADMISSIONS AS (
		SELECT DISTINCT
			ADM.SUBJECT_ID,
			EXTRACT(
				YEAR
				FROM
					ADM.ADMITTIME::TIMESTAMP
			) - P.ANCHOR_YEAR + P.ANCHOR_AGE AS CALCULATED_AGE
		FROM
			MIMICIV_HOSP.ADMISSIONS ADM
			JOIN MIMICIV_HOSP.PATIENTS P ON ADM.SUBJECT_ID = P.SUBJECT_ID
		WHERE
			EXTRACT(
				YEAR
				FROM
					ADM.ADMITTIME::TIMESTAMP
			) - P.ANCHOR_YEAR + P.ANCHOR_AGE >= 18
	)
SELECT DISTINCT
	SUBJECT_ID
FROM
	ADULT_ADMISSIONS;

-- Criar índice para melhorar a performance de consultas futuras
CREATE INDEX IDX_ADULT_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.ADULT_PATIENTS (SUBJECT_ID);


-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
--  * **ICU Admission**: Patients are selected based on their admission to the Intensive Care Unit (ICU). Often, only the first ICU admission is considered to prevent data duplication [4, 7, 8].
CREATE TABLE MASTER_S_DEGREE.ADULT_ICU_PATIENTS AS
WITH
	FIRST_ICU_STAYS AS (
		SELECT
			IE.SUBJECT_ID,
			IE.HADM_ID,
			IE.STAY_ID,
			ROW_NUMBER() OVER (
				PARTITION BY
					IE.SUBJECT_ID
				ORDER BY
					IE.INTIME
			) AS ICU_ADMISSION_ORDER
		FROM
			MIMICIV_ICU.ICUSTAYS IE
	),
	ADULT_PATIENTS AS (
		SELECT DISTINCT
			ADM.SUBJECT_ID,
			EXTRACT(
				YEAR
				FROM
					ADM.ADMITTIME::TIMESTAMP
			) - P.ANCHOR_YEAR + P.ANCHOR_AGE AS AGE_AT_ADMISSION
		FROM
			MIMICIV_HOSP.ADMISSIONS ADM
			JOIN MIMICIV_HOSP.PATIENTS P ON ADM.SUBJECT_ID = P.SUBJECT_ID
		WHERE
			EXTRACT(
				YEAR
				FROM
					ADM.ADMITTIME::TIMESTAMP
			) - P.ANCHOR_YEAR + P.ANCHOR_AGE >= 18
	)
SELECT DISTINCT
	AP.SUBJECT_ID,
	FIS.STAY_ID
FROM
	ADULT_PATIENTS AP
	JOIN FIRST_ICU_STAYS FIS ON AP.SUBJECT_ID = FIS.SUBJECT_ID
WHERE
	FIS.ICU_ADMISSION_ORDER = 1;

-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_ADULT_ICU_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.ADULT_ICU_PATIENTS (SUBJECT_ID);

CREATE INDEX IDX_ADULT_ICU_PATIENTS_STAY_ID ON MASTER_S_DEGREE.ADULT_ICU_PATIENTS (STAY_ID);  
  
  
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
  --* **Minimum ICU Stay:** A **minimum length of stay in the ICU is often required, typically 24 hours or more**[3, 4, 7, 8, 9]. This ensures sufficient data points for time-series analysis. Some studies specifically require a 12 hour minimum ICU stay
CREATE TABLE MASTER_S_DEGREE.ADULT_ICU_PATIENTS_24H AS
SELECT DISTINCT
	AIP.SUBJECT_ID,
	AIP.STAY_ID
FROM
	MASTER_S_DEGREE.ADULT_ICU_PATIENTS AIP
	JOIN MIMICIV_ICU.ICUSTAYS IE ON AIP.STAY_ID = IE.STAY_ID
WHERE
	EXTRACT(
		EPOCH
		FROM
			(IE.OUTTIME - IE.INTIME)
	) / 3600 >= 24;

-- Estadia de pelo menos 24 horas
-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_ADULT_ICU_PATIENTS_24H_SUBJECT_ID ON MASTER_S_DEGREE.ADULT_ICU_PATIENTS_24H (SUBJECT_ID);

CREATE INDEX IDX_ADULT_ICU_PATIENTS_24H_STAY_ID ON MASTER_S_DEGREE.ADULT_ICU_PATIENTS_24H (STAY_ID);  
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
* **Sepsis Definition:**
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
  * **Sepsis-3 Criteria:** Many studies use the **Sepsis-3 criteria** to define sepsis, which includes suspected or documented infection, a Sequential Organ Failure Assessment (SOFA) score of 2 or more and microbial culture results indicating an infection. [8, 9, 10]
  CREATE TABLE MASTER_S_DEGREE.SEPSIS_PATIENTS AS
SELECT DISTINCT
	S3.SUBJECT_ID,
	S3.STAY_ID
FROM
	MIMICIV_DERIVED.SEPSIS3 S3
	JOIN MASTER_S_DEGREE.ADULT_ICU_PATIENTS_24H AIP ON S3.SUBJECT_ID = AIP.SUBJECT_ID
	AND S3.STAY_ID = AIP.STAY_ID
WHERE
	S3.SEPSIS3 = TRUE;

-- Indica que o paciente atende aos critérios Sepsis-3
-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_SEPSIS_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.SEPSIS_PATIENTS (SUBJECT_ID);

CREATE INDEX IDX_SEPSIS_PATIENTS_STAY_ID ON MASTER_S_DEGREE.SEPSIS_PATIENTS (STAY_ID);
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
--  * **Exclusion of Pre-existing Sepsis**: Some studies specifically **exclude patients who were admitted with sepsis** [11]. This is because the goal is often to predict the *onset* of sepsis, not its presence upon admission.
  CREATE TABLE MASTER_S_DEGREE.SEPSIS_PATIENTS AS
WITH
	SEPSIS_ONSET AS (
		SELECT
			S3.SUBJECT_ID,
			S3.STAY_ID,
			S3.SOFA_TIME,
			I.INTIME,
			EXTRACT(
				EPOCH
				FROM
					(S3.SOFA_TIME - I.INTIME)
			) / 3600 AS HOURS_SINCE_ADMISSION
		FROM
			MIMICIV_DERIVED.SEPSIS3 S3
			JOIN MIMICIV_ICU.ICUSTAYS I ON S3.STAY_ID = I.STAY_ID
		WHERE
			S3.SEPSIS3 = true -- Indica que o paciente atende aos critérios Sepsis-3
	)
SELECT DISTINCT
	SO.SUBJECT_ID,
	SO.STAY_ID
FROM
	SEPSIS_ONSET SO
	JOIN MASTER_S_DEGREE.ADULT_ICU_PATIENTS_24H AIP ON SO.SUBJECT_ID = AIP.SUBJECT_ID
	AND SO.STAY_ID = AIP.STAY_ID
WHERE
	SO.HOURS_SINCE_ADMISSION > 6;

-- Exclui casos de sepse identificados nas primeiras 6 horas após a admissão
-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_SEPSIS_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.SEPSIS_PATIENTS (SUBJECT_ID);

CREATE INDEX IDX_SEPSIS_PATIENTS_STAY_ID ON MASTER_S_DEGREE.SEPSIS_PATIENTS (STAY_ID);
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
  -- * **Septic Shock Identification:** While the query focuses on septic shock, most studies focus on sepsis as a precursor, and some do not distinguish between sepsis and septic shock [2].  In one study septic shock was defined by the need for vasopressors due to hypotension and an elevated lactate level [12].
  
  CREATE TABLE MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS AS
WITH
	SEPSIS_ONSET AS (
		SELECT
			S3.SUBJECT_ID,
			S3.STAY_ID,
			S3.SOFA_TIME,
			S3.SEPSIS3,
			I.INTIME,
			EXTRACT(
				EPOCH
				FROM
					(S3.SOFA_TIME - I.INTIME)
			) / 3600 AS HOURS_SINCE_ADMISSION
		FROM
			MIMICIV_DERIVED.SEPSIS3 S3
			JOIN MIMICIV_ICU.ICUSTAYS I ON S3.STAY_ID = I.STAY_ID
		WHERE
			S3.SEPSIS3 = TRUE -- Indica que o paciente atende aos critérios Sepsis-3
	),
	-- TODO: REVER ISSO AQUI
	VASOPRESSOR_USE AS (
		SELECT DISTINCT
			SUBJECT_ID,
			STAY_ID
		FROM
			MIMICIV_ICU.INPUTEVENTS
		WHERE
			ITEMID IN (
				SELECT
					ITEMID
				FROM
					MIMICIV_ICU.D_ITEMS
				WHERE
					LOWER(LABEL) LIKE '%vasopressor%'
			)
	),
	HIGH_LACTATE AS (
		SELECT DISTINCT
			SUBJECT_ID,
			STAY_ID
		FROM
			MIMICIV_ICU.CHARTEVENTS
		WHERE
			ITEMID IN (
				SELECT
					ITEMID
				FROM
					MIMICIV_ICU.D_ITEMS
				WHERE
					LOWER(LABEL) LIKE '%lactate%'
			)
			AND VALUENUM > 2 -- Assumindo que lactato > 2 mmol/L é considerado elevado
	)
SELECT DISTINCT
	SO.SUBJECT_ID,
	SO.STAY_ID,
	CASE
		WHEN V.SUBJECT_ID IS NOT NULL
		AND HL.SUBJECT_ID IS NOT NULL THEN 1
		ELSE 0
	END AS SEPTIC_SHOCK
FROM
	SEPSIS_ONSET SO
	JOIN MASTER_S_DEGREE.ADULT_ICU_PATIENTS_24H AIP ON SO.SUBJECT_ID = AIP.SUBJECT_ID
	AND SO.STAY_ID = AIP.STAY_ID
	LEFT JOIN VASOPRESSOR_USE V ON SO.SUBJECT_ID = V.SUBJECT_ID
	AND SO.STAY_ID = V.STAY_ID
	LEFT JOIN HIGH_LACTATE HL ON SO.SUBJECT_ID = HL.SUBJECT_ID
	AND SO.STAY_ID = HL.STAY_ID
WHERE
	SO.HOURS_SINCE_ADMISSION > 6;

-- Exclui casos de sepse identificados nas primeiras 6 horas após a admissão
-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_SEPSIS_SHOCK_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (SUBJECT_ID);

CREATE INDEX IDX_SEPSIS_SHOCK_PATIENTS_STAY_ID ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (STAY_ID);

CREATE INDEX IDX_SEPSIS_SHOCK_PATIENTS_SEPTIC_SHOCK ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (SEPTIC_SHOCK);
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
SELECT DISTINCT status FROM (
SELECT 
    ssp.subject_id,
    ssp.stay_id,
    ssp.septic_shock,
    CASE 
        WHEN sp.subject_id IS NULL THEN 'Only in SEPSIS_AND_SHOCK_PATIENTS'
        ELSE 'In both tables'
    END AS status
FROM MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS ssp
LEFT JOIN MASTER_S_DEGREE.SEPSIS_PATIENTS sp
ON ssp.subject_id = sp.subject_id AND ssp.stay_id = ssp.stay_id);

-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
* **Time-Series Data Extraction:**
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------  
  * **Vital Signs:** The primary focus is on extracting time-series data of vital signs. Common vital signs include heart rate (HR), respiratory rate (RR), oxygen saturation (SpO2), and mean arterial pressure (MAP) [13]. These are considered crucial for monitoring the progression of sepsis and are easily and regularly collected.
  * **Time Windows**: Data is usually extracted within specific time windows. For instance, vital signs are extracted for the **24 hours prior to a prediction point**[13, 14, 15, 16].  Some studies use a **6-hour sliding window** to capture temporal dependencies in vital signs [17]. Some models are trained to predict mortality or sepsis within a time frame (k) of 6, 24, or 48 hours [13, 18].
  * **Irregular Intervals:** Studies also acknowledge that vital signs are collected at irregular intervals in clinical settings, requiring a time-aware mechanism, such as a time decay function. [18]
  * **Forecasting:** Some studies forecast vital signs up to 3 hours into the future, using 6 hours of past data. [14]
  * **Lookback Window:** In one study, a lookback window of 6 hours of data was used to train a model to predict sepsis onset 4, 8, and 12 hours before it occurs. [19]
* **Data Cleaning & Imputation:**
  * **Error Records:** Studies identify and remove error records. For example, heart rate values outside the range of 30-260, respiratory rates outside 5-70, SpO2 outside of 0-100, and MAP outside of 10-200 are deleted. [13]
  * **Missing Values:** Missing data is handled using various techniques including:
    * **Forward fill:** Propagating the last available value forward. [20]
    * **Mean Imputation:** Replacing missing values with the mean value of the feature either across the entire dataset or on a per-patient basis. [21]
    * **Linear Imputation:** Estimating missing data points using the values before and after the gap. [21]
    * **Multiple Imputation:** A more advanced method, using other variables to impute missing values. [22]
    * **Masked Prediction:** Using a model's pre-training to fill in missing values based on the surrounding data. [18]
  * **Outlier Removal**: Outliers are removed from the dataset [23]. In one study, vital signs were limited to ranges deemed acceptable, such as a heart rate between 30 and 200 [24].
* **Feature Engineering**:
  * **Aggregation:** Time-series data is often aggregated over intervals, like hourly means or using maximum, minimum, and mean values for a window of time, often the first 24 hours [23, 25, 26].
  * **Trend calculation**: The change in the variable value over time is calculated and used as a feature [23].
  * **Clinical Scores:** Relevant clinical scores such as SOFA and SAPS II are computed and included as features [22, 27].
* **Data Splitting:**
  * The data is split into training, validation, and testing sets for model development [2]. Some studies use cross-validation to assess the model's generalizability [28].
By carefully selecting patients, extracting relevant time-series data, addressing data quality issues, and engineering informative features, these studies aim to build robust machine learning models that can effectively predict septic shock using the MIMIC-IV database.