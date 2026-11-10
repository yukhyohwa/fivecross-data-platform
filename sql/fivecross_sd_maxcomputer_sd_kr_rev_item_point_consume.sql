
SELECT
    'KR' AS region,
    mbga_uid AS lid,
    user_id,
    SPLIT(zone,'_')[2] AS zone,
    SUM(CASE WHEN obj IN ('dmp:freestamps') THEN CAST(diff AS INT) END)*-1 AS free_consumed,
    SUM(CASE WHEN obj IN ('dmp:stamps') THEN CAST(diff AS INT) END)*-1 AS paid_consumed,
    SUM(CAST(diff AS INT))*-1 AS total_consumed
FROM
    g33002013.daily_game_log
LATERAL VIEW
    EXPLODE(a_rst) b AS rst
LATERAL VIEW
    JSON_TUPLE(rst, 'obj', 'diff') j_tab AS obj, diff
WHERE
    day BETWEEN 20260101 AND 20260104
    AND obj IN ('dmp:freestamps','dmp:stamps')
    AND diff <0
GROUP BY
    mbga_uid,
    user_id,
    SPLIT(zone,'_')[2] ,
    obj
HAVING
    SUM(CAST(diff AS INT)) < 0