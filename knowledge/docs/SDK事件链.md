> 来源：JoyTools 88 Agent（apps/41_RO-转化归因.py（EVENT_LIBRARY/ALLOWED_REGIONS/EVENT_BUSINESS_CONTEXT））

# SDK 事件链与登录转化漏斗

## 适用游戏
[rooc, ro_hmt, ro_sea, ro_lna, ro_zxf]（注意：无 rooc_am）。

## 登录转化漏斗事件链（11 步，按发生顺序）
1. ta_app_install 设备安装
2. ta_hot_download 热更开始
3. ta_hot_info 热更弹窗
4. ta_hot_download_60 热更 60%
5. ta_hot_downloaded 热更 100%
6. ta_loading 解压
7. ta_loaded 解压 100%
8. ta_sdk_auth 选择登录方式
9. ta_login_loginserver 进入选服界面
10. ta_login_gateserver 点击进入游戏
11. ta_enter_game 进入游戏场景（登录成功）

## 口径
- 漏斗按 event_name 计数、按事件顺序排序，计算相邻两步的转化率与流失。
- 安装环节按设备口径、登录环节按账号口径，混合前先确认分母归属（EVENT_BUSINESS_CONTEXT 记录各事件业务语义）。

## 注意事项
- 事件名是 SDK 埋点标识，不要随意改写或"归一化"，否则与埋点表对不上。
- rooc_am 不在适用清单内，涉及它要先确认渠道侧埋点版本一致再扩展。
