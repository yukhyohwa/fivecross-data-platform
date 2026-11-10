/*
================================================================================
Game: Slam Dunk (TC: g23002013 / GL: g63002013 / KR: g33002013)
Description: 提取三个灌篮 (台湾、全球、韩国) 的 palace_skill 事件数据
Environment: Aliyun MaxCompute (ODPS)
================================================================================
*/

SELECT 
    'TC' AS area, 
    log_t AS event_time,
    mbga_uid AS account_id,
    user_id AS role_id,
    a_typ AS part_event,
    GET_JSON_OBJECT(a_tar, '$.skill_id') AS skill_id,
    GET_JSON_OBJECT(a_tar, '$.type') AS type,
    GET_JSON_OBJECT(a_tar, '$.level') AS level,
    a_rst
FROM g23002013.daily_game_log
WHERE day BETWEEN 20260423 AND 20260608
  AND log_t <= '2026-06-08 23:59:59'
  AND a_typ = 'palace_skill'

UNION ALL

SELECT 
    'GL' AS area, 
    log_t AS event_time,
    mbga_uid AS account_id,
    user_id AS role_id,
    a_typ AS part_event,
    GET_JSON_OBJECT(a_tar, '$.skill_id') AS skill_id,
    GET_JSON_OBJECT(a_tar, '$.type') AS type,
    GET_JSON_OBJECT(a_tar, '$.level') AS level,
    a_rst
FROM g63002013.daily_game_log
WHERE day BETWEEN 20260423 AND 20260608
  AND log_t <= '2026-06-08 23:59:59'
  AND a_typ = 'palace_skill'

UNION ALL

SELECT 
    'KR' AS area, 
    log_t AS event_time,
    mbga_uid AS account_id,
    user_id AS role_id,
    a_typ AS part_event,
    GET_JSON_OBJECT(a_tar, '$.skill_id') AS skill_id,
    GET_JSON_OBJECT(a_tar, '$.type') AS type,
    GET_JSON_OBJECT(a_tar, '$.level') AS level,
    a_rst
FROM g33002013.daily_game_log
WHERE day BETWEEN 20260423 AND 20260608
  AND log_t <= '2026-06-08 23:59:59'
  AND a_typ = 'palace_skill';
