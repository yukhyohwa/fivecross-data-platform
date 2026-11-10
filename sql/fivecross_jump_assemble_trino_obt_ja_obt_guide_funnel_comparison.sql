/*
================================================================================
Game    : Jump Assemble (众星之聚 / 跳跃集结)
Region  : TC (Traditional Chinese)
Report  : 新手引导漏斗 - OBT 本期与对比期对比 (带排序ID)
Description:
    统计 OBT 期间，本期(date1)和对比期(date2)的新用户在各新手引导步骤的完成人数及转化率。
    关联 user_result_cluster_23 获取用户最早注册日期并排除 internal_users 黑名单。
Environment: Trino (TA)
================================================================================
*/

WITH
-- 1. 过滤内部账号黑名单
UserBlacklist AS (
    SELECT DISTINCT  "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users')
),

-- 2. 用户注册时间标签与映射
UserProfileDetail AS (
    SELECT 
        "#varchar_id" AS lcx_id, 
        MAX(CASE WHEN cluster_name = 'fixed_regdate' THEN tag_value END) AS fixed_regdate
    FROM user_result_cluster_23
    WHERE cluster_name IN ('fixed_regdate')
    GROUP BY "#varchar_id"
),

-- 3. 引入本期(date1)和对比期(date2)的时间维度
DimPeriod AS (
    SELECT DISTINCT
        '本期' AS period,
        "$part_date"
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
    
    UNION ALL
    
    SELECT DISTINCT
        '对比期' AS period,
        "$part_date"
    FROM ta.v_event_23
    WHERE ${PartDate:date2}
),

-- 4. 基于 fixed_regdate 固化注册日期圈定用户群
CohortUsers AS (
    SELECT 
        u.lcx_id, 
        p.period
    FROM UserProfileDetail u
    LEFT JOIN UserBlacklist bl ON u.lcx_id = bl.lcx_id
    INNER JOIN (
        SELECT period, MIN("$part_date") AS scan_start, MAX("$part_date") AS scan_end
        FROM DimPeriod
        GROUP BY 1
    ) p ON CAST(u.fixed_regdate AS DATE) BETWEEN CAST(p.scan_start AS DATE) AND CAST(p.scan_end AS DATE)
    WHERE bl.lcx_id IS NULL
),

-- 5. 提取引导相关事件日志
RoleGuideLogs AS (
    SELECT 
        s1.guide_id,
        s1."$part_event",
        s2.lcx_id,
        s2.period 
    FROM ta.v_event_23 s1
    INNER JOIN CohortUsers s2 
        ON COALESCE(s1.sdkcommon.lcx_id, s1.fc_sdk_common.lcx_id, CAST(s1."#account_id" AS VARCHAR)) = s2.lcx_id
    WHERE s1."$part_event" IN ('NUU','role_guide_before','role_guide','force_guide')
      AND s1."$part_date" >= (SELECT MIN("$part_date") FROM DimPeriod)
),

-- 6. 用户基准总数 (基于固化注册标签)
BaseUsers AS (
    SELECT 
        period, 
        COUNT(DISTINCT lcx_id) AS new_users
    FROM CohortUsers
    GROUP BY 1
),

-- 7. 各引导步骤去重人数计算
FunnelSteps AS (
    -- 步骤 2 往后的行为（从行为事件日志中统计）
    SELECT 
        s1.period,
        CASE 
            WHEN s1.guide_id = 2      THEN 2
            WHEN s1.guide_id = 3      THEN 3
            WHEN s1.guide_id = 4      THEN 4
            WHEN s1.guide_id = 5      THEN 5
            WHEN s1.guide_id = 6      THEN 6
            WHEN s1.guide_id IN (100001,200001,300001) THEN 7
            WHEN s1.guide_id IN (100011,200011,300011) THEN 8
            WHEN s1.guide_id IN (100021,200021,300021) THEN 9
            WHEN s1.guide_id IN (100031,200031,300031) THEN 10
            WHEN s1.guide_id IN (100041,200041,300041) THEN 11
            WHEN s1.guide_id IN (100051,200051,300051) THEN 12
            WHEN s1.guide_id = 7      THEN 13
            WHEN s1.guide_id = 8      THEN 14
            WHEN s1.guide_id = 9      THEN 15
            WHEN s1.guide_id = 10     THEN 16
            WHEN s1.guide_id = 11     THEN 17
            WHEN s1.guide_id = 12     THEN 18
            WHEN s1.guide_id = 13     THEN 19
            WHEN s1.guide_id = 14     THEN 20
            WHEN s1.guide_id = 15     THEN 21
            WHEN s1.guide_id = 16     THEN 22
            WHEN s1.guide_id = 150    THEN 23
            WHEN s1.guide_id = 151    THEN 24
            WHEN s1.guide_id = 152    THEN 25
            WHEN s1.guide_id = 200    THEN 26
            WHEN s1.guide_id = 201    THEN 27
            WHEN s1.guide_id = 202    THEN 28
            WHEN s1.guide_id = 203    THEN 29
            WHEN s1.guide_id = 204    THEN 30
            WHEN s1.guide_id = 205    THEN 31
            WHEN s1.guide_id = 206    THEN 32
            WHEN s1.guide_id = 301    THEN 33
            WHEN s1.guide_id = 302    THEN 34
            WHEN s1.guide_id = 303    THEN 35
            WHEN s1.guide_id = 304    THEN 36
            WHEN s1.guide_id = 305    THEN 37
            WHEN s1.guide_id = 500    THEN 38
            WHEN s1.guide_id = 501    THEN 39
            WHEN s1.guide_id = 502    THEN 40
            WHEN s1.guide_id = 503    THEN 41
            WHEN s1.guide_id = 504    THEN 42
            WHEN s1.guide_id = 505    THEN 43
            WHEN s1.guide_id = 506    THEN 44
            WHEN s1.guide_id = 507    THEN 45
            WHEN s1.guide_id = 508    THEN 46
            WHEN s1.guide_id = 509    THEN 47
            WHEN s1.guide_id = 1100   THEN 48
            WHEN s1.guide_id = 1200   THEN 49
            WHEN s1.guide_id = 1201   THEN 50
            WHEN s1.guide_id = 1202   THEN 51
            WHEN s1.guide_id = 1203   THEN 52
            WHEN s1.guide_id = 1204   THEN 53
            WHEN s1.guide_id = 1205   THEN 54
            WHEN s1.guide_id = 1206   THEN 55
            WHEN s1.guide_id = 1027   THEN 56
            WHEN s1.guide_id = 600    THEN 57
            WHEN s1.guide_id = 601    THEN 58
            WHEN s1.guide_id = 602    THEN 59
            WHEN s1.guide_id = 603    THEN 60
            WHEN s1.guide_id = 604    THEN 61
            WHEN s1.guide_id = 605    THEN 62
            WHEN s1.guide_id = 606    THEN 63
            WHEN s1.guide_id = 607    THEN 64
            WHEN s1.guide_id = 608    THEN 65
            WHEN s1.guide_id = 609    THEN 66
            WHEN s1.guide_id = 700    THEN 67
            WHEN s1.guide_id = 701    THEN 68
            WHEN s1.guide_id = 702    THEN 69
            WHEN s1.guide_id = 703    THEN 70
            WHEN s1.guide_id = 704    THEN 71
            WHEN s1.guide_id = 705    THEN 72
            WHEN s1.guide_id = 706    THEN 73
            WHEN s1.guide_id = 707    THEN 74
            WHEN s1.guide_id = 708    THEN 75
            WHEN s1.guide_id = 900    THEN 76
            WHEN s1.guide_id = 901    THEN 77
            WHEN s1.guide_id = 902    THEN 78
            WHEN s1.guide_id = 903    THEN 79
            WHEN s1.guide_id = 904    THEN 80
            WHEN s1.guide_id = 905    THEN 81
            WHEN s1.guide_id = 906    THEN 82
            WHEN s1.guide_id = 907    THEN 83
            WHEN s1.guide_id = 908    THEN 84
            WHEN s1.guide_id = 909    THEN 85
            WHEN s1.guide_id = 1001   THEN 86
            WHEN s1.guide_id = 1002   THEN 87
            WHEN s1.guide_id = 1003   THEN 88
            WHEN s1.guide_id = 1004   THEN 89
            WHEN s1.guide_id = 1005   THEN 90
            WHEN s1.guide_id = 1006   THEN 91
            WHEN s1.guide_id = 1007   THEN 92
            WHEN s1.guide_id = 1008   THEN 93
            WHEN s1.guide_id = 1009   THEN 94
            WHEN s1.guide_id = 1010   THEN 95
            WHEN s1.guide_id = 1011   THEN 96
            WHEN s1.guide_id = 1012   THEN 97
            WHEN s1.guide_id = 1101   THEN 98
            WHEN s1.guide_id = 1102   THEN 99
            WHEN s1.guide_id = 1103   THEN 100
            WHEN s1.guide_id = 1301   THEN 101
            WHEN s1.guide_id = 1302   THEN 102
            WHEN s1.guide_id = 1303   THEN 103
            WHEN s1.guide_id = 1304   THEN 104
            WHEN s1.guide_id = 1305   THEN 105
            WHEN s1.guide_id = 1306   THEN 106
            WHEN s1.guide_id = 1307   THEN 107
            WHEN s1.guide_id = 1308   THEN 108
            WHEN s1.guide_id = 1309   THEN 109
            WHEN s1.guide_id = 1310   THEN 110
        END AS sort_id,
        CASE 
            WHEN s1.guide_id = 2      THEN '问卷完成'
            WHEN s1.guide_id = 3      THEN '选择英雄加载完成'
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
            WHEN s1.guide_id = 10     THEN '引导战斗开始'
            WHEN s1.guide_id = 11     THEN '引导战斗开始1分钟'
            WHEN s1.guide_id = 12     THEN '引导战斗开始2分钟'
            WHEN s1.guide_id = 13     THEN '引导流程完成'
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
            WHEN s1.guide_id = 301    THEN '点击【排位赛】入口'
            WHEN s1.guide_id = 302    THEN '点击【单人排位】按钮'
            WHEN s1.guide_id = 303    THEN '选择第一个英雄'
            WHEN s1.guide_id = 304    THEN '点击【确定】按钮'
            WHEN s1.guide_id = 305    THEN '战斗结束'
            WHEN s1.guide_id = 500    THEN '点击【荣誉之路】图标'
            WHEN s1.guide_id = 501    THEN '点击领取第二个奖励（阅览券）'
            WHEN s1.guide_id = 502    THEN '点击【总奖杯奖励】，返回主界面'
            WHEN s1.guide_id = 503    THEN '点击【刊物】，进入刊物中心'
            WHEN s1.guide_id = 504    THEN '点击【兑换十次】，进行抽奖'
            WHEN s1.guide_id = 505    THEN '点击【刊物中心】，返回'
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
        END AS "引导步骤",
        COUNT(DISTINCT lcx_id) funnel_counts
    FROM RoleGuideLogs s1 
    GROUP BY 1, 2, 3

    UNION ALL

    -- 步骤 1 (注册)：直接从 CohortUsers 统计（不受没有 NUU 事件的影响）
    SELECT 
        period,
        1 AS sort_id,
        '注册' AS "引导步骤",
        COUNT(DISTINCT lcx_id) AS funnel_counts
    FROM CohortUsers
    GROUP BY 1
)

--------------------------------------------------------------------------------
-- 8. 最终输出并计算转化率
--------------------------------------------------------------------------------
SELECT 
    p1.period,
    p1.sort_id AS "步骤ID",
    p1."引导步骤",
    p1.funnel_counts * 1.0 / NULLIF(CAST(p2.new_users AS DOUBLE), 0) AS "值"
FROM FunnelSteps p1
LEFT JOIN BaseUsers p2 ON p1.period = p2.period
WHERE p1."引导步骤" IS NOT NULL
AND sort_id <= 47
AND sort_id NOT IN (2,49,50,51,52,53,54,57,58,59,60,67,68,69,70,76,77,78,79,86,87,88,89)
ORDER BY p1.period, p1.sort_id;
