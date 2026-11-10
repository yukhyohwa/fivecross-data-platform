/*
================================================================================
Game: Jump Assemble (众星之聚)
Region: TC (Traditional Chinese - TW/HK/MO)
Description: 新手引导漏斗 (使用【用户标签】加速方案)
             1. 使用 UserProfileDetail (来自 user_result_cluster_16) 确定注册日期。
             2. 移除了对比逻辑，直接以 fixed_regdate 作为时间维度。
             3. 优化了分母计算，基于标签系统的注册日期。
Environment: Trino (TA)
================================================================================
*/

WITH

-- 1. [性能优化] 自动计算扫描边界 (基于 PartDate:date1)
ScanConfig AS (
    SELECT 
        MIN(CAST("$part_date" AS DATE)) AS target_start_date,
        MAX(CAST("$part_date" AS DATE)) AS target_end_date
    FROM ta.v_event_16
    WHERE ${PartDate:date1}
),

-- 2. 用户标签数据 (核心加速方案)
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_country' THEN tag_value END) AS fixed_country, 
        MAX(CASE WHEN cluster_name = 'fixed_affcode' THEN tag_value END) AS fixed_affcode, 
        MAX(CASE WHEN cluster_name = 'fixed_os'      THEN tag_value END) AS fixed_os, 
        MAX(CASE WHEN cluster_name = 'fixed_store'   THEN tag_value END) AS fixed_store, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate 
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_country', 'fixed_affcode', 'fixed_os', 'fixed_store', 'fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 3. 确定目标用户群 (基于 fixed_regdate 过滤，作为分母基础)
CohortUsers AS (
    SELECT 
        u."#account_id" AS lcx_id,
        u.fixed_regdate AS period
    FROM UserProfileDetail u
    CROSS JOIN ScanConfig sc
    WHERE CAST(u.fixed_regdate AS DATE) BETWEEN sc.target_start_date AND sc.target_end_date
    AND u.fixed_os = 'iOS'
),

-- 4. 提取引导相关事件日志
RoleGuideLogs AS (
    SELECT 
        s1.guide_id,
        s1."$part_event",
        s2.lcx_id,
        s2.period 
    FROM ta.v_event_16 s1
    INNER JOIN CohortUsers s2 
        ON (CASE WHEN s1."$part_event" = 'NUU' THEN s1."#account_id" ELSE json_extract_scalar(s1.fc_sdk_common, '$.lcx_id') END) = s2.lcx_id
    CROSS JOIN ScanConfig sc
    -- 扫描时间从注册开始时间开始，确保覆盖所有后续步骤
    WHERE s1."$part_date" >= CAST(sc.target_start_date AS VARCHAR)
        AND s1."$part_event" IN ('NUU','role_guide_before','role_guide','force_guide')
)

-- 5. 漏斗步骤聚合与转化率计算
SELECT 
    p1.period AS "注册日期",
    p1."引导步骤",
    p1.funnel_counts AS "触发人数",
    p2.new_lcxid AS "注册人数",
    ROUND(p1.funnel_counts * 1.0 / NULLIF(CAST(p2.new_lcxid AS DOUBLE), 0), 4) AS "转化率"
FROM (
    SELECT 
        s1.period,
        CASE 
            WHEN s1."$part_event" IN ('NUU') THEN '注册'
            WHEN s1.guide_id = 2      THEN '问卷完成'
            WHEN s1.guide_id = 3      THEN '选择英雄加载完成' -- '选择英雄界面'
            WHEN s1.guide_id = 4      THEN '选择英雄完成'
            WHEN s1.guide_id = 5      THEN '引导加载完成'
            WHEN s1.guide_id = 6      THEN '引导pv播放完成'
            WHEN s1.guide_id IN (100001,200001,300001) THEN '开始新手教学'
            WHEN s1.guide_id IN (100011,200011,300011) THEN '移动指定位置'
            WHEN s1.guide_id IN (100021,200021,300021) THEN '拖动普攻木桩'
            WHEN s1.guide_id IN (100031,200031,300031) THEN '点击普攻木桩'
            WHEN s1.guide_id IN (100041,200041,300041) THEN '技能攻击木桩'
            WHEN s1.guide_id IN (100051,200051,300051) THEN '大招攻击木桩'
            WHEN s1.guide_id = 7      THEN '打开引导战斗界面'
            WHEN s1.guide_id = 8      THEN '点击开始引导战斗'
            WHEN s1.guide_id = 9      THEN '引导战斗加载完成'
            WHEN s1.guide_id = 10     THEN '引导战斗开始'       -- '引导战斗完成'
            WHEN s1.guide_id = 11     THEN '引导战斗开始1分钟'  -- '获得英雄界面'
            WHEN s1.guide_id = 12     THEN '引导战斗开始2分钟'  -- '展示英雄界面'
            WHEN s1.guide_id = 13     THEN '引导战斗完成'       -- '引导流程完成'
            WHEN s1.guide_id = 14     THEN '打开引导获得英雄界面'
            WHEN s1.guide_id = 15     THEN '打开引导展示英雄界面'
            WHEN s1.guide_id = 16     THEN '引导流程完成'
            WHEN s1.guide_id = 150    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 151    THEN '点击领取第一个奖励'
            WHEN s1.guide_id = 152    THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 200    THEN '点击【角色】'
            WHEN s1.guide_id = 201    THEN '选中当前拥有的英雄'
            WHEN s1.guide_id = 202    THEN '点击设定集界面的【升级】'
            WHEN s1.guide_id = 203    THEN '点击窗口中的【升级】'
            WHEN s1.guide_id = 204    THEN '点击关闭窗口'
            WHEN s1.guide_id = 205    THEN '点击退出【设定集】，返回主界面'
            WHEN s1.guide_id = 206    THEN '点击退出角色列表，返回主界面'
            WHEN s1.guide_id = 301    THEN '点击【漫斗赛】入口'
            WHEN s1.guide_id = 302    THEN '选择第1个入口'
            WHEN s1.guide_id = 303    THEN '点击开始'
            WHEN s1.guide_id = 304    THEN '战斗结束'
            WHEN s1.guide_id = 305    THEN '返回主界面'
            WHEN s1.guide_id = 500    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 501    THEN '点击领取第二个奖励（阅览券）'
            WHEN s1.guide_id = 502    THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 503    THEN '点击【刊物】，进入刊物中心'
            WHEN s1.guide_id = 504    THEN '点击【兑换十次】，使用阅览券进行抽奖'
            WHEN s1.guide_id = 505    THEN '点击【刊物中心】，返回主界面'
            WHEN s1.guide_id = 506    THEN '点击【漫斗赛】入口'
            WHEN s1.guide_id = 507    THEN '选择大乱斗'
            WHEN s1.guide_id = 508    THEN '选择单人乱斗'
            WHEN s1.guide_id = 509    THEN '点击更换英雄按钮'
            WHEN s1.guide_id = 1100   THEN '惊喜宝箱'
            WHEN s1.guide_id = 1200   THEN '点击【角色】'
            WHEN s1.guide_id = 1201   THEN '点击选中第一个角色'
            WHEN s1.guide_id = 1202   THEN '点击觉醒圆形图标'
            WHEN s1.guide_id = 1203   THEN '点击【觉醒】，完成觉醒'
            WHEN s1.guide_id = 1204   THEN '点击【角色】'
            WHEN s1.guide_id = 1205   THEN '点击选中第一个角色'
            WHEN s1.guide_id = 1206   THEN '点击第一个天赋槽位'
            WHEN s1.guide_id = 1027   THEN '点击激活按钮'
            WHEN s1.guide_id = 600    THEN '返回主界面'
            WHEN s1.guide_id = 601    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 602    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 603    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 604    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 605    THEN '点击领取第4个奖励（战令）'
            WHEN s1.guide_id = 606    THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 607    THEN '点击战令入口'
            WHEN s1.guide_id = 608    THEN '奖励介绍（点任何按钮或者空白区域都进入下一步）'
            WHEN s1.guide_id = 609    THEN '介绍赛季任务'
            WHEN s1.guide_id = 700    THEN '返回主界面'
            WHEN s1.guide_id = 701    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 702    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 703    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 704    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 705    THEN '点击领取第5个奖励（活动）'
            WHEN s1.guide_id = 706    THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 707    THEN '点击活动入口（需要特殊处理，按钮在滚顿）'
            WHEN s1.guide_id = 708    THEN '奖励介绍（加机制）'
            WHEN s1.guide_id = 900    THEN '返回主界面'
            WHEN s1.guide_id = 901    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 902    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 903    THEN '结算有多个独立界面'
            WHEN s1.guide_id = 904    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 905    THEN '点击领取第7个奖励（成就）'
            WHEN s1.guide_id = 906    THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 907    THEN '点击成就按钮'
            WHEN s1.guide_id = 908    THEN '介绍漫画成就'
            WHEN s1.guide_id = 909    THEN '介绍玩家成就'
            WHEN s1.guide_id = 1001   THEN '返回主界面'
            WHEN s1.guide_id = 1002   THEN '结算有多个独立界面'
            WHEN s1.guide_id = 1003   THEN '结算有多个独立界面'
            WHEN s1.guide_id = 1004   THEN '结算有多个独立界面'
            WHEN s1.guide_id = 1005   THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 1006   THEN '点击领取第9个奖励（排位）'
            WHEN s1.guide_id = 1007   THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 1008   THEN '点击【排位赛】入口'
            WHEN s1.guide_id = 1009   THEN '介绍【赛季奖励】'
            WHEN s1.guide_id = 1010   THEN '介绍【荣耀战区】'
            WHEN s1.guide_id = 1011   THEN '介绍【排位开始】'
            WHEN s1.guide_id = 1012   THEN '介绍排位赛的星级'
            WHEN s1.guide_id = 1101   THEN '点击每日胜场tips'
            WHEN s1.guide_id = 1102   THEN '点击【排位赛】，进入排位房间'
            WHEN s1.guide_id = 1103   THEN '点击【漫斗赛】入口'
            WHEN s1.guide_id = 1301   THEN '返回主界面'
            WHEN s1.guide_id = 1302   THEN '结算有多个独立界面'
            WHEN s1.guide_id = 1303   THEN '结算有多个独立界面'
            WHEN s1.guide_id = 1304   THEN '结算有多个独立界面'
            WHEN s1.guide_id = 1305   THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 1306   THEN '点击领取第11个奖励（社团）'
            WHEN s1.guide_id = 1307   THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 1308   THEN '点击【社团】入口'
            WHEN s1.guide_id = 1309   THEN '介绍社团搜索功能'
            WHEN s1.guide_id = 1310   THEN '介绍社团创建功能'
        END "引导步骤",
        COUNT(DISTINCT lcx_id) funnel_counts
    FROM RoleGuideLogs s1 
    GROUP BY 1, 2
) p1
LEFT JOIN (
    SELECT 
        period,
        COUNT(DISTINCT lcx_id) new_lcxid 
    FROM CohortUsers
    GROUP BY 1
) p2 ON p1.period = p2.period
WHERE p1."引导步骤" IS NOT NULL
ORDER BY p1.period, p1.funnel_counts DESC;
