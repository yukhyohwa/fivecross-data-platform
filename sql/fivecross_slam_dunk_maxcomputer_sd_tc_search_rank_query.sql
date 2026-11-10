-- ***************************************************************
-- 提取 2026-02-05 灌篮高手 TC 服 "超凡灌篮高手" 段位玩家 (Top 500)
-- 目的: 验证结算奖励发放名单
-- ***************************************************************

SELECT /*+ MAPJOIN(d) */ -- 强制将维表加载到内存，优化笛卡尔积性能
    s.mbga_uid AS lcx_id,
    s.user_id AS gid,
    s.nickname,
    s.level,
    s.match_rank
FROM (
    SELECT 
        mbga_uid, 
        user_id, 
        nickname, 
        level, 
        match_rank,
        '1' as fj
    FROM g23002013.daily_user_snapshot 
    WHERE day = '20260205' -- 既然是查今天(5号)的数据，直接指定分区效率最高
) s
INNER JOIN ( -- 用 INNER JOIN 过滤效果更明确
    SELECT 
        DISTINCT min_star, 
        '1' as fj
    FROM g23002013.dim_rank 
    WHERE rank_detail = '超凡灌篮高手'
) d 
ON s.fj = d.fj
WHERE s.match_rank >= d.min_star 
-- "超凡灌篮高手" 逻辑：在达到基础星数后，取服务器全量排序的前 500 名
ORDER BY s.match_rank DESC
LIMIT 500;