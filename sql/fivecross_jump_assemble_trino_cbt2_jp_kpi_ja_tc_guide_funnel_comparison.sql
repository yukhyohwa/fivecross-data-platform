/*
================================================================================
Game    : Jump Assemble (跳跃集结)
Region  : TC (Traditional Chinese)
Report  : 新手引导漏斗 — 事件时间 vs 对比时间
Description:
    统计两个时段内，NUU 新用户在各引导步骤的完成人数及转化率。
    黑名单来源：user_result_cluster_16（internal_users / is_water 标签）
    用户 ID 关联：NUU 事件用 "#account_id"，其余引导事件用 lcxsdkcommon.lcx_id
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 黑名单（internal_users / is_water 标签）
--------------------------------------------------------------------------------
UserBlacklist AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 用户标签（用于扩展过滤，如 OS / 国家等）
--------------------------------------------------------------------------------
UserProfileDetail AS (
    SELECT
        "#varchar_id"                                                           AS "#account_id",
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END)       AS fixed_country,
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END)       AS fixed_affcode,
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END)       AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END)       AS fixed_store,
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END)       AS fixed_regdate
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

--------------------------------------------------------------------------------
-- 3. 时段维表：将两个参数日期打上 period 标记
--------------------------------------------------------------------------------
DimPeriod AS (
    SELECT DISTINCT
        CASE
            WHEN ${PartDate:date1} THEN '事件时间'
            WHEN ${PartDate:date2} THEN '对比时间'
        END                 AS period,
        "$part_date"
    FROM ta.v_event_16
    WHERE (${PartDate:date1} OR ${PartDate:date2})
),

--------------------------------------------------------------------------------
-- 4. Cohort 用户集：两个时段内触发 NUU 的新用户
--    用 "#account_id" 作为统一 ID（NUU 事件的主键）
--    排除黑名单
--------------------------------------------------------------------------------
CohortUsers AS (
    SELECT
        e."#account_id"     AS lcx_id,
        d.period
    FROM ta.v_event_16 e
    JOIN DimPeriod d
        ON e."$part_date" = d."$part_date"
    LEFT JOIN UserBlacklist bl
        ON e."#account_id" = bl.lcx_id
    WHERE e."$part_event" = 'NUU'
      AND bl.lcx_id IS NULL
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 5. 引导行为明细
--    NUU 事件：用 "#account_id" 关联
--    其余引导事件：用 lcxsdkcommon.lcx_id 关联
--    扫描范围：DimPeriod 覆盖的最早日期起
--------------------------------------------------------------------------------
RoleGuideLogs AS (
    SELECT
        s1.guide_id,
        s1."$part_event",
        s2.lcx_id,
        s2.period
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers s2
        ON CASE
               WHEN s1."$part_event" = 'NUU'
               THEN s1."#account_id"
               ELSE s1.lcxsdkcommon.lcx_id
           END = s2.lcx_id
    WHERE s1."$part_event" IN (
              'NUU',
              'role_guide_before',
              'role_guide',
              'force_guide'
          )
      AND s1."$part_date" >= (SELECT MIN("$part_date") FROM DimPeriod)
)

--------------------------------------------------------------------------------
-- 6. 最终输出：各引导步骤完成人数 / 注册人数 = 转化率
--------------------------------------------------------------------------------
SELECT
    p1.period,
    p1."引导步骤",
    p1.funnel_counts                                                            AS "完成人数",
    p2.new_lcxid                                                                AS "注册人数",
    p1.funnel_counts * 1.0 / NULLIF(CAST(p2.new_lcxid AS DOUBLE), 0)           AS "转化率"
FROM (
    SELECT
        s1.period,
        CASE
            WHEN s1."$part_event" IN ('NUU')              THEN '注册'
            WHEN s1.guide_id = 2                          THEN '问卷完成'
            WHEN s1.guide_id = 3                          THEN '选择英雄加载完成'
            WHEN s1.guide_id = 4                          THEN '选择英雄完成'
            WHEN s1.guide_id = 5                          THEN '引导加载完成'
            WHEN s1.guide_id = 6                          THEN '引导PV播放完成'
            WHEN s1.guide_id IN (100001,200001,300001)    THEN '开始新手教学'
            WHEN s1.guide_id IN (100011,200011,300011)    THEN '移动指定位置'
            WHEN s1.guide_id IN (100021,200021,300021)    THEN '拖动普攻木桩'
            WHEN s1.guide_id IN (100031,200031,300031)    THEN '点击普攻木桩'
            WHEN s1.guide_id IN (100041,200041,300041)    THEN '技能攻击木桩'
            WHEN s1.guide_id IN (100051,200051,300051)    THEN '大招攻击木桩'
            WHEN s1.guide_id = 7                          THEN '打开引导战斗界面'
            WHEN s1.guide_id = 8                          THEN '点击开始引导战斗'
            WHEN s1.guide_id = 9                          THEN '引导战斗加载完成'
            WHEN s1.guide_id = 10                         THEN '引导战斗开始'
            WHEN s1.guide_id = 11                         THEN '引导战斗开始1分钟'
            WHEN s1.guide_id = 12                         THEN '引导战斗开始2分钟'
            WHEN s1.guide_id = 13                         THEN '引导战斗完成'
            WHEN s1.guide_id = 14                         THEN '打开引导获得英雄界面'
            WHEN s1.guide_id = 15                         THEN '打开引导展示英雄界面'
            WHEN s1.guide_id = 16                         THEN '引导流程完成'
            WHEN s1.guide_id = 150                        THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 151                        THEN '点击领取第一个奖励'
            WHEN s1.guide_id = 152                        THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 200                        THEN '点击【角色】'
            WHEN s1.guide_id = 201                        THEN '选中当前拥有的英雄'
            WHEN s1.guide_id = 202                        THEN '点击设定集界面的【升级】'
            WHEN s1.guide_id = 203                        THEN '点击窗口中的【升级】'
            WHEN s1.guide_id = 204                        THEN '点击关闭窗口'
            WHEN s1.guide_id = 205                        THEN '点击退出【设定集】，返回主界面'
            WHEN s1.guide_id = 206                        THEN '点击退出角色列表，返回主界面'
            WHEN s1.guide_id = 301                        THEN '点击【排位赛】入口'
            WHEN s1.guide_id = 302                        THEN '点击【单人排位】按钮'
            WHEN s1.guide_id = 303                        THEN '选择第一个英雄'
            WHEN s1.guide_id = 304                        THEN '点击【确定】按钮'
            WHEN s1.guide_id = 305                        THEN '战斗结束'
            WHEN s1.guide_id = 500                        THEN '点击【荣誉之路】图标(500)'
            WHEN s1.guide_id = 501                        THEN '点击领取第二个奖励（阅览券）'
            WHEN s1.guide_id = 502                        THEN '点击【总奖杯奖励】，返回主界面(502)'
            WHEN s1.guide_id = 503                        THEN '点击【刊物】，进入刊物中心'
            WHEN s1.guide_id = 504                        THEN '点击【兑换十次】，进行抽奖'
            WHEN s1.guide_id = 505                        THEN '点击【刊物中心】，返回'
            WHEN s1.guide_id = 506                        THEN '点击【漫斗赛】入口'
            WHEN s1.guide_id = 507                        THEN '选择大乱斗'
            WHEN s1.guide_id = 508                        THEN '选择单人乱斗'
            WHEN s1.guide_id = 509                        THEN '点击更换英雄按钮'
            WHEN s1.guide_id = 605                        THEN '点击领取第4个奖励（战令）'
            WHEN s1.guide_id = 705                        THEN '点击领取第5个奖励（活动）'
            WHEN s1.guide_id = 905                        THEN '点击领取第7个奖励（成就）'
            WHEN s1.guide_id = 908                        THEN '点击成就按钮'
            WHEN s1.guide_id = 1100                       THEN '惊喜宝箱'
            WHEN s1.guide_id = 1200                       THEN '点击【角色】(1200)'
            WHEN s1.guide_id = 1201                       THEN '点击选中第一个角色'
            WHEN s1.guide_id = 1202                       THEN '点击觉醒圆形图标'
            WHEN s1.guide_id = 1206                       THEN '点击第一个天赋槽位'
        END                                                                     AS "引导步骤",
        COUNT(DISTINCT lcx_id)                                                  AS funnel_counts
    FROM RoleGuideLogs s1
    GROUP BY 1, 2
) p1
LEFT JOIN (
    SELECT
        period,
        COUNT(DISTINCT lcx_id)  AS new_lcxid
    FROM RoleGuideLogs
    WHERE "$part_event" IN ('NUU')
    GROUP BY 1
) p2 ON p1.period = p2.period
WHERE p1."引导步骤" IS NOT NULL
ORDER BY p1.period, p1.funnel_counts DESC;
