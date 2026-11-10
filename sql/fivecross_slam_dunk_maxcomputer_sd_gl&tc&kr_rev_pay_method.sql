-- odps sql
-- ********************************************************************--
-- author:陆晓华
-- create time:2025-12-24 11:39:22
-- ********************************************************************--
WITH
  transactions AS (
    -- 筛选交易数据
    SELECT
      substr(day, 1, 6) AS months,
      game_id,
      channel_type,
      paid_amount,
      currency_code
    FROM
      dm_platform.transaction_wallet
    WHERE
      day BETWEEN 20260301 AND 20260331
      AND transaction_type IN ('CHARGE', 'DIRECT_CHARGE')
      AND game_id IN ('63002013', '23002013', '33002013')
  ),
  exchange_rates AS (
    -- 处理汇率
    SELECT
      substr(day_hour, 1, 6) AS months,
      trans_from,
      max(exchange_rate) AS exchange_rate
    FROM
      dm_platform.itunes_exchange_rate_fmp
    WHERE
      trans_to = 'cny'
      AND day >= 20260301
    GROUP BY
      substr(day_hour, 1, 6),
      trans_from
  )
SELECT
  CASE
    WHEN a.game_id = '23002013' THEN '繁体'
    WHEN a.game_id = '33002013' THEN '韩国'
    WHEN a.game_id = '63002013' THEN '全球'
  END AS region,
  a.channel_type,
  round(sum(a.paid_amount * c.exchange_rate), 2) AS sales,
  a.months
FROM
  transactions a
  LEFT JOIN exchange_rates c ON a.months = c.months AND upper(a.currency_code) = c.trans_from
GROUP BY
  CASE
    WHEN a.game_id = '23002013' THEN '繁体'
    WHEN a.game_id = '33002013' THEN '韩国'
    WHEN a.game_id = '63002013' THEN '全球'
  END,
  a.channel_type,
  a.months;
