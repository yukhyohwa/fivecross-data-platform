/*
================================================================================
Game    : Jump Assemble (众星之聚) - TC Region (CBT2)
Report  : CBT2 玩家充值返利(跃之星/鸣人造型)与奖杯成就奖励结算统计
Date    : 2026-04-15 ~ 2026-04-23
Table   : ta.v_event_16
================================================================================
*/

WITH ScanConfig AS (
    SELECT 
        '2026-04-15' AS start_day,
        '2026-04-23' AS end_day
),

-- 1. 排除黑名单用户（内部测试与水军）
UserBlacklist AS (
    SELECT 'null' AS lcx_id
),

-- 2. 统计截止到结束日期的最后奖杯数
LatestTrophy AS ( 
    SELECT *
    FROM (
        SELECT 
            rolecommon.role_id,
            rolecommon.role_name,
            COALESCE(
                JSON_EXTRACT_SCALAR(v.fc_sdk_common, '$.lcx_id'), 
                v.sdkcommon.lcx_id, 
                v."#account_id"
            ) AS lcx_id,
            season_fight_trophy AS trophy_count,
            ROW_NUMBER() OVER(PARTITION BY rolecommon.role_id ORDER BY "#event_time" DESC) AS rank_idx
        FROM ta.v_event_16 AS v
        CROSS JOIN ScanConfig AS cfg
        WHERE v."$part_date" BETWEEN cfg.start_day AND cfg.end_day
          AND v."$part_event" = 'daily_role_snapshot'
    ) 
    WHERE rank_idx = 1
),

-- 3. 统计累计储值并计算跃之星
RechargeSummary AS (
    SELECT 
        "#account_id" AS lcx_id,
        -- 总累充金额 (TWD)
        SUM(v.payload.curamt / fx_usd.exchange * fx_twd.exchange) AS total_paid_twd,
        -- 礼包类金额 (TWD)
        SUM(CASE 
                WHEN v.payload.productid LIKE '%.gift%' 
                THEN v.payload.curamt / fx_usd.exchange * fx_twd.exchange 
                ELSE 0 
            END) AS gift_paid_twd,
        -- 基础跃之星计算 (正则提取 x 后的数字)
        SUM(CASE 
                WHEN v.payload.productid NOT LIKE '%.gift%' 
                THEN CAST(REGEXP_EXTRACT("payload.productid@product_name", '(?i)x(\d+)', 1) AS INT) 
                ELSE 0 
            END) AS base_star_stones
    FROM ta.v_event_16 AS v
    CROSS JOIN ScanConfig AS cfg
    LEFT JOIN ta_dim.dim_16_0_23989 pd ON v.payload.productid = pd."payload.productid@product_id"
    LEFT JOIN ta_dim.ta_exchange AS fx_usd
        ON  v."$part_date" = fx_usd.ex_date 
        AND v.payload.cur = fx_usd.currency
    LEFT JOIN ta_dim.ta_exchange AS fx_twd
        ON  v."$part_date" = fx_twd.ex_date 
        AND fx_twd.currency = 'TWD'
    WHERE v."$part_date" BETWEEN cfg.start_day AND cfg.end_day
      AND v."$part_event" = 'PURCHASE'
      AND v.payload.validationtype <> 'SANDBOX_RECEIPT'
    GROUP BY 1
)

-- 4. 汇总结果并计算正式上线回馈
SELECT 
    t.lcx_id,
    t.role_id,
    t.role_name,

    COALESCE(r.total_paid_twd, 0) AS "累積儲值",
    COALESCE(r.gift_paid_twd, 0) AS "累積儲值(直購禮包)",
    COALESCE(r.base_star_stones, 0) AS "儲值躍之星",
    
    -- 换算逻辑：礼包金额*2 + 普通充值提取的数字
    (COALESCE(r.gift_paid_twd, 0) * 2 + COALESCE(r.base_star_stones, 0)) AS "总躍之星(含直購禮包換算)",
    
    -- 计算回馈跃之星：1~12000 部分 150%，超过部分 100%
    CASE 
        WHEN (COALESCE(r.gift_paid_twd, 0) * 2 + COALESCE(r.base_star_stones, 0)) <= 12000 
            THEN (COALESCE(r.gift_paid_twd, 0) * 2 + COALESCE(r.base_star_stones, 0)) * 1.5
        ELSE (12000 * 1.5) + ((COALESCE(r.gift_paid_twd, 0) * 2 + COALESCE(r.base_star_stones, 0)) - 12000)
    END AS "回饋躍之星",
    
    -- 判定鸣人造型资格
    CASE 
        WHEN (COALESCE(r.gift_paid_twd, 0) * 2 + COALESCE(r.base_star_stones, 0)) >= 2000 
            THEN 1 
        ELSE 0 
    END AS "鳴人造型-迷濛拂曉",
    
    t.trophy_count AS "總獎盃數",
    
    CASE 
        WHEN t.trophy_count >= 100 
             THEN 1000 
        ELSE 0
    END AS "紀念幣",
    
    CASE 
        WHEN t.trophy_count >= 100 
             THEN 100
        ELSE 0
    END AS "能量石",
    
    CASE 
        WHEN t.trophy_count >= 200
             THEN 200 
        ELSE 0
    END AS "意志結晶",

    CASE 
        WHEN t.trophy_count >= 300 
             THEN 1
        ELSE 0
    END AS "新手入場動作箱",
    
    CASE 
        WHEN t.trophy_count >= 500 
             THEN 1
        ELSE 0
    END AS "英雄往紀頭像框"

FROM LatestTrophy AS t
LEFT JOIN RechargeSummary AS r ON t.lcx_id = r.lcx_id
LEFT JOIN UserBlacklist AS ub ON t.lcx_id = ub.lcx_id
WHERE ub.lcx_id IS NULL
ORDER BY "累積儲值" DESC;
