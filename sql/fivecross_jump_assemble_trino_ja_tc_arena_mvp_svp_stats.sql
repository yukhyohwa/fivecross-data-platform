WITH 
RawFightLogs AS (
    SELECT 
        CASE 
            WHEN 1=0  THEN '全部模式'
            ELSE 
                CASE 
                    WHEN model_type = 1 THEN '休闲赛'
                    WHEN model_type = 2 THEN '排位赛'
                    WHEN model_type = 3 THEN '自定义'
                    WHEN model_type = 5 THEN '漫斗赛'
                    ELSE '其他' 
                END
        END AS model_type,
        
        CASE 
            WHEN 1=0  THEN '全部玩法'
            ELSE 
                CASE 
                    WHEN game_type = 1 THEN '卷轴争夺'
                    WHEN game_type = 2 THEN '单人乱斗'
                    WHEN game_type = 3 THEN '双人乱斗'
                    WHEN game_type = 4 THEN '武道会'
                    WHEN game_type = 5 THEN '积分争夺'
                    WHEN game_type = 7 THEN '咒术高专'
                    WHEN game_type = 9 THEN '顶上战争'
                    WHEN game_type = 10 THEN '无限列车'
                    WHEN game_type = 11 THEN '淘汰赛'
                    WHEN game_type = 12 THEN '忍界大战'
                    WHEN game_type = 15 THEN '龙珠之争'
                    WHEN game_type = 16 THEN '爆破对决'
                    ELSE '其他'
                END
        END AS game_type,
        CAST(player_ladder_level AS INTEGER) AS player_ladder_level,
        battle_id, 
        "#account_id",
        robot_num,
        t.h_id AS hero_id,
        mvp,
        
        -- 判断胜负，用于后续计算败方最高分 (SVP)
        CASE 
            WHEN (game_type IN (1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16) AND rank = 1)
              OR (game_type = 2 AND rank <= 4)
              OR (game_type = 3 AND rank <= 2)
            THEN 1 ELSE 0 
        END AS is_win,
        
        CAST(score AS DOUBLE) / 1000.0 AS score, 
        COALESCE(cost_time,0)+COALESCE(hook_time,0) AS "time/s",
        
        CAST(t.dmg AS DOUBLE) AS b_damage,
        CAST(t.kl AS DOUBLE)  AS b_kill,
        CAST(t.dd AS DOUBLE)  AS b_death,
        CAST(t.an AS DOUBLE)  AS b_assist,
        CAST(t.tk AS DOUBLE)  AS b_takedamage,
        CAST(t.cu AS DOUBLE)  AS b_cure
        
    FROM ta.v_event_23
    -- 加回 cure 解包
    CROSS JOIN UNNEST(
        hero_id_list, damage, kill_num, dead_num, assist_num, takedamage, cure
    ) AS t(h_id, dmg, kl, dd, an, tk, cu)
    WHERE ${PartDate:date1} 
      AND "$part_event" = 'arena_fight'
      AND model_type IN (1,2,3,5)
      AND game_type IN (1,2,3,4,5,7,9,10,11,12,13,14,15,16)
      AND TRY_CAST(robot_num AS INTEGER) = 0
),

RankedFightLogs AS (
    SELECT 
        *,
        -- 对每一局的败方（is_win = 0）按评分倒序排名，第1名即为 SVP
        ROW_NUMBER() OVER (PARTITION BY battle_id, is_win ORDER BY score DESC) AS team_score_rank
    FROM RawFightLogs
),

FinalLogs AS (
    SELECT 
        *,
        CASE 
            WHEN mvp = true THEN 'MVP'
            WHEN is_win = 0 AND team_score_rank = 1 AND score > 0 THEN 'SVP'
            ELSE '未知'
        END AS honor_type
    FROM RankedFightLogs
)

SELECT 
    player_ladder_level AS "段位",
    model_type AS "模式",
    game_type AS "玩法",
    CAST(battle_id AS VARCHAR)||'a' AS "场次ID",
    hero_id AS "英雄ID",
    "hero_id_list@card_name" AS "英雄名称",
    CAST("#account_id" AS VARCHAR) AS "#account_id",
    honor_type AS "荣誉类型",
    ROUND(score, 2) AS "评分",
    b_damage AS "伤害数",
    b_kill AS "击杀数",
    b_death AS "死亡数",
    b_assist AS "助攻数",
    b_takedamage AS "承伤数",
    b_cure AS "治疗数",
    robot_num,
    "time/s" 
FROM FinalLogs fl
LEFT JOIN ta_dim.dim_16_0_24863 dim_cn 
  ON CAST(fl.hero_id AS INTEGER) = CAST(dim_cn."hero_id_list@card_id" AS INTEGER)
-- 只要 MVP 和 我们算出来的 SVP
WHERE honor_type IN ('MVP', 'SVP')
ORDER BY player_ladder_level DESC, score DESC;
