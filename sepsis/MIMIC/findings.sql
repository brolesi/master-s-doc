-- Cria uma tabela com o tempo de "início" da Sepse-3 na UTI.
-- Ou seja, o primeiro momento em que um paciente teve SOFA >= 2 e suspeita de infecção. 
-- Como muitas variáveis usadas no SOFA são coletadas apenas na UTI, esta consulta só pode definir o início da sepse-3 dentro da UTI.
-- extrai linhas com SOFA >= 2 implicitamente, isso pressupõe que o SOFA basal era 0 antes da admissão na UTI.


--------------------------------------------------------------------------------------------------------------	
-- PACIENTES UNICOS MAIORES DE 18 anos
--------------------------------------------------------------------------------------------------------------	

SELECT DISTINCT
    icu.subject_id
FROM
    mimiciv_icu.icustays icu
INNER JOIN
    mimiciv_hosp.patients p
ON
    icu.subject_id = p.subject_id
WHERE
    p.anchor_age >= 18
ORDER BY
    icu.subject_id;
	
--------------------------------------------------------------------------------------------------------------	
-- Pacientes maiores de 18 anos, com e sem sepse, e com valor de sepse = {NULL, true} (ainda com registros duplicados (tem NULL e true para um mesmo paciente n vezes).
--------------------------------------------------------------------------------------------------------------	

SELECT DISTINCT
    icu.subject_id,
    s.sepsis3
FROM
    mimiciv_icu.icustays icu
INNER JOIN
    mimiciv_hosp.patients p
ON
    icu.subject_id = p.subject_id
LEFT JOIN
    mimiciv_derived.sepsis3 s
ON
    icu.stay_id = s.stay_id
WHERE
    p.anchor_age >= 18
ORDER BY
    icu.subject_id

--------------------------------------------------------------------------------------------------------------	
-- COM E SEM SEPSE ÚNICOS CONSIDERANDO A ÚLTIMA INTERNAÇÃO
-- 27673	true -- com sepse
-- 37693	NULL -- sem sepse
--------------------------------------------------------------------------------------------------------------	

WITH ranked_icu_stays AS (
    SELECT 
        icu.subject_id,
        icu.stay_id,
        icu.intime,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime DESC) AS stay_rank
    FROM 
        mimiciv_icu.icustays icu
)
SELECT DISTINCT
    r.subject_id,
    s.sepsis3
FROM
    ranked_icu_stays r
INNER JOIN
    mimiciv_hosp.patients p
ON
    r.subject_id = p.subject_id
LEFT JOIN
    mimiciv_derived.sepsis3 s
ON
    r.stay_id = s.stay_id
WHERE
    p.anchor_age >= 18
    AND r.stay_rank = 1
ORDER BY
    r.subject_id;	

--------------------------------------------------------------------------------------------------------------	
-- CONTAGEM DOS COM E SEM SEPSE CONSIDERANDO ULTIMA ENTRADA
--------------------------------------------------------------------------------------------------------------
WITH ranked_icu_stays AS (
    SELECT 
        icu.subject_id,
        icu.stay_id,
        icu.intime,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime DESC) AS stay_rank
    FROM 
        mimiciv_icu.icustays icu
)
SELECT sum (1), sepsis3 from (
SELECT DISTINCT
    r.subject_id,
    s.sepsis3
FROM
    ranked_icu_stays r
INNER JOIN
    mimiciv_hosp.patients p
ON
    r.subject_id = p.subject_id
LEFT JOIN
    mimiciv_derived.sepsis3 s
ON
    r.stay_id = s.stay_id
WHERE
    p.anchor_age >= 18
    AND r.stay_rank = 1
ORDER BY
    r.subject_id) GROUP BY sepsis3;	

--------------------------------------------------------------------------------------------------------------
-- 	SINAIS VITAIS para subject_id=16907496
--------------------------------------------------------------------------------------------------------------
WITH ranked_icu_stays AS (
    SELECT 
        icu.subject_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime DESC) AS stay_rank
    FROM 
        mimiciv_icu.icustays icu
),
last_icu_stays AS (
    SELECT 
        r.subject_id,
        r.stay_id,
        r.intime,
        r.outtime,
        s.sepsis3
    FROM
        ranked_icu_stays r
    INNER JOIN
        mimiciv_hosp.patients p
    ON
        r.subject_id = p.subject_id
    LEFT JOIN
        mimiciv_derived.sepsis3 s
    ON
        r.stay_id = s.stay_id
    WHERE
        p.anchor_age >= 18
        AND r.stay_rank = 1
),
hourly_vitals AS (
    SELECT 
        l.subject_id,
        l.stay_id,
        l.sepsis3,
        DATE_TRUNC('hour', ce.charttime) AS chart_hour,
        ce.itemid,
        AVG(ce.valuenum) AS avg_value
    FROM
        last_icu_stays l
    INNER JOIN
        mimiciv_icu.chartevents ce
    ON
        l.stay_id = ce.stay_id
    WHERE
        ce.itemid IN (
            220045, -- Heart Rate
            220050, -- Arterial Blood Pressure systolic
            220051, -- Arterial Blood Pressure diastolic
            220052, -- Arterial Blood Pressure mean
            220179, -- Non Invasive Blood Pressure systolic
            220180, -- Non Invasive Blood Pressure diastolic
            220181, -- Non Invasive Blood Pressure mean
            220210, -- Respiratory Rate
            223761, -- Temperature Fahrenheit
            223762  -- Temperature Celsius
        )
        AND ce.charttime BETWEEN l.intime AND l.outtime
        AND ce.valuenum IS NOT NULL
    GROUP BY
        l.subject_id, l.stay_id, l.sepsis3, DATE_TRUNC('hour', ce.charttime), ce.itemid
)
SELECT
    subject_id,
    stay_id,
    sepsis3,
    chart_hour,
    MAX(CASE WHEN itemid = 220045 THEN avg_value END) AS heart_rate,
    MAX(CASE WHEN itemid = 220050 THEN avg_value END) AS abp_systolic,
    MAX(CASE WHEN itemid = 220051 THEN avg_value END) AS abp_diastolic,
    MAX(CASE WHEN itemid = 220052 THEN avg_value END) AS abp_mean,
    MAX(CASE WHEN itemid = 220179 THEN avg_value END) AS nibp_systolic,
    MAX(CASE WHEN itemid = 220180 THEN avg_value END) AS nibp_diastolic,
    MAX(CASE WHEN itemid = 220181 THEN avg_value END) AS nibp_mean,
    MAX(CASE WHEN itemid = 220210 THEN avg_value END) AS respiratory_rate,
    MAX(CASE WHEN itemid = 223761 THEN avg_value END) AS temp_fahrenheit,
    MAX(CASE WHEN itemid = 223762 THEN avg_value END) AS temp_celsius
FROM
    hourly_vitals
where subject_id=16907496
GROUP BY
    subject_id, stay_id, sepsis3, chart_hour
ORDER BY
    subject_id, stay_id, chart_hour;
-- 637 rows



--------------------------------------------------------------------------------------------------------------
-- 	SINAIS VITAIS para subject_id=16907496
--------------------------------------------------------------------------------------------------------------
WITH ranked_icu_stays AS (
    SELECT 
        icu.subject_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        ROW_NUMBER() OVER (PARTITION BY icu.subject_id ORDER BY icu.intime DESC) AS stay_rank
    FROM 
        mimiciv_icu.icustays icu
    WHERE
        icu.subject_id = 16907496
),
last_icu_stays AS (
    SELECT 
        r.subject_id,
        r.stay_id,
        r.intime,
        r.outtime,
        s.sepsis3
    FROM
        ranked_icu_stays r
    INNER JOIN
        mimiciv_hosp.patients p
    ON
        r.subject_id = p.subject_id
    LEFT JOIN
        mimiciv_derived.sepsis3 s
    ON
        r.stay_id = s.stay_id
    WHERE
        p.anchor_age >= 18
        AND r.stay_rank = 1
),
hourly_vitals AS (
    SELECT 
        l.subject_id,
        l.stay_id,
        l.sepsis3,
        DATE_TRUNC('hour', ce.charttime) AS chart_hour,
        ce.itemid,
        AVG(ce.valuenum) AS avg_value
    FROM
        last_icu_stays l
    INNER JOIN
        mimiciv_icu.chartevents ce
    ON
        l.stay_id = ce.stay_id
    WHERE
        ce.itemid IN (
            220045, -- Heart Rate
            220050, -- Arterial Blood Pressure systolic
            220051, -- Arterial Blood Pressure diastolic
            220052, -- Arterial Blood Pressure mean
            220179, -- Non Invasive Blood Pressure systolic
            220180, -- Non Invasive Blood Pressure diastolic
            220181, -- Non Invasive Blood Pressure mean
            220210, -- Respiratory Rate
            223761, -- Temperature Fahrenheit
            223762  -- Temperature Celsius
        )
        AND ce.charttime BETWEEN l.intime AND l.outtime
        AND ce.valuenum IS NOT NULL
    GROUP BY
        l.subject_id, l.stay_id, l.sepsis3, DATE_TRUNC('hour', ce.charttime), ce.itemid
)
SELECT
    subject_id,
    stay_id,
    sepsis3,
    chart_hour,
    MAX(CASE WHEN itemid = 220045 THEN avg_value END) AS heart_rate,
    MAX(CASE WHEN itemid = 220050 THEN avg_value END) AS abp_systolic,
    MAX(CASE WHEN itemid = 220051 THEN avg_value END) AS abp_diastolic,
    MAX(CASE WHEN itemid = 220052 THEN avg_value END) AS abp_mean,
    MAX(CASE WHEN itemid = 220179 THEN avg_value END) AS nibp_systolic,
    MAX(CASE WHEN itemid = 220180 THEN avg_value END) AS nibp_diastolic,
    MAX(CASE WHEN itemid = 220181 THEN avg_value END) AS nibp_mean,
    MAX(CASE WHEN itemid = 220210 THEN avg_value END) AS respiratory_rate,
    MAX(CASE WHEN itemid = 223761 THEN avg_value END) AS temp_fahrenheit,
    MAX(CASE WHEN itemid = 223762 THEN avg_value END) AS temp_celsius
FROM
    hourly_vitals
GROUP BY
    subject_id, stay_id, sepsis3, chart_hour
ORDER BY
    subject_id, stay_id, chart_hour;
-- 637 rows




--------------------------------------------------------------------------------------------------------------
-- Agrupe os dados por hora, pegando a média de cada um deles quando existir. 
-- 	Insira o SOFA e o sepsis3 á análise, e considere o tempo de identificação do choque séptico como tempo 0. Calcule quantas horas cada grupo de registros está do tempo 0 para cada paciente.
--------------------------------------------------------------------------------------------------------------

WITH septic_shock_patients AS (
    SELECT DISTINCT a.subject_id, a.hadm_id,
           MIN(a.admittime) AS septic_shock_time
    FROM mimiciv_hosp.admissions a
    JOIN mimiciv_hosp.diagnoses_icd d ON a.hadm_id = d.hadm_id
    WHERE d.icd_code IN ('R6521', 'A419') -- códigos ICD-10 para choque séptico
    GROUP BY a.subject_id, a.hadm_id
),
sofa_scores AS (
    SELECT stay_id, starttime, sofa_24hours AS sofa_score
    FROM mimiciv_derived.sofa
),
sepsis3 AS (
    SELECT subject_id, stay_id, 
           suspected_infection_time,
           sofa_time, sofa_score, sepsis3
    FROM mimiciv_derived.sepsis3
),
vital_signs AS (
    SELECT c.subject_id, c.hadm_id, c.stay_id,
           DATE_TRUNC('hour', c.charttime) AS chart_hour,
           AVG(CASE WHEN c.itemid = 220045 THEN c.valuenum END) AS heart_rate,
           AVG(CASE WHEN c.itemid = 220050 THEN c.valuenum END) AS abp_systolic,
           AVG(CASE WHEN c.itemid = 220051 THEN c.valuenum END) AS abp_diastolic,
           AVG(CASE WHEN c.itemid = 220052 THEN c.valuenum END) AS abp_mean,
           AVG(CASE WHEN c.itemid = 220179 THEN c.valuenum END) AS nibp_systolic,
           AVG(CASE WHEN c.itemid = 220180 THEN c.valuenum END) AS nibp_diastolic,
           AVG(CASE WHEN c.itemid = 220181 THEN c.valuenum END) AS nibp_mean,
           AVG(CASE WHEN c.itemid = 220210 THEN c.valuenum END) AS respiratory_rate,
           AVG(CASE WHEN c.itemid = 223761 THEN c.valuenum END) AS temperature_f,
           AVG(CASE WHEN c.itemid = 223762 THEN c.valuenum END) AS temperature_c
    FROM mimiciv_icu.chartevents c
    JOIN septic_shock_patients s ON c.subject_id = s.subject_id AND c.hadm_id = s.hadm_id
    WHERE c.itemid IN (220045, 220050, 220051, 220052, 220179, 220180, 220181, 220210, 223761, 223762)
    GROUP BY c.subject_id, c.hadm_id, c.stay_id, DATE_TRUNC('hour', c.charttime)
)
SELECT 
    v.*,
    p.gender,
    p.anchor_age,
    s.sofa_score,
    sep3.sepsis3,
    EXTRACT(EPOCH FROM (v.chart_hour - ssp.septic_shock_time)) / 3600 AS hours_from_shock
FROM vital_signs v
JOIN mimiciv_hosp.patients p ON v.subject_id = p.subject_id
JOIN septic_shock_patients ssp ON v.subject_id = ssp.subject_id AND v.hadm_id = ssp.hadm_id
LEFT JOIN sofa_scores s ON v.stay_id = s.stay_id 
    AND v.chart_hour = DATE_TRUNC('hour', s.starttime)
LEFT JOIN sepsis3 sep3 ON v.subject_id = sep3.subject_id 
    AND v.stay_id = sep3.stay_id
    AND v.chart_hour = DATE_TRUNC('hour', sep3.sofa_time)
WHERE v.chart_hour BETWEEN ssp.septic_shock_time - INTERVAL '24 hours' AND ssp.septic_shock_time + INTERVAL '24 hours'
ORDER BY v.subject_id, hours_from_shock;







--------------------------------------------------------------------------------------------------------------
-- Pega se o paciente teve alta ou óbito e o tempo entre um e outro.
--------------------------------------------------------------------------------------------------------------

WITH patient_admissions AS (
    SELECT 
        a.subject_id,
        a.hadm_id,
        a.admittime AS data_hora_admissao,
        CASE 
            WHEN p.dod IS NOT NULL AND p.dod BETWEEN a.admittime AND a.dischtime THEN p.dod
            ELSE a.dischtime 
        END AS data_hora_saida,
        EXTRACT(EPOCH FROM (
            CASE 
                WHEN p.dod IS NOT NULL AND p.dod BETWEEN a.admittime AND a.dischtime THEN p.dod
                ELSE a.dischtime 
            END - a.admittime
        )) / 3600 AS duracao_internacao_horas,
        CASE 
            WHEN p.dod IS NOT NULL AND p.dod BETWEEN a.admittime AND a.dischtime THEN 'Óbito'
            WHEN p.dod IS NOT NULL AND p.dod > a.dischtime THEN 'Alta (Óbito posterior)'
            ELSE 'Alta' 
        END AS desfecho
    FROM 
        mimiciv_hosp.admissions a
    JOIN 
        mimiciv_hosp.patients p ON a.subject_id = p.subject_id
)
SELECT 
    subject_id,
    array_agg(hadm_id) AS admissoes,
    array_agg(data_hora_admissao) AS datas_admissao,
    array_agg(data_hora_saida) AS datas_saida,
    array_agg(duracao_internacao_horas) AS duracoes_internacao,
    array_agg(desfecho) AS desfechos
FROM 
    patient_admissions
GROUP BY 
    subject_id
LIMIT 10;





--------------------------------------------------------------------------------------------------------------
-- Para cada paciente do MIMIC e considerando o sepsis3, identifique se o subect_id numa determinada admissão teve ou não sepse considerando a tabela do sepsis3.
--------------------------------------------------------------------------------------------------------------

WITH sepsis_status AS (
    SELECT DISTINCT ON (subject_id, stay_id)
        subject_id,
        stay_id,
        CASE 
            WHEN sepsis3 = true THEN 'Sim'
            ELSE 'Não'
        END AS teve_sepse,
        sofa_time AS tempo_sepse,
        suspected_infection_time AS tempo_suspeita_infeccao,
        sofa_score
    FROM 
        mimiciv_derived.sepsis3
    ORDER BY 
        subject_id, stay_id, sepsis3 DESC, sofa_time
)
SELECT 
    a.subject_id,
	s.stay_id,
    a.hadm_id,
    a.admittime AS data_hora_admissao,
    a.dischtime AS data_hora_alta,
    COALESCE(s.teve_sepse, 'Não') AS teve_sepse,
    s.tempo_sepse,
    s.tempo_suspeita_infeccao,
    s.sofa_score,
    CASE 
        WHEN p.dod IS NOT NULL AND p.dod BETWEEN a.admittime AND a.dischtime THEN 'Óbito'
        WHEN p.dod IS NOT NULL AND p.dod > a.dischtime THEN 'Alta (Óbito posterior)'
        ELSE 'Alta' 
    END AS desfecho
FROM 
    mimiciv_hosp.admissions a
LEFT JOIN 
    mimiciv_icu.icustays i ON a.hadm_id = i.hadm_id
LEFT JOIN 
    sepsis_status s ON i.stay_id = s.stay_id
JOIN 
    mimiciv_hosp.patients p ON a.subject_id = p.subject_id
ORDER BY 
    a.subject_id, a.admittime, s.stay_id
LIMIT 200;



--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------------------------
-- Quero uma nova consulta, neste momento ignorando as anteriores: pegue todos os pacientes admitidos na UTI e dê o tempo de permanência e o desfecho.
--------------------------------------------------------------------------------------------------------------

SELECT 
    icu.subject_id,
    icu.hadm_id,
    icu.stay_id,
    icu.intime AS data_hora_admissao_uti,
    icu.outtime AS data_hora_alta_uti,
    EXTRACT(EPOCH FROM (icu.outtime - icu.intime)) / 3600 AS tempo_permanencia_horas,
    EXTRACT(EPOCH FROM (icu.outtime - icu.intime)) / (24 * 3600) AS tempo_permanencia_dias,
    CASE 
        WHEN adm.deathtime IS NOT NULL AND adm.deathtime BETWEEN icu.intime AND icu.outtime THEN 'Óbito na UTI'
        WHEN adm.deathtime IS NOT NULL AND adm.deathtime > icu.outtime THEN 'Óbito após alta da UTI'
        WHEN adm.deathtime IS NULL THEN 'Alta vivo'
        ELSE 'Desconhecido'
    END AS desfecho
FROM 
    mimiciv_icu.icustays icu
JOIN 
    mimiciv_hosp.admissions adm ON icu.hadm_id = adm.hadm_id
ORDER BY 
    icu.subject_id, icu.intime
LIMIT 100;  -- Limitando a 100 resultados para exemplo, remova ou ajuste conforme necessário

--------------------------------------------------------------------------------------------------------------
-- Para cada paciente, quero os dados de sepse deles e o sofa score de hora em hora da entrada até a saída
--------------------------------------------------------------------------------------------------------------
WITH hourly_intervals AS (
    SELECT 
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        generate_series(
            date_trunc('hour', icu.intime),
            date_trunc('hour', icu.outtime),
            '1 hour'::interval
        ) AS hour
    FROM mimiciv_icu.icustays icu
),
sepsis_data AS (
    SELECT 
        subject_id,
        stay_id,
        sepsis3,
        sofa_time,
        suspected_infection_time
    FROM mimiciv_derived.sepsis3
),
sofa_hourly AS (
    SELECT 
        stay_id,
        starttime,
        endtime,
        sofa_24hours
    FROM mimiciv_derived.sofa
)
SELECT 
    hi.subject_id,
    hi.hadm_id,
    hi.stay_id,
    hi.intime AS admissao_uti,
    hi.outtime AS alta_uti,
    hi.hour AS hora,
    CASE 
        WHEN sd.sepsis3 = true THEN 'Sim'
        ELSE 'Não'
    END AS sepse,
    sd.sofa_time AS tempo_sepse,
    sd.suspected_infection_time AS suspeita_infeccao,
    COALESCE(sh.sofa_24hours, LAG(sh.sofa_24hours) OVER (PARTITION BY hi.stay_id ORDER BY hi.hour)) AS sofa_score
FROM 
    hourly_intervals hi
LEFT JOIN sepsis_data sd ON hi.stay_id = sd.stay_id
LEFT JOIN sofa_hourly sh ON hi.stay_id = sh.stay_id 
    AND hi.hour >= sh.starttime 
    AND hi.hour < sh.endtime
ORDER BY 
    hi.subject_id, hi.stay_id, hi.hour
LIMIT 1000;  -- Ajuste conforme necessário

--

WITH hourly_intervals AS (
    SELECT 
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        generate_series(
            date_trunc('hour', icu.intime),
            date_trunc('hour', icu.outtime),
            '1 hour'::interval
        ) AS hour
    FROM mimiciv_icu.icustays icu
),
sepsis_data AS (
    SELECT 
        subject_id,
        stay_id,
        sepsis3,
        sofa_time,
        suspected_infection_time
    FROM mimiciv_derived.sepsis3
),
sofa_hourly AS (
    SELECT 
        stay_id,
        starttime,
        endtime,
        sofa_24hours
    FROM mimiciv_derived.sofa
)
SELECT 
    hi.subject_id,
    hi.hadm_id,
    hi.stay_id,
    hi.intime AS admissao_uti,
    hi.outtime AS alta_uti,
    hi.hour AS hora,
    CASE 
        WHEN sd.sepsis3 = true THEN 'Sim'
        ELSE 'Não'
    END AS sepse,
    sd.sofa_time AS tempo_sepse,
    sd.suspected_infection_time AS suspeita_infeccao,
    COALESCE(sh.sofa_24hours, LAG(sh.sofa_24hours) OVER (PARTITION BY hi.stay_id ORDER BY hi.hour)) AS sofa_score
FROM 
    hourly_intervals hi
LEFT JOIN sepsis_data sd ON hi.stay_id = sd.stay_id
LEFT JOIN sofa_hourly sh ON hi.stay_id = sh.stay_id 
    AND hi.hour >= sh.starttime 
    AND hi.hour < sh.endtime
ORDER BY 
    hi.subject_id, hi.stay_id, hi.hour
LIMIT 1000;  -- Ajuste conforme necessário



--------------------------------------------------------------------------------------------------------------
-- Adicione agora os sinais vitais do paciente também de hora em hora, pivotados. Também quero o momento em que o diagnóstico de choque séptico é confirmado (CID-10)
--------------------------------------------------------------------------------------------------------------
WITH hourly_intervals AS (
    SELECT 
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        generate_series(
            date_trunc('hour', icu.intime),
            date_trunc('hour', icu.outtime),
            '1 hour'::interval
        ) AS hour
    FROM mimiciv_icu.icustays icu
),
sepsis_data AS (
    SELECT 
        subject_id,
        stay_id,
        sepsis3,
        sofa_time,
        suspected_infection_time
    FROM mimiciv_derived.sepsis3
),
sofa_hourly AS (
    SELECT 
        stay_id,
        starttime,
        endtime,
        sofa_24hours
    FROM mimiciv_derived.sofa
),
vital_signs AS (
    SELECT 
        ce.stay_id,
        date_trunc('hour', ce.charttime) AS chart_hour,
        AVG(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) AS heart_rate,
        AVG(CASE WHEN ce.itemid = 220050 THEN ce.valuenum END) AS sbp,
        AVG(CASE WHEN ce.itemid = 220051 THEN ce.valuenum END) AS dbp,
        AVG(CASE WHEN ce.itemid = 220052 THEN ce.valuenum END) AS mbp,
        AVG(CASE WHEN ce.itemid = 220179 THEN ce.valuenum END) AS temperature,
        AVG(CASE WHEN ce.itemid = 220210 THEN ce.valuenum END) AS respiratory_rate,
        AVG(CASE WHEN ce.itemid = 220277 THEN ce.valuenum END) AS spo2
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (220045, 220050, 220051, 220052, 220179, 220210, 220277)
    GROUP BY ce.stay_id, date_trunc('hour', ce.charttime)
),
septic_shock_diagnosis AS (
    SELECT 
        d.subject_id,
        d.hadm_id,
        MIN(a.admittime) AS septic_shock_date
    FROM mimiciv_hosp.diagnoses_icd d
    JOIN mimiciv_hosp.admissions a ON d.hadm_id = a.hadm_id
    WHERE d.icd_code IN ('R6521', 'A419') -- ICD-10 codes for septic shock
    GROUP BY d.subject_id, d.hadm_id
)
SELECT 
    hi.subject_id,
    hi.hadm_id,
    hi.stay_id,
    hi.intime AS admissao_uti,
    hi.outtime AS alta_uti,
    hi.hour AS hora,
    CASE 
        WHEN sd.sepsis3 = true THEN 'Sim'
        ELSE 'Não'
    END AS sepse,
    sd.sofa_time AS tempo_sepse,
    sd.suspected_infection_time AS suspeita_infeccao,
    ssd.septic_shock_date AS data_diagnostico_choque_septico,
    COALESCE(sh.sofa_24hours, LAG(sh.sofa_24hours) OVER (PARTITION BY hi.stay_id ORDER BY hi.hour)) AS sofa_score,
    vs.heart_rate,
    vs.sbp,
    vs.dbp,
    vs.mbp,
    vs.temperature,
    vs.respiratory_rate,
    vs.spo2
FROM 
    hourly_intervals hi
LEFT JOIN sepsis_data sd ON hi.stay_id = sd.stay_id
LEFT JOIN sofa_hourly sh ON hi.stay_id = sh.stay_id 
    AND hi.hour >= sh.starttime 
    AND hi.hour < sh.endtime
LEFT JOIN vital_signs vs ON hi.stay_id = vs.stay_id AND hi.hour = vs.chart_hour
LEFT JOIN septic_shock_diagnosis ssd ON hi.subject_id = ssd.subject_id AND hi.hadm_id = ssd.hadm_id
ORDER BY 
    hi.subject_id, hi.stay_id, hi.hour
LIMIT 1000;  -- Ajuste conforme necessário

--------------------------------------------------------------------------------------------------------------
-- Coloque uma coluna com o desfecho e coloque todos os nomes de colunas em inglês e com uma descrição clara (por exemplo o campo hora, é hora de que?)
--------------------------------------------------------------------------------------------------------------

WITH hourly_intervals AS (
    SELECT 
        icu.subject_id,
        icu.hadm_id,
        icu.stay_id,
        icu.intime,
        icu.outtime,
        generate_series(
            date_trunc('hour', icu.intime),
            date_trunc('hour', icu.outtime),
            '1 hour'::interval
        ) AS hour
    FROM mimiciv_icu.icustays icu
),
sepsis_data AS (
    SELECT 
        subject_id,
        stay_id,
        sepsis3,
        sofa_time,
        suspected_infection_time
    FROM mimiciv_derived.sepsis3
),
sofa_hourly AS (
    SELECT 
        stay_id,
        starttime,
        endtime,
        sofa_24hours
    FROM mimiciv_derived.sofa
),
vital_signs AS (
    SELECT 
        ce.stay_id,
        date_trunc('hour', ce.charttime) AS chart_hour,
        AVG(CASE WHEN ce.itemid = 220045 THEN ce.valuenum END) AS heart_rate,
        AVG(CASE WHEN ce.itemid = 220050 THEN ce.valuenum END) AS sbp,
        AVG(CASE WHEN ce.itemid = 220051 THEN ce.valuenum END) AS dbp,
        AVG(CASE WHEN ce.itemid = 220052 THEN ce.valuenum END) AS mbp,
        AVG(CASE WHEN ce.itemid = 220179 THEN ce.valuenum END) AS temperature,
        AVG(CASE WHEN ce.itemid = 220210 THEN ce.valuenum END) AS respiratory_rate,
        AVG(CASE WHEN ce.itemid = 220277 THEN ce.valuenum END) AS spo2
    FROM mimiciv_icu.chartevents ce
    WHERE ce.itemid IN (220045, 220050, 220051, 220052, 220179, 220210, 220277)
    GROUP BY ce.stay_id, date_trunc('hour', ce.charttime)
),
septic_shock_diagnosis AS (
    SELECT 
        d.subject_id,
        d.hadm_id,
        MIN(a.admittime) AS septic_shock_date
    FROM mimiciv_hosp.diagnoses_icd d
    JOIN mimiciv_hosp.admissions a ON d.hadm_id = a.hadm_id
    WHERE d.icd_code IN ('R6521', 'A419') -- ICD-10 codes for septic shock
    GROUP BY d.subject_id, d.hadm_id
)
SELECT 
    hi.subject_id AS patient_id,
    hi.hadm_id AS hospital_admission_id,
    hi.stay_id AS icu_stay_id,
    hi.intime AS icu_admission_time,
    hi.outtime AS icu_discharge_time,
    hi.hour AS measurement_hour,
    CASE 
        WHEN sd.sepsis3 = true THEN 'Yes'
        ELSE 'No'
    END AS has_sepsis,
    sd.sofa_time AS sepsis_onset_time,
    sd.suspected_infection_time AS suspected_infection_time,
    ssd.septic_shock_date AS septic_shock_diagnosis_time,
    COALESCE(sh.sofa_24hours, LAG(sh.sofa_24hours) OVER (PARTITION BY hi.stay_id ORDER BY hi.hour)) AS sofa_score,
    vs.heart_rate,
    vs.sbp AS systolic_blood_pressure,
    vs.dbp AS diastolic_blood_pressure,
    vs.mbp AS mean_blood_pressure,
    vs.temperature,
    vs.respiratory_rate,
    vs.spo2 AS oxygen_saturation,
    CASE 
        WHEN p.dod IS NOT NULL AND p.dod BETWEEN hi.intime AND hi.outtime THEN 'Death in ICU'
        WHEN p.dod IS NOT NULL AND p.dod > hi.outtime THEN 'Death after ICU discharge'
        WHEN p.dod IS NULL THEN 'Survived'
        ELSE 'Unknown'
    END AS patient_outcome
FROM 
    hourly_intervals hi
LEFT JOIN sepsis_data sd ON hi.stay_id = sd.stay_id
LEFT JOIN sofa_hourly sh ON hi.stay_id = sh.stay_id 
    AND hi.hour >= sh.starttime 
    AND hi.hour < sh.endtime
LEFT JOIN vital_signs vs ON hi.stay_id = vs.stay_id AND hi.hour = vs.chart_hour
LEFT JOIN septic_shock_diagnosis ssd ON hi.subject_id = ssd.subject_id AND hi.hadm_id = ssd.hadm_id
LEFT JOIN mimiciv_hosp.patients p ON hi.subject_id = p.subject_id
ORDER BY 
    hi.subject_id, hi.stay_id, hi.hour
LIMIT 1000;  -- Adjust as needed