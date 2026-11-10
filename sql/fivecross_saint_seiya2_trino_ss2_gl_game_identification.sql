/*
================================================================================
Game: Saint Seiya 2 (GL - TC & SEA)
Description: Unified game identification logic for Trino events (v_event_17).
             Maps different event attributes (applicationid, productid, 
             lcxproductid) to a single game_id and game_name based on 
             part_event type.
Environment: Trino
Tables: 
  - ta.v_event_19
================================================================================
*/

SELECT DISTINCT 
CASE 
WHEN 
   applicationid IN ('23000113','seiya30tw') 
OR productid IN ('23000113','seiya30tw') 
OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('23000113')
OR substring(affcode, -8) IN ('23000113') 
OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('23000113','seiya30tw')
THEN 'Saint Seiya (TC)' 
WHEN 
   applicationid IN ('60000001') 
OR productid IN ('60000001') 
OR regexp_extract(lcxproductid, 'g(\d+)', 1) IN ('60000001')
OR substring(affcode, -8) IN ('60000001') 
OR regexp_extract(payload.productid, 'g(\d+)', 1) IN ('60000001')
THEN 'Saint Seiya (SEA)' 
ELSE 'UNKNOWN' END AS game_name,
"$part_event",
applicationid,
productid,
regexp_extract(payload.productid, 'g(\d+)', 1) fixed_payloadproductid,
regexp_extract(lcxproductid, 'g(\d+)', 1) fixed_lcxproductid,
substring(affcode, -8) fixed_affcode
FROM ta.v_event_19
WHERE ${PartDate:date1}

/*
|game_name | $part_event | applicationid | productid | fixed_payloadproductid | fixed_lcxproductid | fixed_affcode
|---|---|---|---|---|---|---
|Saint Seiya (TC) | PURCHASE | seiya30tw | (null) | 23000113 | (null) | 23000113
|Saint Seiya (SEA) | PURCHASE | 60000001 | (null) | 60000001 | (null) | 60000001
|Saint Seiya (TC) | NUU | seiya30tw | (null) | (null) | (null) | 23000113
|Saint Seiya (SEA) | NUU | 60000001 | (null) | (null) | (null) | 60000001
|Saint Seiya (TC) | LOGIN_SUCCESS | (null) | seiya30tw | (null) | (null) | 23000113
|Saint Seiya (SEA) | LOGIN_SUCCESS | (null) | 60000001 | (null) | (null) | 60000001
|Saint Seiya (TC) | LCX_WALLET_SPEND_TRANSACTION | (null) | (null) | (null) | 23000113 | (null)
|Saint Seiya (SEA) | LCX_WALLET_SPEND_TRANSACTION | (null) | (null) | (null) | 60000001 | (null)
*/