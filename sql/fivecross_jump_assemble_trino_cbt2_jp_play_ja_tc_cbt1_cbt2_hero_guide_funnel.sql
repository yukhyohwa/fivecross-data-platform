/*
================================================================================
Game   : Jump Assemble (跳跃集结)
Region : TC (繁體中文)
Description:
    新手引导英雄选择漏斗对比
    - CBT1：2025-11-25 ~ 2025-12-02，用户标识 = "#user_id"
    - CBT2：2026-04-15 ~ 2026-04-23，用户标识 = "#user_id"
    两个时段均使用 "#user_id"，不做注册日过滤，直接取时间窗口内有引导事件的用户

    漏斗逻辑：
      guide_id = 4  → 英雄选择节点（HeroChose，记录 hero_id）
      guide_id = 13 → 后续关键节点
    英雄 ID 说明：
      148 = 漩涡鸣人（小）
      142 = 孙悟空（新）
      143 = 路飞
================================================================================
*/

WITH

--------------------------------------------------------------------------------
-- 1. 两个时段的目标用户集（直接取时间窗口内有引导事件的用户，不过滤注册日）
--    CBT1 / CBT2 均使用 "#user_id"
--------------------------------------------------------------------------------
TargetUsers AS (
    -- CBT1
    SELECT DISTINCT
        CAST("#user_id" AS VARCHAR)   AS user_id,
        'CBT1'          AS period
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2025-11-25' AND '2025-12-02'
      AND "$part_event" IN ('role_guide_before', 'role_guide', 'force_guide')
      AND "#user_id" IS NOT NULL

    UNION ALL

    -- CBT2
    SELECT DISTINCT
        CAST("#user_id" AS VARCHAR)  AS user_id,
        'CBT2'                       AS period
    FROM ta.v_event_16
    WHERE "$part_date" BETWEEN '2026-04-15' AND '2026-04-23'
      AND "$part_event" IN ('role_guide_before', 'role_guide', 'force_guide')
      AND "#user_id" IS NOT NULL
),

--------------------------------------------------------------------------------
-- 2. 英雄选择节点（guide_id = 4），记录每个用户选择的 hero_id
--------------------------------------------------------------------------------
HeroChose AS (
    SELECT
        s2.user_id,
        s2.period,
        s1.hero_id
    FROM ta.v_event_16 s1
    INNER JOIN TargetUsers s2
        ON CAST(s1."#user_id" AS VARCHAR) = s2.user_id
    WHERE s1."$part_event" IN ('role_guide_before', 'role_guide', 'force_guide')
      AND s1.guide_id = 4
      AND s1.hero_id IN (148, 142, 143)
      AND (
          (s2.period = 'CBT1' AND s1."$part_date" BETWEEN '2025-11-25' AND '2025-12-02')
          OR
          (s2.period = 'CBT2' AND s1."$part_date" BETWEEN '2026-04-15' AND '2026-04-23')
      )
),

--------------------------------------------------------------------------------
-- 3. 后续关键节点（guide_id = 13）
--------------------------------------------------------------------------------
RoleGuideLogs AS (
    SELECT
        s2.user_id,
        s2.period
    FROM ta.v_event_16 s1
    INNER JOIN TargetUsers s2
        ON CAST(s1."#user_id" AS VARCHAR) = s2.user_id
    WHERE s1."$part_event" IN ('role_guide_before', 'role_guide', 'force_guide')
      AND s1.guide_id = 13
      AND (
          (s2.period = 'CBT1' AND s1."$part_date" BETWEEN '2025-11-25' AND '2025-12-02')
          OR
          (s2.period = 'CBT2' AND s1."$part_date" BETWEEN '2026-04-15' AND '2026-04-23')
      )
)

--------------------------------------------------------------------------------
-- 4. 最终输出：按 period + hero_id 分组，输出漏斗人数
--------------------------------------------------------------------------------
SELECT
    s2.period                                                               AS "测试阶段",
    s2.hero_id                                                              AS "英雄ID",
    CASE s2.hero_id
        WHEN 148 THEN '漩涡鸣人（小）'
        WHEN 142 THEN '孙悟空（新）'
        WHEN 143 THEN '路飞'
        ELSE CAST(s2.hero_id AS VARCHAR)
    END                                                                     AS "英雄名称",
    COUNT(DISTINCT s2.user_id)                                              AS "选择英雄人数 (guide_id=4)",
    COUNT(DISTINCT s1.user_id)                                              AS "完成后续节点人数 (guide_id=13)",
    CAST(COUNT(DISTINCT s1.user_id) AS DOUBLE)
        / NULLIF(COUNT(DISTINCT s2.user_id), 0)                             AS "漏斗转化率"
FROM HeroChose s2
LEFT JOIN RoleGuideLogs s1
    ON  s1.user_id = s2.user_id
    AND s1.period  = s2.period
GROUP BY 1, 2, 3
ORDER BY 1, 2;
