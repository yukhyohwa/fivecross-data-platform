WITH 
MvpFightLogs AS (
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
        'MVP' AS honor_type,
        
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
    WHERE "$part_date" BETWEEN '2026-07-10' AND '2026-08-03' 
      AND "$part_event" = 'arena_fight'
      AND model_type = 2 -- 只要排位赛
      AND game_type IN (1,2,3,4,5,7,9,10,11,12,13,14,15,16)
      AND mvp = true
      -- 包含机器人的场次（已移除 TRY_CAST(robot_num AS INTEGER) = 0 条件）
),

CustomsPass AS (
    -- 从 client_customs_pass 提取 BOn（是否BO3）、bon_round（当前回合数），按 battle_id 去重
    SELECT 
        battle_id,
        MAX(bon) AS bon,
        MAX(TRY_CAST(bon_round AS INTEGER)) AS bon_round
    FROM ta.v_event_23
    WHERE "$part_date" BETWEEN '2026-07-10' AND '2026-08-03' 
      AND "$part_event" = 'client_customs_pass'
      AND model_type = 2
      AND game_type IN (1,2,3,4,5,7,9,10,11,12,13,14,15,16)
    GROUP BY battle_id
)

SELECT 
    fl.player_ladder_level AS "段位",
    fl.model_type AS "模式",
    fl.game_type AS "玩法",
    CAST(fl.battle_id AS VARCHAR)||'a' AS "场次ID",
    cp.bon AS bon,
    cp.bon_round AS bon_round,
    fl.hero_id AS "英雄ID",
    dim_cn."hero_id_list@card_name" AS "英雄名称",
    CAST(fl."#account_id" AS VARCHAR) AS "#account_id",
    fl.honor_type AS "荣誉类型",
    ROUND(fl.score, 2) AS "评分",
    fl.b_damage AS "伤害数",
    fl.b_kill AS "击杀数",
    fl.b_death AS "死亡数",
    fl.b_assist AS "助攻数",
    fl.b_takedamage AS "承伤数",
    fl.b_cure AS "治疗数",
    fl.robot_num,
    fl."time/s" 
FROM MvpFightLogs fl
LEFT JOIN CustomsPass cp 
  ON fl.battle_id = cp.battle_id
LEFT JOIN ta_dim.dim_16_0_24863 dim_cn 
  ON CAST(fl.hero_id AS INTEGER) = CAST(dim_cn."hero_id_list@card_id" AS INTEGER)
ORDER BY fl.player_ladder_level DESC, fl.score DESC;
