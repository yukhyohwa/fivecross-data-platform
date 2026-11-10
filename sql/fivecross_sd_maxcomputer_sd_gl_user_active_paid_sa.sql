-- 南美区域活跃或付费用户查询 SQL
-- 目标：筛选特定区域（zone开头为3）、近两年有过登录或历史有过充值的用户GID
-- 近两年定义：最后登录时间在20240120之后（当前时间2026-01-20往前推2年）

WITH LastLogin AS (
    SELECT 
        mbga_uid,
        user_id,
        MAX(last_login) AS last_login_ts
    FROM 
        g63002013.daily_user_snapshot
    WHERE 
        SUBSTR(zone, 1, 1) = '3' -- 取zone第一位为3的南美区域
        AND day >= 0
    GROUP BY 
        mbga_uid, user_id
),
-- 近两年有登录的用户
RecentLoginUsers AS (
    SELECT DISTINCT
        mbga_uid,
        user_id AS role_id
    FROM 
        LastLogin
    WHERE 
        -- 将时间戳转换为yyyyMMdd格式,筛选20240120之后的登录
        TO_CHAR(FROM_UNIXTIME(CAST(last_login_ts AS BIGINT)), 'yyyyMMdd') > '20240120'
),

-- 历史有过充值的用户（通过 LastLogin 关联获取 user_id）
PaidUsers AS (
    SELECT DISTINCT 
        l.mbga_uid,
        l.user_id AS role_id
    FROM 
        dm_platform.daily_lcx_user_info p
    INNER JOIN
        LastLogin l 
        ON p.lcm_id = l.mbga_uid
    WHERE 
        p.day >= 0
        AND p.app_id = 63002013
        AND p.purchase > 0
)

-- 合并两类用户：近两年登录 OR 历史充值
SELECT DISTINCT
    role_id
FROM 
    RecentLoginUsers
UNION
SELECT DISTINCT
    role_id
FROM 
    PaidUsers;
