* **Patient Selection**:
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
--  * **Adult Patients**: The studies consistently focus on **adult patients, typically defined as those 18 years or older**[1, 2, 3, 4]. Some studies use a lower age limit of 15 [5, 6]. This is a critical first step to ensure that the models are trained on a relevant patient population.
CREATE TABLE master_s_degree.temp_adult_patients AS
SELECT 
    subject_id,
    gender,
    anchor_age
FROM 
    mimiciv_hosp.patients
WHERE 
    anchor_age >= 18;

-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
--  * **ICU Admission**: Patients are selected based on their admission to the Intensive Care Unit (ICU). Often, only the first ICU admission is considered to prevent data duplication [4, 7, 8].
CREATE TABLE master_s_degree.temp_first_icu_stay AS
WITH first_icu_stay AS (
    SELECT 
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        icu.los,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime) AS icu_admission_order
    FROM 
        mimiciv_icu.icustays icu
    INNER JOIN 
        master_s_degree.temp_adult_patients ap
    ON 
        icu.subject_id = ap.subject_id
)
SELECT 
    fis.subject_id,
    fis.hadm_id,
    fis.stay_id,
    fis.intime,
    fis.outtime,
    fis.los,
    ap.gender,
    ap.anchor_age
FROM 
    first_icu_stay fis
INNER JOIN 
    master_s_degree.temp_adult_patients ap
ON 
    fis.subject_id = ap.subject_id
WHERE 
    fis.icu_admission_order = 1;

-- Criando índices para melhorar o desempenho
CREATE INDEX idx_temp_first_icu_stay_subject_id ON master_s_degree.temp_first_icu_stay(subject_id);
CREATE INDEX idx_temp_first_icu_stay_hadm_id ON master_s_degree.temp_first_icu_stay(hadm_id);
CREATE INDEX idx_temp_first_icu_stay_stay_id ON master_s_degree.temp_first_icu_stay(stay_id);
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
--  * **Minimum ICU Stay:** A **minimum length of stay in the ICU is often required, typically 24 hours or more**[3, 4, 7, 8, 9]. This ensures sufficient data points for time-series analysis. Some studies specifically require a 12 hour minimum ICU stay
-- Criando tabela temporária para pacientes com estadia mínima de 12 horas na UTI
CREATE TABLE master_s_degree.temp_icu_stay_min_12h AS
SELECT 
    fis.subject_id,
    fis.hadm_id,
    fis.stay_id,
    fis.intime,
    fis.outtime,
    fis.los,
    fis.gender,
    fis.anchor_age
FROM 
    master_s_degree.temp_first_icu_stay fis
WHERE 
    fis.los >= 12;  -- LOS (Length of Stay) é assumido estar em horas

-- Criando índices para melhorar o desempenho
CREATE INDEX idx_temp_icu_stay_min_12h_subject_id ON master_s_degree.temp_icu_stay_min_12h(subject_id);
CREATE INDEX idx_temp_icu_stay_min_12h_hadm_id ON master_s_degree.temp_icu_stay_min_12h(hadm_id);
CREATE INDEX idx_temp_icu_stay_min_12h_stay_id ON master_s_degree.temp_icu_stay_min_12h(stay_id);

-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
* **Sepsis Definition:**
  * **Sepsis-3 Criteria:** Many studies use the **Sepsis-3 criteria** to define sepsis, which includes suspected or documented infection, a Sequential Organ Failure Assessment (SOFA) score of 2 or more and microbial culture results indicating an infection. [8, 9, 10]
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
CREATE TABLE master_s_degree.temp_sofa_ge_2 AS
SELECT DISTINCT
    stay_id,
    starttime AS sofa_time
FROM 
    mimiciv_derived.sofa
WHERE 
    sofa_24hours >= 2;

-- 2. Identificar pacientes com suspeita de infecção
CREATE TABLE master_s_degree.temp_suspected_infection AS
SELECT DISTINCT
    subject_id,
    stay_id,
    suspected_infection_time
FROM 
    mimiciv_derived.sepsis3
WHERE 
    sepsis3 = true;

-- 3. Identificar pacientes com culturas positivas
CREATE TABLE master_s_degree.temp_positive_cultures AS
SELECT DISTINCT
    subject_id,
    charttime,
    org_name
FROM 
    mimiciv_hosp.microbiologyevents
WHERE 
    org_name IS NOT NULL;

-- 4. Combinar os critérios para Sepsis-3
CREATE TABLE master_s_degree.temp_sepsis3_patients AS
SELECT DISTINCT
    si.subject_id,
    si.stay_id,
    si.suspected_infection_time,
    sofa.sofa_time,
    pc.charttime AS positive_culture_time
FROM 
    master_s_degree.temp_suspected_infection si
INNER JOIN 
    master_s_degree.temp_sofa_ge_2 sofa ON si.stay_id = sofa.stay_id
INNER JOIN 
    master_s_degree.temp_positive_cultures pc ON si.subject_id = pc.subject_id
INNER JOIN
    master_s_degree.temp_icu_stay_min_12h icu ON si.stay_id = icu.stay_id
WHERE
    -- Ensure SOFA score is within 24 hours of suspected infection
    sofa.sofa_time BETWEEN si.suspected_infection_time - INTERVAL '24 hours' AND si.suspected_infection_time + INTERVAL '24 hours'
    -- Ensure positive culture is within 72 hours of suspected infection
    AND pc.charttime BETWEEN si.suspected_infection_time - INTERVAL '72 hours' AND si.suspected_infection_time + INTERVAL '72 hours';

-- Criar índices para melhorar o desempenho
CREATE INDEX idx_temp_sepsis3_patients_subject_id ON master_s_degree.temp_sepsis3_patients(subject_id);
CREATE INDEX idx_temp_sepsis3_patients_stay_id ON master_s_degree.temp_sepsis3_patients(stay_id);
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  * **Exclusion of Pre-existing Sepsis**: Some studies specifically **exclude patients who were admitted with sepsis** [11]. This is because the goal is often to predict the *onset* of sepsis, not its presence upon admission.
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Criando tabela temporária para pacientes com sepsis, excluindo aqueles com sepsis na admissão
CREATE TABLE master_s_degree.temp_sepsis3_patients_exclude_admission AS
SELECT 
    s.subject_id,
    s.stay_id,
    s.suspected_infection_time,
    s.sofa_time,
    s.positive_culture_time,
    i.intime AS icu_admission_time
FROM 
    master_s_degree.temp_sepsis3_patients s
INNER JOIN 
    master_s_degree.temp_icu_stay_min_12h i ON s.stay_id = i.stay_id
WHERE 
    -- Excluir pacientes cuja suspeita de infecção ocorreu nas primeiras 6 horas após a admissão na UTI
    s.suspected_infection_time > i.intime + INTERVAL '6 hours';

-- Criando índices para melhorar o desempenho
CREATE INDEX idx_temp_sepsis3_exclude_admission_subject_id ON master_s_degree.temp_sepsis3_patients_exclude_admission(subject_id);
CREATE INDEX idx_temp_sepsis3_exclude_admission_stay_id ON master_s_degree.temp_sepsis3_patients_exclude_admission(stay_id);
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  * **Septic Shock Identification:** While the query focuses on septic shock, most studies focus on sepsis as a precursor, and some do not distinguish between sepsis and septic shock [2].  In one study septic shock was defined by the need for vasopressors due to hypotension and an elevated lactate level [12].
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- FOI UTILIZADO ESSA
temp_septic_shock_patients
			-- Criando tabela temporária para pacientes com choque séptico
			CREATE TABLE master_s_degree.temp_septic_shock_patients AS
			WITH vasopressor_patients AS (
				SELECT DISTINCT
					stay_id,
					starttime AS vasopressor_starttime
				FROM
					mimiciv_icu.inputevents
				WHERE
					itemid IN (
						221906, -- norepinephrine
						221289, -- epinephrine
						221662, -- dopamine
						221653  -- phenylephrine
					)
			),
			hypotension_patients AS (
				SELECT DISTINCT
					stay_id,
					charttime AS hypotension_time
				FROM
					mimiciv_icu.chartevents
				WHERE
					itemid IN (
						220052, -- Arterial BP Mean
						220181  -- Non Invasive Blood Pressure mean
					)
					AND valuenum < 65 -- MAP < 65 mmHg is considered hypotension
			),
			high_lactate_patients AS (
				SELECT DISTINCT
					stay_id,
					charttime AS high_lactate_time
				FROM
					mimiciv_icu.chartevents
				WHERE
					itemid IN (
						223835, -- Lactate
						225668  -- Arterial Lactate
					)
					AND valuenum > 2 -- Lactate > 2 mmol/L is considered elevated
			)
			SELECT DISTINCT
				s.subject_id,
				s.stay_id,
				s.suspected_infection_time,
				s.sofa_time,
				s.positive_culture_time,
				v.vasopressor_starttime,
				h.hypotension_time,
				l.high_lactate_time
			FROM 
				master_s_degree.temp_sepsis3_patients_exclude_admission s
			INNER JOIN 
				vasopressor_patients v ON s.stay_id = v.stay_id
			INNER JOIN 
				hypotension_patients h ON s.stay_id = h.stay_id
			INNER JOIN 
				high_lactate_patients l ON s.stay_id = l.stay_id
			WHERE
				-- Ensure vasopressor use, hypotension, and high lactate occur within 24 hours of each other
				v.vasopressor_starttime BETWEEN h.hypotension_time - INTERVAL '24 hours' AND h.hypotension_time + INTERVAL '24 hours'
				AND l.high_lactate_time BETWEEN h.hypotension_time - INTERVAL '24 hours' AND h.hypotension_time + INTERVAL '24 hours';

			-- Criando índices para melhorar o desempenho
			CREATE INDEX idx_temp_septic_shock_patients_subject_id ON master_s_degree.temp_septic_shock_patients(subject_id);
			CREATE INDEX idx_temp_septic_shock_patients_stay_id ON master_s_degree.temp_septic_shock_patients(stay_id);


-- MODIFICADA MAS NAO UTIILIZADA

CREATE TABLE master_s_degree.temp_septic_shock_patients AS
			WITH vasopressor_patients AS (
				SELECT DISTINCT
					stay_id,
					starttime AS vasopressor_starttime
				FROM
					mimiciv_icu.inputevents
				WHERE
					itemid IN (
						221906, -- norepinephrine
						221289, -- epinephrine
						221662, -- dopamine
						221653  -- phenylephrine
					)
			),
			hypotension_patients AS (
				SELECT DISTINCT
					stay_id,
					charttime AS hypotension_time
				FROM
					mimiciv_icu.chartevents
				WHERE
					itemid IN (
						220052, -- Arterial BP Mean
						220181  -- Non Invasive Blood Pressure mean
					)
					AND valuenum < 65 -- MAP < 65 mmHg is considered hypotension
			),
			high_lactate_patients AS (
				SELECT DISTINCT
					stay_id,
					charttime AS high_lactate_time
				FROM
					mimiciv_icu.chartevents
				WHERE
					itemid IN (
						223835, -- Lactate
						225668  -- Arterial Lactate
					)
					AND valuenum > 2 -- Lactate > 2 mmol/L is considered elevated
			)
			SELECT DISTINCT
				s.subject_id,
				s.stay_id
			FROM 
				master_s_degree.temp_sepsis3_patients_exclude_admission s
			INNER JOIN 
				vasopressor_patients v ON s.stay_id = v.stay_id
			INNER JOIN 
				hypotension_patients h ON s.stay_id = h.stay_id
			INNER JOIN 
				high_lactate_patients l ON s.stay_id = l.stay_id
			WHERE
				-- Ensure vasopressor use, hypotension, and high lactate occur within 24 hours of each other
				v.vasopressor_starttime BETWEEN h.hypotension_time - INTERVAL '24 hours' AND h.hypotension_time + INTERVAL '24 hours'
				AND l.high_lactate_time BETWEEN h.hypotension_time - INTERVAL '24 hours' AND h.hypotension_time + INTERVAL '24 hours';

			-- Criando índices para melhorar o desempenho
			CREATE INDEX idx_temp_septic_shock_patients_subject_id ON master_s_degree.temp_septic_shock_patients(subject_id);
			CREATE INDEX idx_temp_septic_shock_patients_stay_id ON master_s_degree.temp_septic_shock_patients(stay_id);



-- ESSA NÃO FOI UTILIZADA
-- 1. Pacientes que receberam vasopressores
CREATE TABLE master_s_degree.temp_vasopressor_patients AS
SELECT DISTINCT
    stay_id,
    starttime AS vasopressor_starttime
FROM
    mimiciv_icu.inputevents
WHERE
    itemid IN (
        221906, -- norepinephrine
        221289, -- epinephrine
        221662, -- dopamine
        221653  -- phenylephrine
    );

CREATE INDEX idx_temp_vasopressor_patients_stay_id ON master_s_degree.temp_vasopressor_patients(stay_id);

-- 2. Pacientes com hipotensão
CREATE TABLE master_s_degree.temp_hypotension_patients AS
SELECT DISTINCT
    stay_id,
    charttime AS hypotension_time
FROM
    mimiciv_icu.chartevents
WHERE
    itemid IN (
        220052, -- Arterial BP Mean
        220181  -- Non Invasive Blood Pressure mean
    )
    AND valuenum < 65; -- MAP < 65 mmHg is considered hypotension

CREATE INDEX idx_temp_hypotension_patients_stay_id ON master_s_degree.temp_hypotension_patients(stay_id);

-- 3. Pacientes com níveis elevados de lactato
CREATE TABLE master_s_degree.temp_high_lactate_patients AS
SELECT DISTINCT
    stay_id,
    charttime AS high_lactate_time
FROM
    mimiciv_icu.chartevents
WHERE
    itemid IN (
        223835, -- Lactate
        225668  -- Arterial Lactate
    )
    AND valuenum > 2; -- Lactate > 2 mmol/L is considered elevated

CREATE INDEX idx_temp_high_lactate_patients_stay_id ON master_s_degree.temp_high_lactate_patients(stay_id);

-- 4. Combinando as informações para identificar pacientes com choque séptico
CREATE TABLE master_s_degree.temp_septic_shock_patients AS
SELECT DISTINCT
    s.subject_id,
    s.stay_id,
    s.suspected_infection_time,
    s.sofa_time,
    s.positive_culture_time,
    v.vasopressor_starttime,
    h.hypotension_time,
    l.high_lactate_time
FROM 
    master_s_degree.temp_sepsis3_patients_exclude_admission s
INNER JOIN 
    master_s_degree.temp_vasopressor_patients v ON s.stay_id = v.stay_id
INNER JOIN 
    master_s_degree.temp_hypotension_patients h ON s.stay_id = h.stay_id
INNER JOIN 
    master_s_degree.temp_high_lactate_patients l ON s.stay_id = l.stay_id
WHERE
    -- Ensure vasopressor use, hypotension, and high lactate occur within 24 hours of each other
    v.vasopressor_starttime BETWEEN h.hypotension_time - INTERVAL '24 hours' AND h.hypotension_time + INTERVAL '24 hours'
    AND l.high_lactate_time BETWEEN h.hypotension_time - INTERVAL '24 hours' AND h.hypotension_time + INTERVAL '24 hours';

CREATE INDEX idx_temp_septic_shock_patients_subject_id ON master_s_degree.temp_septic_shock_patients(subject_id);
CREATE INDEX idx_temp_septic_shock_patients_stay_id ON master_s_degree.temp_septic_shock_patients(stay_id);


-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
-- 1. Primeiro, criamos a tabela com pacientes adultos elegíveis da UTI
CREATE TABLE master_s_degree.temp_eligible_icu_patients AS
SELECT ap.subject_id, ap.gender, ap.anchor_age, fis.stay_id, 
       fis.intime AS icu_admission_time, fis.outtime AS icu_discharge_time, 
       fis.los AS icu_length_of_stay
FROM master_s_degree.temp_adult_patients ap
INNER JOIN master_s_degree.temp_first_icu_stay fis ON ap.subject_id = fis.subject_id
INNER JOIN master_s_degree.temp_icu_stay_min_12h icu ON fis.stay_id = icu.stay_id
WHERE ap.anchor_age >= 18 AND fis.los >= 12;

CREATE INDEX idx_eligible_icu_patients_stay_id ON master_s_degree.temp_eligible_icu_patients(stay_id);

-- 2. Em seguida, identificamos pacientes com sepse, sem incluir colunas adicionais
CREATE TABLE master_s_degree.temp_eligible_sepsis_patients AS
SELECT DISTINCT 
    eip.*,
    CASE WHEN s3p.stay_id IS NOT NULL THEN true ELSE false END AS has_sepsis
FROM 
    master_s_degree.temp_eligible_icu_patients eip
LEFT JOIN 
    master_s_degree.temp_sepsis3_patients_exclude_admission s3p 
ON 
    eip.stay_id = s3p.stay_id;

CREATE INDEX idx_eligible_sepsis_patients_stay_id ON master_s_degree.temp_eligible_sepsis_patients(stay_id);

-- ---------------------------------------------
-- PACIENTES ADULTOS
-- SELECT subject_id from master_s_degree.temp_adult_patients limit 10;

-- PACIENTES ADULTOS - PRIMEIRA INTERNACAO
-- SELECT DISTINCT subject_id, stay_id from master_s_degree.temp_first_icu_stay where subject_id in (SELECT subject_id from master_s_degree.temp_adult_patients) limit 10;

-- PACIENTES MINIMO 12h
-- TODO entender como colocar a tupla (subject_id, stay_id)
-- SELECT DISTINCT subject_id, stay_id FROM master_s_degree.temp_icu_stay_min_12h WHERE stay_id in (
-- SELECT DISTINCT stay_id from master_s_degree.temp_first_icu_stay where subject_id in (SELECT subject_id from master_s_degree.temp_adult_patients)
-- ) limit 10;

-- SEPSE TIRANDO SEPSE NA ADMISSAO
-- SELECT DISTINCT subject_id, stay_id FROM master_s_degree.temp_sepsis3_patients_exclude_admission WHERE (CINSIDERAR MINIMO 12h)

SELECT DISTINCT subject_id, stay_id FROM master_s_degree.temp_septic_shock_patients LIMIT 10
-- -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
* **Time-Series Data Extraction:**
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