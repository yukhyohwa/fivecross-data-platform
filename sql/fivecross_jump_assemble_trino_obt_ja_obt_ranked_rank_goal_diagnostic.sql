/*
JUMP TW OBT — 段位目标追逐诊断（Trino / ThinkingData）

回答三个直接的“段位目标”问题：
1) 各段位带的排位投入是否在结算前下滑？
2) 距离下一大段仅一步（升段临界）的玩家，是否仍更愿意再次排位？
3) 再次排位是否转化为可见的段位提升？

窗口：2026-06-24 至 2026-08-25；8/26 结算日不纳入。
段位临界：3、6、10、15、20、25、28、31，分别是进入下一大段前的最后一级。
注意：player_ladder_level 是结算时记录；本报表只衡量观察性关联，不证明奖励或匹配为因果。
*/
WITH params AS (
    SELECT DATE '2026-06-24' AS start_date, DATE '2026-08-26' AS end_exclusive,
           DATE '2026-07-14' AS early_end, DATE '2026-08-04' AS mid_end
),
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),
RawRanked AS (
    SELECT * FROM (
        SELECT CAST(v."$part_date" AS DATE) AS fight_date,
               COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
               v.battle_id,
               TRY_CAST(v.player_ladder_level AS INTEGER) AS ladder_level,
               v."#event_time" AS event_time,
               ROW_NUMBER() OVER (
                   PARTITION BY CAST(v."$part_date" AS DATE),
                                COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id"),
                                v.battle_id
                   ORDER BY v."#event_time" DESC
               ) AS rn
        FROM ta.v_event_23 v
        CROSS JOIN params p
        LEFT JOIN UserBlacklist ub ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
        WHERE v."$part_date" >= CAST(p.start_date AS VARCHAR)
          AND v."$part_date" < CAST(p.end_exclusive AS VARCHAR)
          AND v."$part_event" = 'arena_fight'
          AND TRY_CAST(v.model_type AS INTEGER) = 2
          AND TRY_CAST(v.game_type AS INTEGER) IN (1,5,7,8,9,11,15)
          AND v.battle_id IS NOT NULL
          AND TRY_CAST(v.player_ladder_level AS INTEGER) BETWEEN 1 AND 32
          AND ub.lcx_id IS NULL
    ) t WHERE rn = 1
),
RankedAccountDay AS (
    SELECT fight_date, lcx_id,
           COUNT(DISTINCT battle_id) AS ranked_matches,
           MAX_BY(ladder_level, event_time) AS end_ladder_level
    FROM RawRanked
    GROUP BY 1,2
),
GoalCohort AS (
    SELECT r.*,
           CASE
               WHEN end_ladder_level <= 10 THEN '01 青铜-黄金'
               WHEN end_ladder_level <= 20 THEN '02 铂金-钻石'
               WHEN end_ladder_level <= 25 THEN '03 星耀'
               ELSE '04 王者以上'
           END AS rank_band,
           CASE WHEN end_ladder_level IN (3,6,10,15,20,25,28,31)
                THEN '升段临界（距下一大段 1 级）'
                ELSE '非升段临界' END AS goal_position
    FROM RankedAccountDay r
),
GoalOutcome AS (
    SELECT c.*, r1.lcx_id AS rerank_d1, r3.lcx_id AS rerank_d3,
           r1.end_ladder_level AS ladder_d1, r3.end_ladder_level AS ladder_d3
    FROM GoalCohort c
    LEFT JOIN RankedAccountDay r1 ON r1.lcx_id=c.lcx_id AND r1.fight_date=DATE_ADD('day',1,c.fight_date)
    LEFT JOIN RankedAccountDay r3 ON r3.lcx_id=c.lcx_id AND r3.fight_date=DATE_ADD('day',3,c.fight_date)
),
Labeled AS (
    SELECT g.*, CASE WHEN fight_date <= p.early_end THEN '前期（OBT-7/14）'
                      WHEN fight_date <= p.mid_end THEN '中期（7/15-8/4）'
                      ELSE '结算前期（8/5-8/25）' END AS season_phase,
           p.end_exclusive
    FROM GoalOutcome g CROSS JOIN params p
)
SELECT season_phase AS "赛季阶段",
       rank_band AS "段位带",
       goal_position AS "目标位置",
       COUNT(*) AS "账号日样本",
       ROUND(AVG(CAST(end_ladder_level AS DOUBLE)),2) AS "当日末段位均值",
       ROUND(AVG(CAST(ranked_matches AS DOUBLE)),2) AS "当日人均排位局数",
       ROUND(100.0 * AVG(CASE WHEN fight_date <= DATE_ADD('day',-1,end_exclusive) AND rerank_d1 IS NOT NULL THEN 1.0
                              WHEN fight_date <= DATE_ADD('day',-1,end_exclusive) THEN 0.0 END),2) AS "D+1再次排位率(%)",
       ROUND(100.0 * AVG(CASE WHEN fight_date <= DATE_ADD('day',-3,end_exclusive) AND rerank_d3 IS NOT NULL THEN 1.0
                              WHEN fight_date <= DATE_ADD('day',-3,end_exclusive) THEN 0.0 END),2) AS "D+3再次排位率(%)",
       ROUND(100.0 * AVG(CASE WHEN fight_date <= DATE_ADD('day',-1,end_exclusive) AND ladder_d1 > end_ladder_level THEN 1.0
                              WHEN fight_date <= DATE_ADD('day',-1,end_exclusive) THEN 0.0 END),2) AS "D+1段位提升率(%)",
       ROUND(100.0 * AVG(CASE WHEN fight_date <= DATE_ADD('day',-3,end_exclusive) AND ladder_d3 > end_ladder_level THEN 1.0
                              WHEN fight_date <= DATE_ADD('day',-3,end_exclusive) THEN 0.0 END),2) AS "D+3段位提升率(%)"
FROM Labeled
GROUP BY 1,2,3
ORDER BY 1,2,3;
