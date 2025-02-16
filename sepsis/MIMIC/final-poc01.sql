--   * **Adult Patients**: The studies consistently focus on **adult patients, typically defined as those 18 years or older**[1, 2, 3, 4]. Some studies use a lower age limit of 15 [5, 6]. This is a critical first step to ensure that the models are trained on a relevant patient population.

-- Criar tabela de pacientes adultos
CREATE TABLE MASTER_S_DEGREE.ADULT_PATIENTS AS
WITH
    ADULT_ADMISSIONS AS (
        SELECT DISTINCT
            ADM.SUBJECT_ID,
            EXTRACT(YEAR FROM ADM.ADMITTIME::TIMESTAMP) - P.ANCHOR_YEAR + P.ANCHOR_AGE AS CALCULATED_AGE
        FROM
            MIMICIV_HOSP.ADMISSIONS ADM
            JOIN MIMICIV_HOSP.PATIENTS P ON ADM.SUBJECT_ID = P.SUBJECT_ID
        WHERE
            EXTRACT(YEAR FROM ADM.ADMITTIME::TIMESTAMP) - P.ANCHOR_YEAR + P.ANCHOR_AGE >= 18
    )
SELECT DISTINCT
    SUBJECT_ID
FROM
    ADULT_ADMISSIONS;

-- Criar índice para melhorar a performance de consultas futuras
CREATE INDEX IDX_ADULT_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.ADULT_PATIENTS (SUBJECT_ID);


-- -----------------------------------------------------------------------------------------------------------------------------------------------------
--   * **ICU Admission**: Patients are selected based on their admission to the Intensive Care Unit (ICU). Often, only the first ICU admission is considered to prevent data duplication [4, 7, 8].

-- Criar tabela de primeiras admissões na UTI
--
CREATE TABLE MASTER_S_DEGREE.FIRST_ICU_STAYS AS
WITH RANKED_ICU_STAYS AS (
    SELECT 
        icu.SUBJECT_ID,
        icu.STAY_ID,
        icu.INTIME,
        ROW_NUMBER() OVER (PARTITION BY icu.SUBJECT_ID ORDER BY icu.INTIME) AS ICU_ADMISSION_ORDER
    FROM 
        MIMICIV_ICU.ICUSTAYS icu
)
SELECT 
    SUBJECT_ID,
    STAY_ID
FROM 
    RANKED_ICU_STAYS
WHERE 
    ICU_ADMISSION_ORDER = 1;

-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_FIRST_ICU_STAYS_SUBJECT_ID ON MASTER_S_DEGREE.FIRST_ICU_STAYS (SUBJECT_ID);
CREATE INDEX IDX_FIRST_ICU_STAYS_STAY_ID ON MASTER_S_DEGREE.FIRST_ICU_STAYS (STAY_ID);





-- -- -----------------------------------------------------------------------------------------------------------------------------------------------------
--   * **Minimum ICU Stay:** A **minimum length of stay in the ICU is often required, typically 24 hours or more**[3, 4, 7, 8, 9]. This ensures sufficient data points for time-series analysis. Some studies specifically require a 12 hour minimum ICU stay

-- Criar tabela de estadias na UTI com duração mínima
CREATE TABLE MASTER_S_DEGREE.ICU_STAYS_MIN_DURATION AS
WITH RANKED_ICU_STAYS AS (
    SELECT 
        icu.SUBJECT_ID,
        icu.STAY_ID,
        icu.INTIME,
        icu.OUTTIME,
        EXTRACT(EPOCH FROM (icu.OUTTIME - icu.INTIME)) / 3600 AS LOS_HOURS,
        ROW_NUMBER() OVER (PARTITION BY icu.SUBJECT_ID ORDER BY icu.INTIME) AS ICU_ADMISSION_ORDER
    FROM 
        MIMICIV_ICU.ICUSTAYS icu
),
FILTERED_STAYS AS (
    SELECT 
        SUBJECT_ID,
        STAY_ID,
        LOS_HOURS,
        ICU_ADMISSION_ORDER,
        CASE 
            WHEN LOS_HOURS >= 24 THEN 'GTE_24H'
            WHEN LOS_HOURS >= 12 THEN 'GTE_12H'
            ELSE 'LT_12H'
        END AS DURATION_CATEGORY
    FROM 
        RANKED_ICU_STAYS
    WHERE 
        LOS_HOURS >= 12 AND ICU_ADMISSION_ORDER = 1
)
SELECT 
    SUBJECT_ID,
    STAY_ID,
    LOS_HOURS,
    DURATION_CATEGORY
FROM 
    FILTERED_STAYS;

-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_ICU_STAYS_MIN_DURATION_SUBJECT_ID ON MASTER_S_DEGREE.ICU_STAYS_MIN_DURATION (SUBJECT_ID);
CREATE INDEX IDX_ICU_STAYS_MIN_DURATION_STAY_ID ON MASTER_S_DEGREE.ICU_STAYS_MIN_DURATION (STAY_ID);
CREATE INDEX IDX_ICU_STAYS_MIN_DURATION_DURATION ON MASTER_S_DEGREE.ICU_STAYS_MIN_DURATION (DURATION_CATEGORY);



-- -----------------------------------------------------------------------------------------------------------------------------------------------------
--   * **Sepsis-3 Criteria:** Many studies use the **Sepsis-3 criteria** to define sepsis, which includes suspected or documented infection, a Sequential Organ Failure Assessment (SOFA) score of 2 or more and microbial culture results indicating an infection. [8, 9, 10]

-- Criar tabela de pacientes com a flag de sepse baseada nos critérios Sepsis-3
CREATE TABLE MASTER_S_DEGREE.SEPSIS_3_PATIENTS AS
SELECT DISTINCT
    subject_id,
    stay_id,
    sepsis3 AS is_sepsis  -- Renomeando para maior clareza, mas você pode manter 'sepsis3' se preferir
FROM
    mimiciv_derived.sepsis3;

-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_SEPSIS_3_PATIENTS_SUBJECT_ID ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS (subject_id);
CREATE INDEX IDX_SEPSIS_3_PATIENTS_STAY_ID ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS (stay_id);
CREATE INDEX IDX_SEPSIS_3_PATIENTS_IS_SEPSIS ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS (is_sepsis);

-- -----------------------------------------------------------------------------------------------------------------------------------------------------
--   * **Exclusion of Pre-existing Sepsis**: Some studies specifically **exclude patients who were admitted with sepsis** [11]. This is because the goal is often to predict the *onset* of sepsis, not its presence upon admission.

CREATE TABLE MASTER_S_DEGREE.SEPSIS_3_PATIENTS_EXCLUDED_PREEXISTING AS
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
            ) / 3600 AS HOURS_SINCE_ADMISSION,
            S3.SEPSIS3
        FROM
            MIMICIV_DERIVED.SEPSIS3 S3
            JOIN MIMICIV_ICU.ICUSTAYS I ON S3.STAY_ID = I.STAY_ID
    )
SELECT DISTINCT
    SO.SUBJECT_ID,
    SO.STAY_ID,
    SO.SEPSIS3 AS IS_SEPSIS,
    CASE 
        WHEN SO.SEPSIS3 = true AND SO.HOURS_SINCE_ADMISSION > 6 THEN 1
        WHEN SO.SEPSIS3 = false THEN 0
        ELSE NULL  -- Indica sepse pré-existente ou muito precoce
    END AS IS_NEW_SEPSIS
FROM
    SEPSIS_ONSET SO;

-- Criar índices para melhorar a performance de consultas futuras
CREATE INDEX IDX_SEPSIS_3_EXCLUDED_SUBJECT_ID ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS_EXCLUDED_PREEXISTING (SUBJECT_ID);
CREATE INDEX IDX_SEPSIS_3_EXCLUDED_STAY_ID ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS_EXCLUDED_PREEXISTING (STAY_ID);
CREATE INDEX IDX_SEPSIS_3_EXCLUDED_IS_SEPSIS ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS_EXCLUDED_PREEXISTING (IS_SEPSIS);
CREATE INDEX IDX_SEPSIS_3_EXCLUDED_IS_NEW_SEPSIS ON MASTER_S_DEGREE.SEPSIS_3_PATIENTS_EXCLUDED_PREEXISTING (IS_NEW_SEPSIS);

-- -----------------------------------------------------------------------------------------------------------------------------------------------------
--  * **Septic Shock Identification:** While the query focuses on septic shock, most studies focus on sepsis as a precursor, and some do not distinguish between sepsis and septic shock [2].  In one study septic shock was defined by the need for vasopressors due to hypotension and an elevated lactate level [12].

-- Criar tabela temporária para uso de vasopressores
CREATE TABLE MASTER_S_DEGREE.TMP_VASOPRESSOR_USE AS
SELECT DISTINCT
    ie.subject_id,
    ie.stay_id,
    1 AS on_vasopressor
FROM 
    mimiciv_icu.inputevents ie
WHERE 
    ie.itemid IN (
        221906, -- norepinephrine
        221289  -- phenylephrine
        -- Adicione outros IDs de vasopressores conforme necessário
    );

CREATE INDEX idx_tmp_vasopressor_subject_id ON MASTER_S_DEGREE.TMP_VASOPRESSOR_USE (subject_id);
CREATE INDEX idx_tmp_vasopressor_stay_id ON MASTER_S_DEGREE.TMP_VASOPRESSOR_USE (stay_id);

-- Criar tabela temporária para hipotensão
CREATE TABLE MASTER_S_DEGREE.TMP_HYPOTENSION AS
SELECT DISTINCT
    ce.subject_id,
    ce.stay_id,
    1 AS has_hypotension
FROM 
    mimiciv_icu.chartevents ce
WHERE 
    ce.itemid IN (220052, 220181) -- Systolic and Mean Arterial Pressure
    AND ce.valuenum < 65; -- Threshold for hypotension

CREATE INDEX idx_tmp_hypotension_subject_id ON MASTER_S_DEGREE.TMP_HYPOTENSION (subject_id);
CREATE INDEX idx_tmp_hypotension_stay_id ON MASTER_S_DEGREE.TMP_HYPOTENSION (stay_id);

-- Criar tabela temporária para lactato elevado
CREATE TABLE MASTER_S_DEGREE.TMP_HIGH_LACTATE AS
SELECT DISTINCT
    ce.subject_id,
    ce.stay_id,
    1 AS has_high_lactate
FROM 
    mimiciv_icu.chartevents ce
WHERE 
    ce.itemid = 223835 -- Lactate
    AND ce.valuenum > 2; -- Threshold for elevated lactate

CREATE INDEX idx_tmp_high_lactate_subject_id ON MASTER_S_DEGREE.TMP_HIGH_LACTATE (subject_id);
CREATE INDEX idx_tmp_high_lactate_stay_id ON MASTER_S_DEGREE.TMP_HIGH_LACTATE (stay_id);

-- Criar tabela final combinando todas as informações
CREATE TABLE MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS AS
SELECT 
    sep.SUBJECT_ID,
    sep.STAY_ID,
    sep.IS_SEPSIS,
    sep.IS_NEW_SEPSIS,
    CASE
        WHEN sep.IS_SEPSIS = true AND v.on_vasopressor = 1 AND (h.has_hypotension = 1 OR l.has_high_lactate = 1) THEN 1
        ELSE 0
    END AS IS_SEPTIC_SHOCK
FROM 
    MASTER_S_DEGREE.SEPSIS_3_PATIENTS_EXCLUDED_PREEXISTING sep
LEFT JOIN 
    MASTER_S_DEGREE.TMP_VASOPRESSOR_USE v ON sep.STAY_ID = v.stay_id
LEFT JOIN 
    MASTER_S_DEGREE.TMP_HYPOTENSION h ON sep.STAY_ID = h.stay_id
LEFT JOIN 
    MASTER_S_DEGREE.TMP_HIGH_LACTATE l ON sep.STAY_ID = l.stay_id;

-- Criar índices na tabela final
CREATE INDEX idx_sepsis_shock_subject_id ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (SUBJECT_ID);
CREATE INDEX idx_sepsis_shock_stay_id ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (STAY_ID);
CREATE INDEX idx_sepsis_shock_is_sepsis ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (IS_SEPSIS);
CREATE INDEX idx_sepsis_shock_is_new_sepsis ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (IS_NEW_SEPSIS);
CREATE INDEX idx_sepsis_shock_is_septic_shock ON MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS (IS_SEPTIC_SHOCK);


-- ------------------------------------------------------------------------------------------------------------------------------------
-- JOIN ALL TABLES

CREATE TABLE MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS AS
SELECT 
    ap.subject_id,
    fis.stay_id,
    COALESCE(ssp.IS_SEPSIS, false) AS is_sepsis,
    CASE
        WHEN ssp.IS_SEPSIS IS NULL THEN -1
        ELSE COALESCE(ssp.IS_NEW_SEPSIS, 0)
    END AS is_new_sepsis,
    COALESCE(ssp.IS_SEPTIC_SHOCK, 0) AS is_septic_shock,
    ismd.los_hours,
    ismd.duration_category
FROM 
    MASTER_S_DEGREE.adult_patients ap
JOIN 
    MASTER_S_DEGREE.first_icu_stays fis ON ap.subject_id = fis.subject_id
LEFT JOIN 
    MASTER_S_DEGREE.SEPSIS_AND_SHOCK_PATIENTS ssp ON fis.stay_id = ssp.STAY_ID
LEFT JOIN
    MASTER_S_DEGREE.icu_stays_min_duration ismd ON fis.stay_id = ismd.stay_id;

-- Criar índices na tabela final
CREATE INDEX idx_all_adult_icu_subject_id ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (subject_id);
CREATE INDEX idx_all_adult_icu_stay_id ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (stay_id);
CREATE INDEX idx_all_adult_icu_is_sepsis ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (is_sepsis);
CREATE INDEX idx_all_adult_icu_is_new_sepsis ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (is_new_sepsis);
CREATE INDEX idx_all_adult_icu_is_septic_shock ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (is_septic_shock);
CREATE INDEX idx_all_adult_icu_los_hours ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (los_hours);
CREATE INDEX idx_all_adult_icu_duration_category ON MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS (duration_category);
-- --
SELECT
    CASE
        WHEN is_sepsis = false THEN 'Sem sepse'
        WHEN is_new_sepsis = 1 THEN 'Sepse nova (> 6 horas)'
        WHEN is_new_sepsis = 0 THEN 'Sepse precoce ou pré-existente (≤ 6 horas)'
        ELSE 'Erro de classificação'
    END AS sepsis_category,
    CASE
        WHEN is_septic_shock = 1 THEN 'Com choque séptico'
        ELSE 'Sem choque séptico'
    END AS shock_status,
    COUNT(*) as count
FROM MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS
GROUP BY 1, 2
ORDER BY 1, 2;
-- --

| is_sepsis | is_new_sepsis | is_septic_shock | Cenário | Explicação |
|-----------|---------------|-----------------|---------|------------|
| true      | 1             | 0               | Sepse Nova sem Choque Séptico | O paciente desenvolveu sepse após 6 horas da admissão na UTI, mas não progrediu para choque séptico. Isso pode indicar uma detecção e tratamento precoces ou uma forma menos grave de sepse. |
| true      | 0             | 1               | Sepse Precoce/Pré-existente com Choque Séptico | O paciente tinha sepse na admissão ou a desenvolveu nas primeiras 6 horas, e progrediu para choque séptico. Isso sugere um caso mais grave ou rapidamente progressivo. |
| true      | 0             | 0               | Sepse Precoce/Pré-existente sem Choque Séptico | O paciente tinha sepse na admissão ou a desenvolveu nas primeiras 6 horas, mas não progrediu para choque séptico. Pode indicar um tratamento eficaz ou uma forma menos grave de sepse. |
| true      | 1             | 1               | Sepse Nova com Choque Séptico | O paciente desenvolveu sepse após 6 horas da admissão e posteriormente progrediu para choque séptico. Isso pode sugerir uma rápida deterioração ou uma resposta inadequada ao tratamento inicial. |
| false     | -1            | 0               | Sem Sepse | O paciente não desenvolveu sepse durante sua estadia na UTI. Este grupo serve como controle para comparações com pacientes sépticos. |

Observações adicionais:

1. A categoria "Sepse Nova" (is_new_sepsis = 1) representa casos que se desenvolveram durante a internação na UTI, possivelmente devido a complicações do tratamento ou à condição subjacente do paciente.

2. A categoria "Sepse Precoce/Pré-existente" (is_new_sepsis = 0) inclui tanto pacientes que chegaram à UTI com sepse quanto aqueles que a desenvolveram muito rapidamente após a admissão.

3. A progressão para choque séptico (is_septic_shock = 1) é um indicador de gravidade e pode estar associada a piores resultados.

4. Pacientes sem sepse (is_sepsis = false) formam um grupo de controle importante para comparações de resultados e fatores de risco.

Esta tabela pode ser usada como referência rápida para interpretar os dados em suas análises e ao comunicar resultados. Ela também pode guiar análises mais profundas, como:

- Comparar taxas de mortalidade entre os diferentes cenários.
- Analisar o tempo de internação na UTI para cada grupo.
- Investigar fatores que podem predispor pacientes a desenvolver sepse nova durante a internação.
- Examinar as diferenças nos tratamentos e intervenções entre os grupos.
- Avaliar o impacto do tempo de início da sepse (nova vs. precoce/pré-existente) nos resultados clínicos.


-- -------------------------------------------------------------------------------------------------
-- -------------------------------------------------------------------------------------------------
-- -------------------------------------------------------------------------------------------------
-- * **Time-Series Data Extraction:**
--   * **Vital Signs:** The primary focus is on extracting time-series data of vital signs. Common vital signs include heart rate (HR), respiratory rate (RR), oxygen saturation (SpO2), and mean arterial pressure (MAP) [13]. These are considered crucial for monitoring the progression of sepsis and are easily and regularly collected.

-- Criar tabela temporária
-- Criar tabela temporária
CREATE TABLE MASTER_S_DEGREE.tmp_vital_signs (
    subject_id INT,
    stay_id INT,
    is_sepsis BOOLEAN,
    is_new_sepsis INT,
    is_septic_shock INT,
    charttime TIMESTAMP,
    hour_bucket TIMESTAMP,
    heart_rate FLOAT,
    respiratory_rate FLOAT,
    spo2 FLOAT,
    map FLOAT
);

-- Preencher a tabela temporária
INSERT INTO MASTER_S_DEGREE.tmp_vital_signs
SELECT 
    aap.subject_id,
    aap.stay_id,
    aap.is_sepsis,
    aap.is_new_sepsis,
    aap.is_septic_shock,
    ce.charttime,
    DATE_TRUNC('hour', ce.charttime) AS hour_bucket,
    CASE WHEN ce.itemid IN (220045, 211) THEN ce.valuenum END AS heart_rate,
    CASE WHEN ce.itemid IN (220210, 618) THEN ce.valuenum END AS respiratory_rate,
    CASE WHEN ce.itemid IN (220277, 646) THEN ce.valuenum END AS spo2,
    CASE WHEN ce.itemid IN (220052, 456) THEN ce.valuenum END AS map
FROM 
    MASTER_S_DEGREE.ALL_ADULT_ICU_PATIENTS aap
JOIN 
    mimiciv_icu.chartevents ce ON aap.stay_id = ce.stay_id
WHERE 
    ce.itemid IN (220045, 211, 220210, 618, 220277, 646, 220052, 456)
    AND ce.valuenum IS NOT NULL;

-- Criar índices na tabela temporária para melhorar o desempenho da consulta final
CREATE INDEX idx_tmp_vital_signs_subject_id ON MASTER_S_DEGREE.tmp_vital_signs (subject_id);
CREATE INDEX idx_tmp_vital_signs_stay_id ON MASTER_S_DEGREE.tmp_vital_signs (stay_id);
CREATE INDEX idx_tmp_vital_signs_hour_bucket ON MASTER_S_DEGREE.tmp_vital_signs (hour_bucket);

-- ---------------------------
-- Criar tabela temporária para SOFA scores

-- Recriar a tabela tmp_sofa_score
DROP TABLE IF EXISTS MASTER_S_DEGREE.tmp_sofa_score;
CREATE TABLE MASTER_S_DEGREE.tmp_sofa_score AS
SELECT 
    stay_id,
    DATE_TRUNC('hour', starttime) AS hour_bucket,
    sofa_24hours AS sofa_24hours
FROM 
    mimiciv_derived.sofa
GROUP BY 
    stay_id, DATE_TRUNC('hour', starttime), sofa_24hours;

-- Criar índices na tabela temporária
CREATE INDEX idx_tmp_sofa_score_stay_id ON MASTER_S_DEGREE.tmp_sofa_score (stay_id);
CREATE INDEX idx_tmp_sofa_score_hour_bucket ON MASTER_S_DEGREE.tmp_sofa_score (hour_bucket);

-- ---------------------------
-- TODO: ESTÁ FALTANDO ALGUNS (65366 x 35352)
CREATE TABLE MASTER_S_DEGREE.HOURLY_VITAL_SIGNS AS
WITH sepsis_onset AS (
    SELECT 
        stay_id,
        MIN(CASE WHEN is_sepsis = true THEN hour_bucket END) AS sepsis_onset_time
    FROM 
        MASTER_S_DEGREE.tmp_vital_signs
    GROUP BY 
        stay_id
)

SELECT 
    tvs.subject_id,
    tvs.stay_id,
    tvs.is_sepsis,
    tvs.is_new_sepsis,
    tvs.is_septic_shock,
    tvs.hour_bucket,
    
    -- Heart Rate
    AVG(tvs.heart_rate) AS avg_hr,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tvs.heart_rate) AS median_hr,
    MIN(tvs.heart_rate) AS min_hr,
    MAX(tvs.heart_rate) AS max_hr,
    
    -- Respiratory Rate
    AVG(tvs.respiratory_rate) AS avg_rr,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tvs.respiratory_rate) AS median_rr,
    MIN(tvs.respiratory_rate) AS min_rr,
    MAX(tvs.respiratory_rate) AS max_rr,
    
    -- SpO2
    AVG(tvs.spo2) AS avg_spo2,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tvs.spo2) AS median_spo2,
    MIN(tvs.spo2) AS min_spo2,
    MAX(tvs.spo2) AS max_spo2,
    
    -- MAP
    AVG(tvs.map) AS avg_map,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tvs.map) AS median_map,
    MIN(tvs.map) AS min_map,
    MAX(tvs.map) AS max_map,

    -- SOFA Score (24 hours)
    ss.sofa_24hours,

    -- Sepsis Flag
    CASE 
        WHEN so.sepsis_onset_time IS NULL THEN -1
        WHEN tvs.hour_bucket < so.sepsis_onset_time THEN 0
        ELSE 1
    END AS sepsis_flag,

    -- Countdown to Sepsis
    CASE 
        WHEN so.sepsis_onset_time IS NULL THEN -1
        ELSE EXTRACT(EPOCH FROM (tvs.hour_bucket - so.sepsis_onset_time))/3600
    END AS hours_to_sepsis

FROM 
    MASTER_S_DEGREE.tmp_vital_signs tvs
LEFT JOIN 
    MASTER_S_DEGREE.tmp_sofa_score ss ON tvs.stay_id = ss.stay_id AND tvs.hour_bucket = ss.hour_bucket
LEFT JOIN
    sepsis_onset so ON tvs.stay_id = so.stay_id
GROUP BY 
    tvs.subject_id, tvs.stay_id, tvs.is_sepsis, tvs.is_new_sepsis, tvs.is_septic_shock, tvs.hour_bucket,
    ss.sofa_24hours, so.sepsis_onset_time
ORDER BY 
    tvs.subject_id, tvs.stay_id, tvs.hour_bucket;

-- Criar índices na tabela final
CREATE INDEX idx_hourly_vital_signs_subject_id ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (subject_id);
CREATE INDEX idx_hourly_vital_signs_stay_id ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (stay_id);
CREATE INDEX idx_hourly_vital_signs_hour_bucket ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (hour_bucket);
CREATE INDEX idx_hourly_vital_signs_is_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (is_sepsis);
CREATE INDEX idx_hourly_vital_signs_is_new_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (is_new_sepsis);
CREATE INDEX idx_hourly_vital_signs_is_septic_shock ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (is_septic_shock);
CREATE INDEX idx_hourly_vital_signs_sepsis_flag ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (sepsis_flag);
CREATE INDEX idx_hourly_vital_signs_hours_to_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (hours_to_sepsis);
CREATE INDEX idx_hourly_vital_signs_sofa_24hours ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS (sofa_24hours);



COPY (
SELECT * FROM MASTER_S_DEGREE.HOURLY_VITAL_SIGNS WHERE 1=1
) TO 'C:/Windows/Temp/sepsis.csv' WITH CSV HEADER;

-- -----------------------------------------------------------------------------------------------------------
-- APENAS OS CASOS DE INTERESSE
-- -----------------------------------------------------------------------------------------------------------
-- DESTA TABELA FOI EXPORTADO sepsis-interest.csv
-- Criar a nova tabela
-- Criar a nova tabela
CREATE TABLE MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_NEW_SEPSIS AS
SELECT
	SUBJECT_ID,
	STAY_ID,
	IS_SEPSIS,
	IS_NEW_SEPSIS,
	IS_SEPTIC_SHOCK,
	HOUR_BUCKET,
	AVG_HR,
	MEDIAN_HR,
	MIN_HR,
	MAX_HR,
	AVG_RR,
	MEDIAN_RR,
	MIN_RR,
	MAX_RR,
	AVG_SPO2,
	MEDIAN_SPO2,
	MIN_SPO2,
	MAX_SPO2,
	AVG_MAP,
	MEDIAN_MAP,
	MIN_MAP,
	MAX_MAP,
	SOFA_24HOURS,
	SEPSIS_FLAG,
	HOURS_TO_SEPSIS
FROM
	MASTER_S_DEGREE.HOURLY_VITAL_SIGNS
WHERE
	IS_NEW_SEPSIS != 0;
-- -------------------------------------------------------------------------------------------
-- -----------------------------------------------------------------------------------------------------------
-- APENAS AQUELES QUE TEM ENTRE 24 E 48 HORAS (mais que isso, removemos os registros)
-- -----------------------------------------------------------------------------------------------------------
-- sepsis-interest-filtered.csv
-- -----------------------------------------------------------------------------------------------------------

CREATE TABLE master_s_degree.filtered_hourly_vital_signs (
    subject_id INT,
    stay_id INT,
    is_sepsis BOOLEAN,
    is_new_sepsis INT,
    is_septic_shock INT,
    hour_bucket TIMESTAMP,
    median_hr FLOAT,
    median_rr FLOAT,
    median_spo2 FLOAT,
    median_map FLOAT,
    sofa_24hours INT,
    sepsis_flag INT,
    hours_to_sepsis FLOAT,
    PRIMARY KEY (subject_id, stay_id, hour_bucket)
);

INSERT INTO master_s_degree.filtered_hourly_vital_signs
WITH ranked_records AS (
  SELECT 
    subject_id, 
    stay_id, 
    is_sepsis, 
    is_new_sepsis, 
    is_septic_shock, 
    hour_bucket, 
    median_hr, 
    median_rr, 
    median_spo2, 
    median_map, 
    sofa_24hours, 
    sepsis_flag, 
    hours_to_sepsis,
    ROW_NUMBER() OVER (PARTITION BY subject_id, stay_id ORDER BY hour_bucket) as row_num,
    COUNT(*) OVER (PARTITION BY subject_id, stay_id) as total_records
  FROM master_s_degree.hourly_vital_signs_new_sepsis
),
filtered_records AS (
  SELECT *
  FROM ranked_records
  WHERE total_records >= 24
)
SELECT 
  subject_id, 
  stay_id, 
  is_sepsis, 
  is_new_sepsis, 
  is_septic_shock, 
  hour_bucket, 
  median_hr, 
  median_rr, 
  median_spo2, 
  median_map, 
  sofa_24hours, 
  sepsis_flag, 
  hours_to_sepsis
FROM filtered_records
WHERE row_num <= 48
ORDER BY subject_id, stay_id, hour_bucket;
-- -------------------------------------------------------------------------------------------
CREATE TABLE master_s_degree.avg_hourly_vital_signs AS
SELECT 
    subject_id, 
    stay_id, 
    is_sepsis, 
    is_new_sepsis, 
    is_septic_shock, 
    hour_bucket, 
    avg_hr, 
    avg_rr, 
    avg_spo2, 
    avg_map, 
    sofa_24hours, 
    sepsis_flag, 
    hours_to_sepsis
FROM master_s_degree.hourly_vital_signs_new_sepsis;
-- -------------------------------------------------------------------------------------------

-- Preencher horas faltantes --------------------------------------------------------------------


-- Criação da tabela
CREATE TABLE IF NOT EXISTS master_s_degree.filled_hourly_vital_signs (
    subject_id INT,
    stay_id INT,
    hour_bucket TIMESTAMP,
    is_sepsis INT,
    is_new_sepsis INT,
    is_septic_shock INT,
    avg_hr FLOAT,
    avg_rr FLOAT,
    avg_spo2 FLOAT,
    avg_map FLOAT,
    sofa_24hours INT,
    sepsis_flag INT,
    hours_to_sepsis FLOAT,
    PRIMARY KEY (subject_id, stay_id, hour_bucket)
);

-- Inserção dos dados
INSERT INTO master_s_degree.filled_hourly_vital_signs
WITH RECURSIVE
time_range AS (
    SELECT 
        subject_id, 
        stay_id, 
        MIN(hour_bucket) AS start_time,
        MAX(hour_bucket) AS end_time
    FROM master_s_degree.avg_hourly_vital_signs
    GROUP BY subject_id, stay_id
),
hour_series AS (
    SELECT 
        subject_id, 
        stay_id, 
        start_time AS hour_bucket
    FROM time_range

    UNION ALL

    SELECT 
        subject_id, 
        stay_id, 
        hour_bucket + INTERVAL '1 hour'
    FROM hour_series
    WHERE hour_bucket < (SELECT end_time FROM time_range tr WHERE tr.subject_id = hour_series.subject_id AND tr.stay_id = hour_series.stay_id)
),
filled_data AS (
    SELECT 
        hs.subject_id, 
        hs.stay_id, 
        hs.hour_bucket,
        COALESCE(avs.is_sepsis::int, LAG(avs.is_sepsis::int) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS is_sepsis,
        COALESCE(avs.is_new_sepsis::int, LAG(avs.is_new_sepsis::int) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS is_new_sepsis,
        COALESCE(avs.is_septic_shock::int, LAG(avs.is_septic_shock::int) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS is_septic_shock,
        COALESCE(avs.avg_hr, LAG(avs.avg_hr) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS avg_hr,
        COALESCE(avs.avg_rr, LAG(avs.avg_rr) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS avg_rr,
        COALESCE(avs.avg_spo2, LAG(avs.avg_spo2) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS avg_spo2,
        COALESCE(avs.avg_map, LAG(avs.avg_map) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS avg_map,
        COALESCE(avs.sofa_24hours, LAG(avs.sofa_24hours) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS sofa_24hours,
        COALESCE(avs.sepsis_flag::int, LAG(avs.sepsis_flag::int) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS sepsis_flag,
        COALESCE(avs.hours_to_sepsis, LAG(avs.hours_to_sepsis) OVER (PARTITION BY hs.subject_id, hs.stay_id ORDER BY hs.hour_bucket)) AS hours_to_sepsis
    FROM hour_series hs
    LEFT JOIN master_s_degree.avg_hourly_vital_signs avs
        ON hs.subject_id = avs.subject_id 
        AND hs.stay_id = avs.stay_id 
        AND hs.hour_bucket = avs.hour_bucket
)
SELECT * FROM filled_data
ORDER BY subject_id, stay_id, hour_bucket;

-- Criação de índices para melhorar o desempenho (opcional, mas recomendado)
CREATE INDEX IF NOT EXISTS idx_filled_hourly_vital_signs_subject_stay
ON master_s_degree.filled_hourly_vital_signs (subject_id, stay_id);

CREATE INDEX IF NOT EXISTS idx_filled_hourly_vital_signs_hour_bucket
ON master_s_degree.filled_hourly_vital_signs (hour_bucket);

-- ---------------------------------------------------------------------------------------------------


 -- * **Time Windows**: Data is usually extracted within specific time windows. For instance, vital signs are extracted for the **24 hours prior to a prediction point**[13, 14, 15, 16].  Some studies use a **6-hour sliding window** to capture temporal dependencies in vital signs [17]. Some models are trained to predict mortality or sepsis within a time frame (k) of 6, 24, or 48 hours [13, 18].
-- Criar a nova tabela com os dados da janela de 6 horas
CREATE TABLE MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW AS

WITH prediction_points AS (
    SELECT DISTINCT subject_id, stay_id, hour_bucket AS prediction_time
    FROM MASTER_S_DEGREE.HOURLY_VITAL_SIGNS
),
window_data AS (
    SELECT 
        pp.subject_id,
        pp.stay_id,
        pp.prediction_time,
        hvs.hour_bucket,
        hvs.avg_hr,
        hvs.avg_rr,
        hvs.avg_spo2,
        hvs.avg_map,
        hvs.sofa_24hours,
        hvs.is_sepsis,
        hvs.is_new_sepsis,
        hvs.is_septic_shock,
        hvs.sepsis_flag,
        hvs.hours_to_sepsis,
        ROW_NUMBER() OVER (PARTITION BY pp.subject_id, pp.stay_id, pp.prediction_time 
                           ORDER BY hvs.hour_bucket DESC) AS row_num
    FROM prediction_points pp
    JOIN MASTER_S_DEGREE.HOURLY_VITAL_SIGNS hvs
        ON pp.subject_id = hvs.subject_id
        AND pp.stay_id = hvs.stay_id
        AND hvs.hour_bucket > pp.prediction_time - INTERVAL '6 hours'
        AND hvs.hour_bucket <= pp.prediction_time
)
SELECT 
    subject_id,
    stay_id,
    prediction_time,
    AVG(avg_hr) AS avg_hr_6h,
    AVG(avg_rr) AS avg_rr_6h,
    AVG(avg_spo2) AS avg_spo2_6h,
    AVG(avg_map) AS avg_map_6h,
    MAX(sofa_24hours) AS max_sofa_6h,
    MAX(CASE WHEN is_sepsis = true THEN 1 ELSE 0 END) AS had_sepsis_6h,
    MAX(CASE WHEN is_new_sepsis = 1 THEN 1 ELSE 0 END) AS had_new_sepsis_6h,
    MAX(CASE WHEN is_septic_shock = 1 THEN 1 ELSE 0 END) AS had_septic_shock_6h,
    MAX(CASE WHEN sepsis_flag = 1 THEN 1 ELSE 0 END) AS had_sepsis_flag_6h,
    MIN(CASE WHEN hours_to_sepsis IS NOT NULL THEN hours_to_sepsis ELSE NULL END) AS min_hours_to_sepsis_6h
FROM window_data
WHERE row_num <= 6  -- Garante que pegamos no máximo 6 registros (1 por hora)
GROUP BY subject_id, stay_id, prediction_time
ORDER BY subject_id, stay_id, prediction_time;

-- Criar índices na nova tabela para melhorar o desempenho de consultas futuras
CREATE INDEX idx_vs_6h_subject_id ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (subject_id);
CREATE INDEX idx_vs_6h_stay_id ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (stay_id);
CREATE INDEX idx_vs_6h_prediction_time ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (prediction_time);
CREATE INDEX idx_vs_6h_had_sepsis ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (had_sepsis_6h);
CREATE INDEX idx_vs_6h_had_new_sepsis ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (had_new_sepsis_6h);
CREATE INDEX idx_vs_6h_had_septic_shock ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (had_septic_shock_6h);
CREATE INDEX idx_vs_6h_had_sepsis_flag ON MASTER_S_DEGREE.VITAL_SIGNS_6H_WINDOW (had_sepsis_flag_6h);


-- -------------------------------------------------------------------------------------------
--  * **Error Records:** Studies identify and remove error records. For example, heart rate values outside the range of 30-260, respiratory rates outside 5-70, SpO2 outside of 0-100, and MAP outside of 10-200 are deleted. [13]
-- Criar a nova tabela com filtros para registros de erro
CREATE TABLE MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED AS

SELECT hvs.*
FROM MASTER_S_DEGREE.HOURLY_VITAL_SIGNS hvs
WHERE 
    -- Filtro para frequência cardíaca (30-260)
    (hvs.min_hr >= 30 AND hvs.max_hr <= 260) AND
    
    -- Filtro para frequência respiratória (5-70)
    (hvs.min_rr >= 5 AND hvs.max_rr <= 70) AND
    
    -- Filtro para SpO2 (0-100)
    (hvs.min_spo2 >= 0 AND hvs.max_spo2 <= 100) AND
    
    -- Filtro para MAP (10-200)
    (hvs.min_map >= 10 AND hvs.max_map <= 200)
ORDER BY hvs.subject_id, hvs.stay_id, hvs.hour_bucket;

-- Criar índices na nova tabela
CREATE INDEX idx_hvs_filtered_subject_id ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (subject_id);
CREATE INDEX idx_hvs_filtered_stay_id ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (stay_id);
CREATE INDEX idx_hvs_filtered_hour_bucket ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (hour_bucket);
CREATE INDEX idx_hvs_filtered_is_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (is_sepsis);
CREATE INDEX idx_hvs_filtered_is_new_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (is_new_sepsis);
CREATE INDEX idx_hvs_filtered_is_septic_shock ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (is_septic_shock);
CREATE INDEX idx_hvs_filtered_sepsis_flag ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (sepsis_flag);
CREATE INDEX idx_hvs_filtered_hours_to_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (hours_to_sepsis);
CREATE INDEX idx_hvs_filtered_sofa_24hours ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED (sofa_24hours);

-- -----------------------------------------
--   * **Trend calculation**: The change in the variable value over time is calculated and used as a feature [23].
-- Criar a nova tabela com filtros para registros de erro e cálculos de tendência
CREATE TABLE MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS AS

WITH filtered_data AS (
    SELECT 
        hvs.*,
        ss.sofa_24hours AS ss_sofa_24hours,
        -- Calcular a diferença de tempo em horas entre registros consecutivos
        EXTRACT(EPOCH FROM (hvs.hour_bucket - LAG(hvs.hour_bucket) OVER (PARTITION BY hvs.subject_id, hvs.stay_id ORDER BY hvs.hour_bucket))) / 3600 AS hours_since_last_record
    FROM MASTER_S_DEGREE.HOURLY_VITAL_SIGNS hvs
    LEFT JOIN MASTER_S_DEGREE.tmp_sofa_score ss
    ON hvs.stay_id = ss.stay_id AND hvs.hour_bucket = ss.hour_bucket
    WHERE 
        -- Filtros para remover registros de erro
        (hvs.min_hr >= 30 AND hvs.max_hr <= 260) AND
        (hvs.min_rr >= 5 AND hvs.max_rr <= 70) AND
        (hvs.min_spo2 >= 0 AND hvs.max_spo2 <= 100) AND
        (hvs.min_map >= 10 AND hvs.max_map <= 200)
)

SELECT 
    fd.*,
    
    -- Calcular tendências para sinais vitais
    (fd.avg_hr - LAG(fd.avg_hr) OVER (PARTITION BY fd.subject_id, fd.stay_id ORDER BY fd.hour_bucket)) / NULLIF(fd.hours_since_last_record, 0) AS hr_trend,
    (fd.avg_rr - LAG(fd.avg_rr) OVER (PARTITION BY fd.subject_id, fd.stay_id ORDER BY fd.hour_bucket)) / NULLIF(fd.hours_since_last_record, 0) AS rr_trend,
    (fd.avg_spo2 - LAG(fd.avg_spo2) OVER (PARTITION BY fd.subject_id, fd.stay_id ORDER BY fd.hour_bucket)) / NULLIF(fd.hours_since_last_record, 0) AS spo2_trend,
    (fd.avg_map - LAG(fd.avg_map) OVER (PARTITION BY fd.subject_id, fd.stay_id ORDER BY fd.hour_bucket)) / NULLIF(fd.hours_since_last_record, 0) AS map_trend,
    
    -- Calcular tendência para SOFA score
    (fd.ss_sofa_24hours - LAG(fd.ss_sofa_24hours) OVER (PARTITION BY fd.subject_id, fd.stay_id ORDER BY fd.hour_bucket)) / NULLIF(fd.hours_since_last_record, 0) AS sofa_trend

FROM filtered_data fd
ORDER BY fd.subject_id, fd.stay_id, fd.hour_bucket;

-- Criar índices na nova tabela
CREATE INDEX idx_hvs_filtered_trends_subject_id ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (subject_id);
CREATE INDEX idx_hvs_filtered_trends_stay_id ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (stay_id);
CREATE INDEX idx_hvs_filtered_trends_hour_bucket ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (hour_bucket);
CREATE INDEX idx_hvs_filtered_trends_is_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (is_sepsis);
CREATE INDEX idx_hvs_filtered_trends_is_new_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (is_new_sepsis);
CREATE INDEX idx_hvs_filtered_trends_is_septic_shock ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (is_septic_shock);
CREATE INDEX idx_hvs_filtered_trends_sepsis_flag ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (sepsis_flag);
CREATE INDEX idx_hvs_filtered_trends_hours_to_sepsis ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (hours_to_sepsis);
CREATE INDEX idx_hvs_filtered_trends_sofa_24hours ON MASTER_S_DEGREE.HOURLY_VITAL_SIGNS_FILTERED_WITH_TRENDS (ss_sofa_24hours);



-- -----------------------------------------------------------------------------------

CREATE TABLE master_s_degree.filtered_hourly_vital_signs_24h_no_outliers AS
WITH filtered_ranked_vital_signs AS (
  SELECT 
    subject_id, 
    stay_id, 
    is_sepsis, 
    is_new_sepsis, 
    is_septic_shock, 
    hour_bucket, 
    avg_hr, 
    avg_rr, 
    avg_spo2, 
    avg_map, 
    sofa_24hours, 
    sepsis_flag, 
    hours_to_sepsis,
    ROW_NUMBER() OVER (PARTITION BY subject_id, stay_id ORDER BY hour_bucket) AS row_num
  FROM master_s_degree.hourly_vital_signs
  WHERE 
    avg_hr BETWEEN 30 AND 260
    AND avg_rr BETWEEN 5 AND 70
    AND avg_spo2 BETWEEN 0 AND 100
    AND avg_map BETWEEN 10 AND 200
)
SELECT 
  subject_id, 
  stay_id, 
  is_sepsis, 
  is_new_sepsis, 
  is_septic_shock, 
  hour_bucket, 
  avg_hr, 
  avg_rr, 
  avg_spo2, 
  avg_map, 
  sofa_24hours, 
  sepsis_flag, 
  hours_to_sepsis
FROM filtered_ranked_vital_signs
WHERE row_num <= 24
ORDER BY subject_id, stay_id, hour_bucket;
COPY (
SELECT * FROM master_s_degree.filtered_hourly_vital_signs_24h_no_outliers WHERE 1=1
) TO 'C:/Windows/Temp/filtered_hourly_vital_signs_24h_no_outliers.csv' WITH CSV HEADER;
-- -------------------------------------------------------------------------------------------------------
