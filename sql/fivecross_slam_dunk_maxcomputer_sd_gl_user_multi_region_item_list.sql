-- 台湾 (TC)、韩�?(KR)、全�?(GL) 三个区域的汇总查�?
-- 台湾 (TC): 查找道具获得
SELECT
    'TC' AS region,
    mbga_uid AS lid,
    user_id,
    zone,
    obj,
    SUM(CAST(diff AS INT)) AS total_obtained,
    TO_CHAR(FROM_UNIXTIME(CAST(MIN(log_t) AS BIGINT)), 'yyyy-mm-dd hh:mm:ss') AS start_time,
    TO_CHAR(FROM_UNIXTIME(CAST(MAX(log_t) AS BIGINT)), 'yyyy-mm-dd hh:mm:ss') AS end_time
FROM
    g23002013.daily_game_log
LATERAL VIEW
    EXPLODE(a_rst) b AS rst
LATERAL VIEW
    JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
WHERE
    day BETWEEN 20251204 AND 20251217
    AND obj = 'item@50300032'
    AND diff > 0
GROUP BY
    mbga_uid,
    user_id,
    zone,
    obj

UNION ALL

-- 韩国 (KR): 查找单个道具的消耗日�?
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
    g33002013.daily_game_log
LATERAL VIEW
    EXPLODE(a_rst) b AS rst
LATERAL VIEW
    JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
WHERE
    day BETWEEN 20251204 AND 20251217
    AND obj = 'item@141024840'
    AND diff = -5
    AND SIZE(a_rst) = 1
GROUP BY
    mbga_uid,
    user_id,
    zone,
    obj

UNION ALL

-- 全球 (GL): 查找道具获得
SELECT
    'GL' AS region,
    mbga_uid AS lid,
    user_id,
    zone,
    obj,
    SUM(CAST(diff AS INT)) AS total_obtained,
    TO_CHAR(FROM_UNIXTIME(CAST(MIN(log_t) AS BIGINT)), 'yyyy-mm-dd hh:mm:ss') AS start_time,
    TO_CHAR(FROM_UNIXTIME(CAST(MAX(log_t) AS BIGINT)), 'yyyy-mm-dd hh:mm:ss') AS end_time
FROM
    g63002013.daily_game_log
LATERAL VIEW
    EXPLODE(a_rst) b AS rst
LATERAL VIEW
    JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
WHERE
    day BETWEEN 20251204 AND 20251217
    AND obj = 'item@50300032'
    AND diff > 0
GROUP BY
    mbga_uid,
    user_id,
    zone�?
    obj;


-- SELECT *
-- FROM g33002013.game_log
-- LATERAL VIEW explode(split(regexp_replace(regexp_replace(a_rst,'\\[|\\]',''),'\\}\\,\\{','\\}\\;\\{'),'\\;'))b as rst
-- LATERAL VIEW json_tuple(rst,'obj','diff') j_tab as obj,diff
-- where a_typ='gacha'
--   AND obj = 'item@50300032'
--   AND diff > 0
 --  AND dt = 20251204
