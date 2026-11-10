/* 钢达姆机器人累计获得 >=4 个的玩家；日期参数 date1；fc_id 多角色合并。
   仅限 type=1116、非零活动 ID、OBT 首次创角后的 active_reward。
   排除 OBT 黑名单；只计算机器人本体正数增加量，不计算碎片/抽奖次数。
*/
WITH Blacklist AS (
    SELECT DISTINCT TRIM(CAST("#varchar_id" AS VARCHAR)) AS fc_id
    FROM user_result_cluster_18
    WHERE cluster_name IN ('internal_users_new','is_windows_new','is_water_new')
),
Registration AS (
    SELECT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
           MIN(CAST(v."#event_time" AS TIMESTAMP)) AS reg_time
    FROM ta.v_event_18 v
    WHERE v."$part_event"='new_role'
      AND v."$part_date">='2026-10-14'
      AND NULLIF(TRIM(CAST(v.fc_id AS VARCHAR)),'') IS NOT NULL
    GROUP BY 1
),
Rewards AS (
    SELECT TRIM(CAST(v.fc_id AS VARCHAR)) AS fc_id,
           CAST(v."#user_id" AS VARCHAR) AS uid,
           CAST(v."#account_id" AS VARCHAR) AS role_id,
           CAST(v.role_name AS VARCHAR) AS role_name,
           CAST(TRY_CAST(v.server_id AS BIGINT) AS VARCHAR) AS server_id,
           CAST(v."#event_time" AS TIMESTAMP) AS event_time,
           CASE WHEN TRY_CAST(u.item_diff AS DECIMAL(38,0))>0
                    THEN TRY_CAST(u.item_diff AS DECIMAL(38,0))
                WHEN TRY_CAST(u.item_after AS DECIMAL(38,0))-TRY_CAST(u.item_before AS DECIMAL(38,0))>0
                    THEN TRY_CAST(u.item_after AS DECIMAL(38,0))-TRY_CAST(u.item_before AS DECIMAL(38,0))
           END AS quantity
    FROM ta.v_event_18 v
    JOIN Registration r ON TRIM(CAST(v.fc_id AS VARCHAR))=r.fc_id
                       AND CAST(v."#event_time" AS TIMESTAMP)>=r.reg_time
    LEFT JOIN Blacklist b ON r.fc_id=b.fc_id
    CROSS JOIN UNNEST(v.a_rst) AS u(item_after,item_before,item_diff,item_id,item_key,item_name)
    WHERE v.${PartDate:date1}
      AND v."$part_date">='2026-10-14'
      AND v."$part_event"='active_reward'
      AND TRY_CAST(v.type AS BIGINT)=1116
      AND TRY_CAST(v.id AS DECIMAL(38,0))<>0
      AND b.fc_id IS NULL
      AND REPLACE(REPLACE(REPLACE(TRIM(CAST(u.item_name AS VARCHAR)),'鋼','钢'),'達','达'),'機','机')='钢达姆机器人'
      AND REPLACE(REPLACE(REPLACE(TRIM(TRY(SPLIT(CAST(v.name AS VARCHAR),'-')[2])),'鋼','钢'),'達','达'),'機','机')='钢达姆机器人'
)
SELECT fc_id AS "FC_ID",
       ARRAY_JOIN(ARRAY_SORT(ARRAY_DISTINCT(ARRAY_AGG(uid) FILTER(WHERE uid IS NOT NULL))),', ') AS "UID",
       ARRAY_JOIN(ARRAY_SORT(ARRAY_DISTINCT(ARRAY_AGG(role_id) FILTER(WHERE role_id IS NOT NULL))),', ') AS "角色ID",
       ARRAY_JOIN(ARRAY_SORT(ARRAY_DISTINCT(ARRAY_AGG(role_name) FILTER(WHERE role_name IS NOT NULL))),', ') AS "角色名称",
       ARRAY_JOIN(ARRAY_SORT(ARRAY_DISTINCT(ARRAY_AGG(server_id) FILTER(WHERE server_id IS NOT NULL))),', ') AS "区服ID",
       SUM(quantity) AS "累计获得机器人个数",
       MIN(event_time) AS "首次获得时间",
       MAX(event_time) AS "末次获得时间"
FROM Rewards
WHERE quantity>0
GROUP BY fc_id
HAVING SUM(quantity)>=4
ORDER BY SUM(quantity) DESC,fc_id;
