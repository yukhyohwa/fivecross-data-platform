/*
================================================================================
Game    : Jump Assemble - OBT
Report  : 英雄获得途径及拥有人数统计 (Hero Acquisition & Ownership Stats)
Description: 不含新手引导 3 选 1 (hero_choose) 的英雄获得 (hero_add) 统计
================================================================================
*/

SELECT 
    s1."hero_id" AS card_id,
    s2."hero_id_list@card_name" AS card_name,
    s1."reason" AS reason,
    COUNT(DISTINCT s1.rolecommon.role_id) AS owners
FROM ta.v_event_23 s1
LEFT JOIN ta_dim.dim_23_0_51137 s2 
    ON CAST(CAST(s1."hero_id" AS INTEGER) AS VARCHAR) = s2."hero_id_list@card_id"
WHERE ${PartDate:date1} 
  AND s1."$part_event" = 'hero_add'
GROUP BY 1, 2, 3;
