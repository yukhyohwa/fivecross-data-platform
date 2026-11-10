SELECT
    'KR' AS region,
    mbga_uid AS lid,
    user_id,
    zone,
    obj,
    SUM(CAST(diff AS INT)) AS total_obtained,
    TO_CHAR(FROM_UNIXTIME(CAST(MIN(log_t) AS BIGINT)), 'yyyy-mm-dd hh:mm:ss') AS start_time,
    TO_CHAR(FROM_UNIXTIME(CAST(MAX(log_t) AS BIGINT)), 'yyyy-mm-dd hh:mm:ss') AS end_time
FROM
    g33002013.game_log
LATERAL VIEW explode(split(regexp_replace(trim(regexp_replace(a_rst,'^\\[|\\]$','')),'\\}\\s*,\\s*\\{','};{'),';')) b as rst
LATERAL VIEW json_tuple(rst,'obj','diff') j_tab as obj,diff
WHERE
    dt BETWEEN 20251218 AND 20251219
    AND obj = 'item@141024847'
    AND diff = 20
GROUP BY
    mbga_uid,
    user_id,
    zone,
    obj