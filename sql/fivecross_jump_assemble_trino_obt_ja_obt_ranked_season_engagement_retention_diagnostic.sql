/*
================================================================================
Game    : Jump Assemble 3v3 OBT (TW) 
Report  : 排位賽參與深度、停留與賽季末動力診斷
Purpose : 判斷 2026-06-24 OBT 至 2026-08-25（8/26 結算前）期間，排位追求
          是否弱化；將整體活躍流失與既活躍用戶不再投入排位區分開。
Environment: Trino (ThinkingData)

Output grain
  1. 每日 × 賽季階段 × 當日排位深度分組。
  2. 最後 7 天沒有足夠觀察窗的 D+7 欄位固定為 NULL，不得解讀為 0%。

Key definitions
  - 活躍：LOGIN_SUCCESS 或 NUU 的去重裝置（OBT 核心 KPI 口徑）。
  - 排位參與／深度／回流：去重 lcx_id（同一裝置多帳號不會被合併）。
    這是因為 arena_fight 目前可穩定取得帳號而非 fixed_deviceid；請勿將
    「排位帳號數」直接與「設備 DAU」相加。
  - 一局：同一 lcx_id + battle_id 只計一次，避免重送事件膨脹對局數。
  - 排位：model_type = 2。排位玩法 game_type 清單沿用已驗證的平衡稽核口徑。

Readout order
  A. 先看活躍帳號中的排位參與占比、每位參與者局數與重度占比；
  B. 再看各深度分組的 D+1/D+3/D+7「登入」與「再次排位」率；
  C. 只有在活躍基數穩定、排位深度下降且再次排位率同步下降時，才可判為
     排位動力轉弱。若 DAU 同步下滑，必須以份額與條件留存為主。

Important limitations
  - arena_fight 未驗證 party_id，因此不可由本 SQL 推論單排／多排原因。
  - 本 SQL 不產出獎勵、任務或版本更新紀錄；若趨勢確認，需與營運日曆對齊。
================================================================================
*/

WITH
params AS (
    SELECT
        DATE '2026-06-24' AS obt_start_date, -- 若實際 OBT 開服日不同，僅修改此處
        DATE '2026-08-26' AS season_end_exclusive, -- 8/26 為結算日，分析只涵蓋 8/25
        DATE '2026-07-14' AS early_end_date,
        DATE '2026-08-04' AS mid_end_date
),

UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

AccountDevice AS (
    SELECT
        "#varchar_id" AS lcx_id,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid
    FROM user_result_cluster_23
    WHERE cluster_name = 'fixed_deviceid'
    GROUP BY 1
),

-- 先找出黑名單所關聯的整台裝置；核心 KPI 口徑需整台排除。
BlockedDevice AS (
    SELECT DISTINCT ad.fixed_deviceid
    FROM UserBlacklist ub
    JOIN AccountDevice ad ON ub.lcx_id = ad.lcx_id
    WHERE ad.fixed_deviceid IS NOT NULL AND ad.fixed_deviceid <> ''
),

ActiveAccountDay AS (
    SELECT DISTINCT
        CAST(v."$part_date" AS DATE) AS activity_date,
        COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
        COALESCE(NULLIF(ad.fixed_deviceid, ''), CONCAT('unknown_', CAST(COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS VARCHAR))) AS device_id
    FROM ta.v_event_23 v
    CROSS JOIN params p
    LEFT JOIN AccountDevice ad
      ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ad.lcx_id
    LEFT JOIN UserBlacklist ub
      ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
    LEFT JOIN BlockedDevice bd
      ON ad.fixed_deviceid = bd.fixed_deviceid
    WHERE v."$part_date" >= CAST(p.obt_start_date AS VARCHAR)
      AND v."$part_date" <= CAST(DATE_ADD('day', 7, p.season_end_exclusive) AS VARCHAR)
      AND v."$part_event" IN ('LOGIN_SUCCESS', 'NUU')
      AND ub.lcx_id IS NULL
      AND bd.fixed_deviceid IS NULL
),

ActiveDeviceDay AS (
    SELECT DISTINCT activity_date, device_id
    FROM ActiveAccountDay
),

RankedFightRaw AS (
    SELECT *
    FROM (
        SELECT
            CAST(v."$part_date" AS DATE) AS fight_date,
            COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") AS lcx_id,
            v.battle_id,
            TRY_CAST(v.player_ladder_level AS INTEGER) AS ladder_level,
            TRY_CAST(v.rank AS INTEGER) AS side_rank,
            TRY_CAST(COALESCE(v.robot_num, 0) AS INTEGER) AS robot_num,
            ROW_NUMBER() OVER (
                PARTITION BY CAST(v."$part_date" AS DATE),
                             COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id"),
                             v.battle_id
                ORDER BY v."#event_time" DESC
            ) AS rn
        FROM ta.v_event_23 v
        CROSS JOIN params p
        LEFT JOIN UserBlacklist ub
          ON COALESCE(v.fc_sdk_common.lcx_id, v.sdkcommon.lcx_id, v."#account_id") = ub.lcx_id
        WHERE v."$part_date" >= CAST(p.obt_start_date AS VARCHAR)
          AND v."$part_date" < CAST(p.season_end_exclusive AS VARCHAR)
          AND v."$part_event" = 'arena_fight'
          AND TRY_CAST(v.model_type AS INTEGER) = 2
          AND TRY_CAST(v.game_type AS INTEGER) IN (1, 5, 7, 8, 9, 11, 15)
          AND v.battle_id IS NOT NULL
          AND ub.lcx_id IS NULL
    ) x
    WHERE rn = 1
),

RankedAccountDay AS (
    SELECT
        fight_date,
        lcx_id,
        COUNT(DISTINCT battle_id) AS ranked_matches,
        MAX(ladder_level) AS max_ladder_level,
        AVG(CASE WHEN side_rank = 1 THEN 1.0 WHEN side_rank = 2 THEN 0.0 END) AS win_rate,
        AVG(CASE WHEN robot_num > 0 THEN 1.0 ELSE 0.0 END) AS bot_match_share
    FROM RankedFightRaw
    GROUP BY 1, 2
),

DailyRankedCohort AS (
    SELECT
        r.*,
        CASE
            WHEN ranked_matches = 1 THEN '1局（試玩）'
            WHEN ranked_matches BETWEEN 2 AND 4 THEN '2-4局（輕度）'
            WHEN ranked_matches BETWEEN 5 AND 9 THEN '5-9局（中度）'
            ELSE '10局以上（重度）'
        END AS depth_segment
    FROM RankedAccountDay r
),

-- 以同一帳號的未來登入／再次排位衡量停留；未成熟觀察窗保留 NULL。
RetentionByDepth AS (
    SELECT
        c.fight_date,
        c.depth_segment,
        COUNT(DISTINCT c.lcx_id) AS ranked_accounts,
        COUNT(DISTINCT CASE WHEN a1.lcx_id IS NOT NULL THEN c.lcx_id END) AS login_d1_accounts,
        COUNT(DISTINCT CASE WHEN a3.lcx_id IS NOT NULL THEN c.lcx_id END) AS login_d3_accounts,
        COUNT(DISTINCT CASE WHEN a7.lcx_id IS NOT NULL THEN c.lcx_id END) AS login_d7_accounts,
        COUNT(DISTINCT CASE WHEN r1.lcx_id IS NOT NULL THEN c.lcx_id END) AS ranked_d1_accounts,
        COUNT(DISTINCT CASE WHEN r3.lcx_id IS NOT NULL THEN c.lcx_id END) AS ranked_d3_accounts,
        COUNT(DISTINCT CASE WHEN r7.lcx_id IS NOT NULL THEN c.lcx_id END) AS ranked_d7_accounts
    FROM DailyRankedCohort c
    CROSS JOIN params p
    LEFT JOIN ActiveAccountDay a1 ON a1.lcx_id = c.lcx_id AND a1.activity_date = DATE_ADD('day', 1, c.fight_date)
    LEFT JOIN ActiveAccountDay a3 ON a3.lcx_id = c.lcx_id AND a3.activity_date = DATE_ADD('day', 3, c.fight_date)
    LEFT JOIN ActiveAccountDay a7 ON a7.lcx_id = c.lcx_id AND a7.activity_date = DATE_ADD('day', 7, c.fight_date)
    LEFT JOIN RankedAccountDay r1 ON r1.lcx_id = c.lcx_id AND r1.fight_date = DATE_ADD('day', 1, c.fight_date)
    LEFT JOIN RankedAccountDay r3 ON r3.lcx_id = c.lcx_id AND r3.fight_date = DATE_ADD('day', 3, c.fight_date)
    LEFT JOIN RankedAccountDay r7 ON r7.lcx_id = c.lcx_id AND r7.fight_date = DATE_ADD('day', 7, c.fight_date)
    GROUP BY 1, 2
),

DailySummary AS (
    SELECT
        r.fight_date,
        COUNT(DISTINCT r.lcx_id) AS ranked_accounts,
        -- RankedAccountDay 已是帳號×日粒度，battle_id 在此層已被聚合；
        -- 以各帳號當日去重局數加總，得到全日玩家對局量。
        SUM(r.ranked_matches) AS ranked_matches,
        AVG(CAST(r.ranked_matches AS DOUBLE)) AS matches_per_ranked_account,
        AVG(CASE WHEN r.ranked_matches >= 5 THEN 1.0 ELSE 0.0 END) AS medium_plus_share,
        AVG(CASE WHEN r.ranked_matches >= 10 THEN 1.0 ELSE 0.0 END) AS heavy_share,
        AVG(r.win_rate) AS avg_win_rate,
        AVG(r.bot_match_share) AS avg_bot_match_share,
        AVG(CAST(r.max_ladder_level AS DOUBLE)) AS avg_daily_max_ladder
    FROM RankedAccountDay r
    GROUP BY 1
),

DailyActive AS (
    SELECT activity_date, COUNT(DISTINCT device_id) AS active_devices
    FROM ActiveDeviceDay
    GROUP BY 1
),

DailyActiveAccount AS (
    SELECT activity_date, COUNT(DISTINCT lcx_id) AS active_accounts
    FROM ActiveAccountDay
    GROUP BY 1
),

-- 交付兩種資料列：daily_total 供趨勢圖；depth_retention 供深度×停留熱圖／表格。
FinalDaily AS (
    SELECT
        d.fight_date AS report_date,
        CASE
            WHEN d.fight_date <= p.early_end_date THEN '前期（OBT-7/14）'
            WHEN d.fight_date <= p.mid_end_date THEN '中期（7/15-8/4）'
            ELSE '結算前期（8/5-8/25）'
        END AS season_phase,
        a.active_devices,
        aa.active_accounts,
        d.ranked_accounts,
        d.ranked_matches,
        ROUND(100.0 * d.ranked_accounts / NULLIF(aa.active_accounts, 0), 2) AS ranked_accounts_per_active_account_pct,
        ROUND(d.matches_per_ranked_account, 2) AS matches_per_ranked_account,
        ROUND(100.0 * d.medium_plus_share, 2) AS medium_plus_share_pct,
        ROUND(100.0 * d.heavy_share, 2) AS heavy_share_pct,
        ROUND(100.0 * d.avg_win_rate, 2) AS avg_win_rate_pct,
        ROUND(100.0 * d.avg_bot_match_share, 2) AS avg_bot_match_share_pct,
        ROUND(d.avg_daily_max_ladder, 2) AS avg_daily_max_ladder
    FROM DailySummary d
    CROSS JOIN params p
    LEFT JOIN DailyActive a ON d.fight_date = a.activity_date
    LEFT JOIN DailyActiveAccount aa ON d.fight_date = aa.activity_date
)

SELECT
    'daily_total' AS result_type,
    CAST(report_date AS VARCHAR) AS "日期",
    season_phase AS "賽季階段",
    NULL AS "當日排位深度",
    active_devices AS "活躍裝置數",
    active_accounts AS "活躍帳號數",
    ranked_accounts AS "排位帳號數",
    ranked_matches AS "排位對局數",
    ranked_accounts_per_active_account_pct AS "活躍帳號中排位參與占比(%)",
    matches_per_ranked_account AS "每排位帳號局數",
    medium_plus_share_pct AS "中度以上占比(%)",
    heavy_share_pct AS "重度占比(%)",
    avg_win_rate_pct AS "平均勝率(%)",
    avg_bot_match_share_pct AS "含機器人局占比(%)",
    avg_daily_max_ladder AS "當日最高段位均值",
    NULL AS "D+1登入率(%)", NULL AS "D+3登入率(%)", NULL AS "D+7登入率(%)",
    NULL AS "D+1再次排位率(%)", NULL AS "D+3再次排位率(%)", NULL AS "D+7再次排位率(%)"
FROM FinalDaily

UNION ALL

SELECT
    'depth_retention' AS result_type,
    CAST(r.fight_date AS VARCHAR) AS "日期",
    CASE
        WHEN r.fight_date <= p.early_end_date THEN '前期（OBT-7/14）'
        WHEN r.fight_date <= p.mid_end_date THEN '中期（7/15-8/4）'
        ELSE '結算前期（8/5-8/25）'
    END AS "賽季階段",
    r.depth_segment AS "當日排位深度",
    NULL, NULL, r.ranked_accounts, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    CASE WHEN r.fight_date <= DATE_ADD('day', -1, p.season_end_exclusive) THEN ROUND(100.0 * r.login_d1_accounts / NULLIF(r.ranked_accounts, 0), 2) END,
    CASE WHEN r.fight_date <= DATE_ADD('day', -3, p.season_end_exclusive) THEN ROUND(100.0 * r.login_d3_accounts / NULLIF(r.ranked_accounts, 0), 2) END,
    CASE WHEN r.fight_date <= DATE_ADD('day', -7, p.season_end_exclusive) THEN ROUND(100.0 * r.login_d7_accounts / NULLIF(r.ranked_accounts, 0), 2) END,
    CASE WHEN r.fight_date <= DATE_ADD('day', -1, p.season_end_exclusive) THEN ROUND(100.0 * r.ranked_d1_accounts / NULLIF(r.ranked_accounts, 0), 2) END,
    CASE WHEN r.fight_date <= DATE_ADD('day', -3, p.season_end_exclusive) THEN ROUND(100.0 * r.ranked_d3_accounts / NULLIF(r.ranked_accounts, 0), 2) END,
    CASE WHEN r.fight_date <= DATE_ADD('day', -7, p.season_end_exclusive) THEN ROUND(100.0 * r.ranked_d7_accounts / NULLIF(r.ranked_accounts, 0), 2) END
FROM RetentionByDepth r
CROSS JOIN params p

ORDER BY 1, 2, 4;
