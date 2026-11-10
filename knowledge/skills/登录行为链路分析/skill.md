---
name: "登录行为链路分析"
description: "分析游戏登录完整链路（安装初始化→进登录页→登录面板→多链路合流→最终登录→选服建角进游戏），按去重设备数输出漏斗分布与分链路成功率，并对媒体邮箱链、Apple/Google 第三方做失败根因钻取。默认分析当天，可指定日期范围。"
version: 1
tags: [登录, 漏斗, 埋点, 媒体邮箱, apple, 第三方登录, 登录成功率]
category: "用户行为分析"
trigger:
  keywords: [登录链路, 登录漏斗, 登录行为, 媒体邮箱登录, apple登录, 登录失败, 第三方登录, 登录成功率]
inputs:
  - name: 起始日期
    type: string
    label: "开始日期（YYYY-MM-DD，默认今天）"
    required: false
    default: "2026-08-27"
  - name: 结束日期
    type: string
    label: "结束日期（YYYY-MM-DD，默认与起始日期相同）"
    required: false
  - name: 数据库
    type: string
    label: "分析库（默认 pf_kof_sea）"
    required: false
    default: "pf_kof_sea"
---

## 前置条件

1. SQL IDE 后端已启动，目标库 `{数据库}`连接已建立。
2. 所有设备数一律 **按 `device_id` 去重**（去重设备 = 当日/区间内出现过该行为的独立设备）。
3. 数据日期过滤用 `date` 字段：单日 `date = '{起始日期}'`，区间 `date BETWEEN '{起始日期}' AND '{结束日期}'`。默认「今天」= 分析当天。
4. 本 Skill 主要面向「登录」环节，涉及两张表：
   - `{数据库}.ods_others_view` —— 全量行为事件，`event_name` / `device_id` / `date` / `event_value`(JSON)
   - `{数据库}.dwd_login_media_code_send_result_view` —— 媒体邮箱发码结果（已展平，含 `result`/`exception_reason`/`fail_reason`/`send_count`/`request_cost_ms`/`media_type`）

## 分析方法

这是一个**并行多链路**登录漏斗，不是单条线性漏斗。核心思路：

1. **先看主漏斗**（进入登录页 → 面板 → 各链路出发 → 最终登录结果），按去重设备数串联。
2. **再分链路各自看成功率**：OU 运营商、JM 手机、第三方（Google/Apple/Guest）、自动登录、媒体邮箱、历史账号。这六条并行链路互不依赖，分别最终合流到 `game_login_result`。
3. **对「媒体邮箱链」和「第三方(尤其 Apple)」做失败根因钻取**——这两个是历史结论里的两大断点。

### 关键口径提醒（避免误判）

- `login_method_select`（很小，~70 台）**不是**主面板锚点；真正的第三方方式选择是 **`login_method_third_select`**（千级），两者差 30 倍，别用错。
- 底部链路里 `server_choose`/`role_create`/`role_enter` 会被**自动登录**绕过，不能当强制阶段，否则出现「选服 > 登录成功」倒挂。
- `game_role_enter` 是另一套 SDK 且字段不全，**进游戏终点用 `role_enter`**。
- `game_login_result` 的 `login_method` 几乎全是 `32`（OU/JM 渠道），第三方 Google/Apple 走独立 `sdk_account_login`，二者不要混进同一个漏斗。

## 步骤

### 1. 主漏斗各阶段去重设备数

对下列 `event_name` 逐个统计去重设备数（可用一条 `GROUP BY event_name`）：

```sql
SELECT event_name, COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.ods_others_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}'
  AND event_name IN (
    'life_init_install','life_init_start','life_init_result','life_init_result_ad',
    'login_page','login_consent_remind_show','login_consent_remind_result',
    'login_panel_show','login_game_call',
    'login_method_third_select','login_method_third_start','login_method_third_result',
    'login_button_click',
    'login_terms_click','login_private_click','game_terms_click','game_private_click',
    'login_history_show','login_history_login_click','login_history_result','login_history_newlogin',
    'login_jm_start','login_jm_result','login_ou_start','login_ou_result',
    'login_auto_start','login_auto_result',
    'login_media_zone_pick','login_media_input','login_media_code_send',
    'login_media_code_send_result','login_media_code_input','login_media_code_input_result',
    'game_login_result','server_choose','role_create','role_enter'
  )
GROUP BY event_name
ORDER BY dev_cnt DESC;
```

最终登录结果拆分（`event_value.result`）：

```sql
SELECT COALESCE(NULLIF(get_json_string(event_value,'$.result'),''),'(空)') AS result,
       COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.ods_others_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}' AND event_name = 'game_login_result'
GROUP BY result ORDER BY dev_cnt DESC;
```

### 2. 第三方方式拆分（Google / Apple / Guest）

```sql
SELECT get_json_string(event_value,'$.method') AS method,
       get_json_string(event_value,'$.result') AS result,
       COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.ods_others_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}'
  AND event_name IN ('login_method_third_select','login_method_third_start','login_method_third_result')
GROUP BY method, result ORDER BY dev_cnt DESC;
```

对 `login_method_third_select` 可按 `method`（或 `event_value` 里的登录方式）分布：

```sql
SELECT get_json_string(event_value,'$.method') AS method, COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.ods_others_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}' AND event_name = 'login_method_third_select'
GROUP BY method ORDER BY dev_cnt DESC;
```

### 3. 媒体邮箱链（重点断点）

发码结果分布（用展平的表，`result`/`exception_reason`/`fail_reason` 都是列）：

```sql
SELECT result, COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.dwd_login_media_code_send_result_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}'
GROUP BY result ORDER BY dev_cnt DESC;
```

发码异常的明细（exception/fail）：

```sql
SELECT result, exception_reason, fail_reason, COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.dwd_login_media_code_send_result_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}'
  AND result <> 'success'
GROUP BY result, exception_reason, fail_reason ORDER BY dev_cnt DESC;
```

发码耗时/重试（隐性因素）：

```sql
SELECT COUNT(DISTINCT device_id) AS dev_cnt,
       ROUND(AVG(request_cost_ms),1) AS avg_cost_ms,
       MAX(request_cost_ms) AS max_cost_ms,
       AVG(send_count) AS avg_send_count
FROM {数据库}.dwd_login_media_code_send_result_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}';
```

媒体链「邮箱最终登录」失败原因（`login_jm_result` 里 `login_method='email'`）：

```sql
SELECT get_json_string(event_value,'$.result') AS result,
       COALESCE(get_json_string(event_value,'$.fail_reason'),'(无)') AS fail_reason,
       COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.ods_others_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}'
  AND event_name = 'login_jm_result'
  AND get_json_string(event_value,'$.login_method') = 'email'
GROUP BY result, fail_reason ORDER BY dev_cnt DESC;
```

（注意验证码错误会有多语言文案，如 `รหัสยืนยันไม่ถูกต้อง`(泰) / `Incorrect verification code`(英) / `验证码不正确`(简中) / `잘못된 인증 코드입니다`(韩) / `驗證碼不正確`(繁中)，都归为「验证码不正确」类。）

### 4. 第三方失败根因钻取（Apple / Google）

第三方结果失败原因（`login_method_third_result`）：

```sql
SELECT get_json_string(event_value,'$.method') AS method,
       get_json_string(event_value,'$.result') AS result,
       COALESCE(get_json_string(event_value,'$.fail_reason'),'(无)') AS fail_reason,
       COUNT(DISTINCT device_id) AS dev_cnt
FROM {数据库}.ods_others_view
WHERE date BETWEEN '{起始日期}' AND '{结束日期}'
  AND event_name = 'login_method_third_result'
  AND get_json_string(event_value,'$.result') <> 'success'
GROUP BY method, result, fail_reason ORDER BY dev_cnt DESC;
```

## 分析结论产出

根据上述数据，输出：

1. **主漏斗表**：各阶段去重设备数 + 相邻阶段环比（注意「面板展示→选择方式」的下降是第三方单链路特征，不等于全量流失，因为 OU/JM/自动/历史用户不走该面板）。
2. **分链路成功率表**：OU / JM / 第三方 / 自动 / 媒体邮箱 / 历史账号，各自「出发→成功」的转化率，标出明显偏低的链路。
3. **媒体邮箱链拆分**：输邮箱→发码→发码结果→最终登录成功，每段设备数与流失；发码技术成功率（`result=success` 占比）通常很高，但**要指出「发码成功 ≠ 用户收到码」**——若后续大量「验证码不正确」+ 高重试次数，根因指向**邮件投递/送达／垃圾箱**，而非后端接口。
4. **第三方失败归类**：Apple 类大量 `The web operation was canceled by the user.` 是**用户在授权弹窗主动取消**（体验问题），Google 类多为设备侧无依赖/无账号（客户端环境问题）。区分技术故障（SSL/DNS/timeout/config）与用户行为。
5. **最终一句话结论**：全站登录整体是否稳定（最终 `game_login_result` 成功率），以及哪 1~2 个断点最值得优化、优先级建议。

> 结论里所有百分比都要标注口径来源（去重设备数 + 事件数），避免把多语言失败文案、或不同 SDK 链路混为一谈。
