/*
================================================================================
项目：蜡笔小新 - TC 繁体 OBT 沙盒充值及福利账号黑名单
说明：
1. 沙盒充值账号：OBT 期间存在 sandbox = TRUE 的 charge。
2. 福利账号：OBT 期间任一事件的角色名以后缀名单结尾；不限定“蠟筆/蜡笔/英文”前缀。
3. 本次保留原有后缀，并新增：
   3EBD5B、3F247C、3F2DB4、3F2E16、3F3D50、3E883F。
================================================================================
*/

WITH
sandbox_charge AS (
    SELECT DISTINCT TRIM(CAST(fc_id AS VARCHAR)) AS fc_id
    FROM ta.v_event_18
    WHERE "$part_event" = 'charge'
      AND "$part_date" >= '2026-10-14'
      AND sandbox = TRUE
      AND NULLIF(TRIM(CAST(fc_id AS VARCHAR)), '') IS NOT NULL
      AND LENGTH(TRIM(CAST(fc_id AS VARCHAR))) >= 10
),

welfare_list AS (
    SELECT DISTINCT TRIM(CAST(fc_id AS VARCHAR)) AS fc_id
    FROM ta.v_event_18
    WHERE "$part_date" >= '2026-10-14'
      AND REGEXP_LIKE(
          UPPER(TRIM(CAST(role_name AS VARCHAR))),
          CONCAT(
              '(',
              '3EAEFB|3EAEE5|3EB012|3EB78D|3EB275|3EBC73|',
              '3E9476|3EE176|3E9E4C|3E9F38|3EE58C|3EE316|',
              '3EBD5D|3EAEF9|3EAEF8|3EBDA2|3EBC26|3E82EA|',
              '3E8F3B|3E8F13|3E892D|3E9118|3E86ED|3E83DB|',
              '3EBFB4|3EB055|3E8800|3EEDD3|3EE490|3EC358|',
              '3EC6CF|3EE8A7|3EDE11|3E9558|3EB15F|3E9C9F|',
              '3EC59A|3ED62C|3EAEE6|3EBD5B|3F247C|3F2DB4|',
              '3F2E16|3F3D50|3E883F',
              ')$'
          )
      )
      AND NULLIF(TRIM(CAST(fc_id AS VARCHAR)), '') IS NOT NULL
      AND LENGTH(TRIM(CAST(fc_id AS VARCHAR))) >= 10
)

SELECT fc_id FROM sandbox_charge
UNION
SELECT fc_id FROM welfare_list;
