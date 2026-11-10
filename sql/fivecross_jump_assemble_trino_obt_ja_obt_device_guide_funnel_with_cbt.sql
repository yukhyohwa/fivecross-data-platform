/*
================================================================================
Game    : Jump Assemble (众星之聚 / 跳跃集结)
Region  : TC (Traditional Chinese)
Report  : 新手引导漏斗 - OBT (含分系统标签) 与 CBT 历史对比 (设备维度 - 去水)
Description:
    统计 OBT 与 CBT1/CBT2 历史测试在各新手引导步骤的完成设备数及转化率。
    以 fixed_deviceid 作为统计去重标准。
    
    1. OBT 数据：
       - 数据表：ta.v_event_23, user_result_cluster_23
       - 维度划分：
         - OBT：$part_date 满足 ${PartDate:date1}
       - 黑名单：internal_users, is_water

    2. CBT 数据：
       - 数据表：ta.v_event_16, user_result_cluster_16
       - 维度划分：
         - CBT1：Android + 2025-11-25 注册新设备 (分区 $part_date = '2025-11-25')
         - CBT2：iOS + 2026-04-15 注册新设备 (分区 $part_date = '2026-04-15')
       - 黑名单：internal_users, is_water

    3. 引导步骤对齐：
       - OBT 引导流程完成于 guide_id = 13
       - CBT 引导流程完成于 guide_id = 16
       - 对齐逻辑：通过 period 判断，OBT 的 guide_id = 13 映射为 '引导流程完成'；
         CBT 的 guide_id = 16 映射为 '引导流程完成' (CBT 的 guide_id = 13 映射为 '引导战斗完成')。

Environment: Trino (TA)
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 黑名单定义 (排除测试号与水军号，去水)
--------------------------------------------------------------------------------
DeviceBlacklist_16 AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_16
    WHERE cluster_name IN ('internal_users', 'is_water')
),

DeviceBlacklist_23 AS (
    SELECT DISTINCT "#varchar_id" AS lcx_id
    FROM user_result_cluster_23
    WHERE cluster_name IN ('internal_users', 'is_water')
),

--------------------------------------------------------------------------------
-- 2. 用户分系统标签与设备映射定义 (UserProfileDetail)
--------------------------------------------------------------------------------
UserProfileDetail_16 AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os'       THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid
    FROM user_result_cluster_16
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate', 'fixed_deviceid')
    GROUP BY "#varchar_id"
),

UserProfileDetail_23 AS (
    SELECT 
        "#varchar_id" AS "#account_id", 
        MAX(CASE WHEN cluster_name = 'fixed_os'       THEN tag_value END) AS fixed_os,
        MAX(CASE WHEN cluster_name = 'fixed_regdate'  THEN tag_value END) AS fixed_regdate,
        MAX(CASE WHEN cluster_name = 'fixed_deviceid' THEN tag_value END) AS fixed_deviceid
    FROM user_result_cluster_23 
    WHERE cluster_name IN ('fixed_os', 'fixed_regdate', 'fixed_deviceid')
    GROUP BY "#varchar_id"
),

-- 映射设备最早注册时间与系统
DeviceProfile_16 AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), CONCAT('unknown_', "#account_id")) AS device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type
    FROM UserProfileDetail_16
    GROUP BY 1
),

DeviceProfile_23 AS (
    SELECT 
        COALESCE(NULLIF(fixed_deviceid, ''), CONCAT('unknown_', "#account_id")) AS device_id,
        MIN(fixed_regdate) AS reg_date,
        MAX(fixed_os) AS os_type
    FROM UserProfileDetail_23
    GROUP BY 1
),

-- 关联排除黑名单设备
DeviceBlacklistFilter_16 AS (
    SELECT DISTINCT COALESCE(NULLIF(s.fixed_deviceid, ''), CONCAT('unknown_', s."#account_id")) AS device_id
    FROM DeviceBlacklist_16 b
    INNER JOIN UserProfileDetail_16 s ON b.lcx_id = s."#account_id"
),

DeviceBlacklistFilter_23 AS (
    SELECT DISTINCT COALESCE(NULLIF(s.fixed_deviceid, ''), CONCAT('unknown_', s."#account_id")) AS device_id
    FROM DeviceBlacklist_23 b
    INNER JOIN UserProfileDetail_23 s ON b.lcx_id = s."#account_id"
),

DimPeriod AS (
    SELECT DISTINCT
        'OBT' AS period,
        "$part_date"
    FROM ta.v_event_23
    WHERE ${PartDate:date1}
),

--------------------------------------------------------------------------------
-- 4. 圈定目标 Cohort 设备集 (基于 fixed_regdate 固化注册日期)
--------------------------------------------------------------------------------
CohortDevices AS (
    -- OBT 注册新设备
    SELECT 
        d.device_id, 
        'OBT' AS period,
        d.os_type AS fixed_os
    FROM DeviceProfile_23 d
    LEFT JOIN DeviceBlacklistFilter_23 bl ON d.device_id = bl.device_id
    CROSS JOIN (
        SELECT MIN("$part_date") AS scan_start, MAX("$part_date") AS scan_end
        FROM DimPeriod
    ) p
    WHERE bl.device_id IS NULL
      AND CAST(d.reg_date AS DATE) BETWEEN CAST(p.scan_start AS DATE) AND CAST(p.scan_end AS DATE)

    UNION ALL

    -- CBT1：Android + 2025-11-25 注册新设备
    SELECT 
        d.device_id, 
        'CBT1' AS period,
        d.os_type AS fixed_os
    FROM DeviceProfile_16 d
    LEFT JOIN DeviceBlacklistFilter_16 bl ON d.device_id = bl.device_id
    WHERE bl.device_id IS NULL
      AND d.reg_date = '2025-11-25'
      AND d.os_type = 'Android'

    UNION ALL

    -- CBT2：iOS + 2026-04-15 注册新设备
    SELECT 
        d.device_id, 
        'CBT2' AS period,
        d.os_type AS fixed_os
    FROM DeviceProfile_16 d
    LEFT JOIN DeviceBlacklistFilter_16 bl ON d.device_id = bl.device_id
    WHERE bl.device_id IS NULL
      AND d.reg_date = '2026-04-15'
      AND d.os_type = 'iOS'
),

--------------------------------------------------------------------------------
-- 5. 提取引导相关事件日志并合并 (关联至设备 ID)
--------------------------------------------------------------------------------
RoleGuideLogs AS (
    -- OBT 引导事件日志
    SELECT 
        s1.guide_id,
        s1."$part_event",
        s2.device_id,
        s2.period,
        s2.fixed_os
    FROM ta.v_event_23 s1
    LEFT JOIN UserProfileDetail_23 s4 
        ON COALESCE(s1.sdkcommon.lcx_id, s1.fc_sdk_common.lcx_id, CAST(s1."#account_id" AS VARCHAR)) = s4."#account_id"
    INNER JOIN CohortDevices s2 
        ON COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) = s2.device_id AND s2.period = 'OBT'
    WHERE s1."$part_event" IN ('NUU','role_guide_before','role_guide','force_guide')
      AND s1."$part_date" >= (SELECT MIN("$part_date") FROM DimPeriod)

    UNION ALL

    -- CBT 引导事件日志
    SELECT 
        s1.guide_id,
        s1."$part_event",
        s2.device_id,
        s2.period,
        s2.fixed_os
    FROM ta.v_event_16 s1
    LEFT JOIN UserProfileDetail_16 s4 
        ON COALESCE(s1.lcxsdkcommon.lcx_id, s1.sdkcommon.lcx_id, s1.lcx_id, json_extract_scalar(s1.fc_sdk_common, '$.lcx_id'), CAST(s1."#account_id" AS VARCHAR)) = s4."#account_id"
    INNER JOIN CohortDevices s2 
        ON COALESCE(NULLIF(s4.fixed_deviceid, ''), CONCAT('unknown_', s4."#account_id")) = s2.device_id AND s2.period IN ('CBT1', 'CBT2')
    WHERE s1."$part_event" IN ('NUU','role_guide_before','role_guide','force_guide')
      AND (
          (s2.period = 'CBT1' AND s1."$part_date" BETWEEN '2025-11-25' AND '2025-12-02')
          OR
          (s2.period = 'CBT2' AND s1."$part_date" BETWEEN '2026-04-15' AND '2026-04-23')
      )
),

--------------------------------------------------------------------------------
-- 6. 设备基准总数 (基于固化注册标签的基准设备分母)
--------------------------------------------------------------------------------
BaseDevices AS (
    SELECT 
        period, 
        fixed_os, 
        COUNT(DISTINCT device_id) AS new_device
    FROM CohortDevices
    GROUP BY 1, 2
),

--------------------------------------------------------------------------------
-- 7. 各引导步骤去重设备数计算
--------------------------------------------------------------------------------
FunnelSteps AS (
    -- 步骤 2 往后的行为（从行为事件日志中统计）
    SELECT 
        s1.period,
        s1.fixed_os,
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
        COUNT(DISTINCT device_id) funnel_counts
    FROM RoleGuideLogs s1 
    GROUP BY 1, 2, 3, 4

    UNION ALL

    -- 步骤 1 (注册)：直接从 CohortDevices 统计（不受没有 NUU 事件的影响）
    SELECT 
        period,
        fixed_os,
        1 AS sort_id,
        '注册' AS "引导步骤",
        COUNT(DISTINCT device_id) AS funnel_counts
    FROM CohortDevices
    GROUP BY 1, 2
)

--------------------------------------------------------------------------------
-- 8. 最终输出并计算转化率
--------------------------------------------------------------------------------
SELECT 
    p1.period,
    p1.fixed_os,
    p1.sort_id AS "步骤ID",
    p1."引导步骤",
    p1.funnel_counts AS "触发设备数",
    p2.new_device AS "注册设备数",
    p1.funnel_counts * 1.0 / NULLIF(CAST(p2.new_device AS DOUBLE), 0) AS "转化率"
FROM FunnelSteps p1
LEFT JOIN BaseDevices p2 ON p1.period = p2.period
    AND p1.fixed_os IS NOT DISTINCT FROM p2.fixed_os
WHERE p1."引导步骤" IS NOT NULL
AND sort_id <= 47
AND sort_id NOT IN (2,49,50,51,52,53,54,57,58,59,60,67,68,69,70,76,77,78,79,86,87,88,89)
AND p1.fixed_os IN ('Android','iOS')
ORDER BY p1.period, p1.sort_id;
