SELECT 
    CAST("$part_date" AS VARCHAR) AS "日期 (Date)",
    CASE 
    WHEN SUBSTR(SPLIT(SPLIT(a_usr,'@')[1],'_')[3], 1, 1) = '4'  THEN '北美'
    WHEN SUBSTR(SPLIT(SPLIT(a_usr,'@')[1],'_')[3], 1, 1) = '3'  THEN '南美'
    WHEN SUBSTR(SPLIT(SPLIT(a_usr,'@')[1],'_')[3], 1, 1) = '2'  THEN '欧洲'
    WHEN SUBSTR(SPLIT(SPLIT(a_usr,'@')[1],'_')[3], 1, 1) = '1'  THEN '东南亚'
    END "区域",
    SPLIT(SPLIT(a_usr,'@')[1],'_')[3]  AS "区服 (Server)",
    COUNT(DISTINCT "#account_id") AS "DAU (活跃人数)"
FROM ta.v_event_21
WHERE "$part_date" BETWEEN '2026-08-01' AND '2026-08-05'
  AND "$part_event" IN ('Dmp101002')
  AND a_usr IS NOT NULL 
  AND a_usr <> ''
GROUP BY 
    1, 2, 3