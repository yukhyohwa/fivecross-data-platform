# -*- coding: utf-8 -*-
"""joytools_tools 渲染级回归测试（不连库）：
模板分段解析、占位符填充与残留断言、区服黑名单、活动排期确定性解析器。
执行层（apply_sql/run_raw_sql/ResultStore）已由既有链路测试覆盖，这里只测本模块的纯逻辑。
"""
import re
from datetime import datetime

import pandas as pd
import pytest

import backend.services.joytools_tools as jt

PLACEHOLDER_RE = re.compile(r"\$\{[^{}]*\}|\{[^{}]*\}")


def _ctx(key="rooc", db="pf_rooc"):
    return {"game": {"key": key, "db": db}, "engine": None}


def _no_leftover(sql):
    leftovers = sorted(set(PLACEHOLDER_RE.findall(sql)))
    assert not leftovers, f"残留占位符：{leftovers}"


# ---- 模板分段解析 ----

@pytest.mark.parametrize("name,expected", [
    ("角色事件查询(rooc).sql", ["事件", "道具", "货币", "自选服", "铜币"]),
    ("主服角色列表(rooc).sql", ["主服务器角色", "玩法参与流水"]),
    ("角色列表(ro3).sql", ["角色列表"]),
    ("养成(ro3).sql", ["角色快照", "副本装备快照", "宠物"]),
    ("公平众神殿角色列表(rooc).sql",
     ["公平众神殿赛季角色汇总", "公平众神殿赛季角色不同职业", "玩法参与流水"]),
    ("ROO版本分析数据获取(rooc).sql", [
        "KPI(汇总)", "KPI(三类账号的活跃人数)", "KPI(版本留存与满勤)",
        "商业化(分商品类型)", "商业化(分付费层级)", "玩法(大类)", "VIP(状态变化)", "VIP(名单)",
    ]),
    ("ROO版本分析数据获取LNA(rooc).sql", [
        "KPI(汇总)", "KPI(三类账号的活跃人数)", "KPI(版本留存与满勤)",
        "商业化(分商品类型)", "商业化(分付费层级)", "玩法(大类)", "VIP(状态变化)", "VIP(名单)",
    ]),
])
def test_sections_parse(name, expected):
    from analysis import sql_store
    titles = [n for n, _ in jt._sections(sql_store.read_sql(name))]
    assert titles == expected, f"{name} 段标题不匹配"


def test_cultivation_rooc_sections_count():
    from analysis import sql_store
    titles = [n for n, _ in jt._sections(sql_store.read_sql("养成(rooc).sql"))]
    assert len(titles) == 26


# ---- role_events 渲染 ----

def _render_role_events(monkeypatch, key="rooc", **kwargs):
    captured = {}

    def fake_env(ctx, sql, max_rows):
        captured["sql"] = sql
        captured["max_rows"] = max_rows
        return {"rendered": True}

    monkeypatch.setattr(jt, "_exec_envelope", fake_env)
    result = jt.role_events(_ctx(key=key, db="pf_" + key), **kwargs)
    assert result == {"rendered": True}
    return captured


def test_role_events_rooc_server_mode(monkeypatch):
    cap = _render_role_events(monkeypatch, vroleid="123456",
                              start_date="2026-10-01", end_date="2026-10-02",
                              scopes=["事件", "铜币"], time_filter_mode="服务器", row_limit=100)
    sql = cap["sql"]
    _no_leftover(sql)
    assert cap["max_rows"] == 100
    assert "UNION ALL" in sql
    assert "pf_rooc.dwd_moneyflow2_log" in sql          # rooc 铜币表
    assert "'moneyflow2' AS event_name" in sql
    assert "pf_rooc.ods_others_log" in sql
    assert "dwd_itemflow_log" not in sql                # 道具段未选
    assert "AND event_time >= '2026-10-01 00:00:00'" in sql
    assert "AND event_time < '2026-10-03 00:00:00'" in sql   # 结束 +1 分钟排他
    assert "AND dteventtime >= '2026-10-01 00:00:00'" in sql  # flow 走 dteventtime
    assert "operatordetail" in sql                      # rooc 有 operatordetail 列
    assert "ORDER BY dteventtime" in sql and sql.rstrip().endswith("LIMIT 100")


def test_role_events_hmt_ingest_mode(monkeypatch):
    cap = _render_role_events(monkeypatch, key="ro_hmt", vroleid="999",
                              start_date="2026-10-01", end_date="2026-10-02",
                              scopes=["事件", "铜币"], time_filter_mode="入库")
    sql = cap["sql"]
    _no_leftover(sql)
    assert "pf_ro_hmt.dwd_moneyflow101_log" in sql      # 非 rooc 铜币表
    assert "'moneyflow101' AS event_name" in sql
    assert "CAST(NULL AS DATETIME) AS sr_ts" in sql     # 非 rooc 无 sr_ts
    assert "CAST(NULL AS STRING)" in sql                # 非 rooc 无 operatordetail
    # 入库模式：others 段按 sr_ts 过滤，flow 段（铜币）无过滤
    assert "AND sr_ts >= '2026-10-01 00:00:00'" in sql
    assert sql.count("AND sr_ts >=") == 1


def test_role_events_off_mode(monkeypatch):
    cap = _render_role_events(monkeypatch, vroleid="123", start_date="2026-10-01",
                              end_date="2026-10-01", time_filter_mode="不生效")
    sql = cap["sql"]
    assert "event_time >=" not in sql and "sr_ts >=" not in sql and "dteventtime >=" not in sql


def test_role_events_validation(monkeypatch):
    with pytest.raises(ValueError, match="game_code"):
        jt.role_events(_ctx(key="rooc"), game_code="ro_sea", vroleid="1",
                       start_date="2026-10-01", end_date="2026-10-01")
    with pytest.raises(ValueError, match="格式"):
        jt.role_events(_ctx(), vroleid="1", start_date="2026/10/01", end_date="2026-10-01")
    with pytest.raises(ValueError, match="scopes"):
        jt.role_events(_ctx(), vroleid="1", start_date="2026-10-01",
                       end_date="2026-10-01", scopes=["事件", "自选服"])
    with pytest.raises(ValueError, match="不能晚于"):
        jt.role_events(_ctx(), vroleid="1", start_date="2026-10-02", end_date="2026-10-01")
    with pytest.raises(ValueError, match="纯数字"):
        jt.role_events(_ctx(), vroleid="abc", start_date="2026-10-01", end_date="2026-10-01")


# ---- cultivation_overview 渲染 ----

def _render_cultivation(monkeypatch, key="rooc", **kwargs):
    captured = {}

    def fake_sections(ctx, pairs, label=""):
        captured["pairs"] = pairs
        captured["label"] = label
        return {"count": len(pairs)}

    monkeypatch.setattr(jt, "_exec_sections", fake_sections)
    result = jt.cultivation_overview(_ctx(key=key, db="pf_" + key), **kwargs)
    assert result == {"count": len(captured["pairs"])}
    return captured


def test_cultivation_rooc_blacklist(monkeypatch):
    cap = _render_cultivation(monkeypatch, role_id="123", date="2026-10-15",
                              snapshot_time="2026-10-15 10:00:00")
    assert cap["label"] == "养成(rooc).sql"
    names = [n for n, _ in cap["pairs"]]
    assert len(names) == 26 - 13   # rooc 黑名单 13 段
    for banned in ("印记石板", "卡片组合", "图鉴", "回收养成线"):
        assert banned not in names
    for kept in ("天赋加点", "宠物", "装备", "勋章"):
        assert kept in names
    for _, sql in cap["pairs"]:
        _no_leftover(sql)
        assert "pf_rooc.dwd_roroleycsnapshot_view" in sql


def test_cultivation_ro_hmt_blacklist(monkeypatch):
    cap = _render_cultivation(monkeypatch, key="ro_hmt", role_id="123",
                              date="2026-10-15", snapshot_time="2026-10-15 10:00:00")
    names = [n for n, _ in cap["pairs"]]
    assert len(names) == 26 - 6    # roo 系黑名单 6 段
    for banned in ("天赋加点", "技能加点", "伊米尔星瞳"):
        assert banned not in names
    for kept in ("印记石板", "卡片组合"):
        assert kept in names


def test_cultivation_ro3_template(monkeypatch):
    cap = _render_cultivation(monkeypatch, key="ro3", role_id="123", date="2026-10-15")
    assert cap["label"] == "养成(ro3).sql"
    names = [n for n, _ in cap["pairs"]]
    assert names == ["角色快照", "副本装备快照", "宠物"]
    for _, sql in cap["pairs"]:
        _no_leftover(sql)


def test_cultivation_snapshot_probe(monkeypatch):
    # snapshot_time 缺省时先查该角色当日最新快照时间
    fake_df = pd.DataFrame({"t": ["2026-10-15 09:30:00"]})
    monkeypatch.setattr(jt, "run_raw_sql", lambda engine, sql, max_rows, max_scanned: fake_df)
    monkeypatch.setattr(jt, "games_svc", jt.games_svc)  # apply_sql 纯文本，原样走
    captured = {}

    def fake_sections(ctx, pairs, label=""):
        captured["pairs"] = pairs
        return {"count": len(pairs)}

    monkeypatch.setattr(jt, "_exec_sections", fake_sections)
    jt.cultivation_overview(_ctx(), role_id="123", date="2026-10-15")
    for _, sql in captured["pairs"]:
        assert "09:30:00" in sql


def test_cultivation_no_snapshot_raises(monkeypatch):
    fake_df = pd.DataFrame({"t": [None]})
    monkeypatch.setattr(jt, "run_raw_sql", lambda engine, sql, max_rows, max_scanned: fake_df)
    with pytest.raises(ValueError, match="无养成快照"):
        jt.cultivation_overview(_ctx(), role_id="123", date="2026-10-15")


# ---- role_list 渲染 ----

def _render_role_list(monkeypatch, key="rooc", **kwargs):
    captured = {}

    def fake_sections(ctx, pairs, label=""):
        captured["pairs"] = pairs
        captured["label"] = label
        return {"count": len(pairs)}

    monkeypatch.setattr(jt, "_exec_sections", fake_sections)
    jt.role_list(_ctx(key=key, db="pf_" + key), **kwargs)
    return captured


def test_role_list_rooc_with_role_id(monkeypatch):
    cap = _render_role_list(monkeypatch, date="2026-10-15", role_id="12345",
                            job_names=["骑士领主", "神官"], limit=50)
    names = [n for n, _ in cap["pairs"]]
    assert names == ["主服务器角色", "玩法参与流水"]
    main, flow = dict(cap["pairs"])["主服务器角色"], dict(cap["pairs"])["玩法参与流水"]
    _no_leftover(main)
    _no_leftover(flow)
    assert "dws_rooc_role_daily_label" in main
    assert "AND job_name IN ('骑士领主', '神官')" in main
    assert "AND vroleid = '12345'" in main
    assert main.rstrip().endswith("LIMIT 50")
    assert "dws_rooc_gameplay_flow" in flow
    assert "public_analyst.dim_rooc_job_info" in flow


def test_role_list_rooc_without_role_id_drops_flow(monkeypatch):
    cap = _render_role_list(monkeypatch, date="2026-10-15", role_name="测试")
    names = [n for n, _ in cap["pairs"]]
    assert names == ["主服务器角色"]
    main = dict(cap["pairs"])["主服务器角色"]
    assert "AND vrolename LIKE '%测试%'" in main
    _no_leftover(main)


def test_role_list_ro3(monkeypatch):
    cap = _render_role_list(monkeypatch, key="ro3", date="2026-10-15", server_id="888",
                            job_names=["修罗"])
    names = [n for n, _ in cap["pairs"]]
    assert names == ["角色列表"]
    sql = dict(cap["pairs"])["角色列表"]
    _no_leftover(sql)
    assert "AND snap.server_id = '888'" in sql
    assert "AND snap.job_name IN ('修罗')" in sql
    assert "dwd_ro3_rolesnapshot_di" in sql


def test_role_list_bad_job(monkeypatch):
    with pytest.raises(ValueError, match="职业名称"):
        jt.role_list(_ctx(), date="2026-10-15", job_names=["不存在的职业"])


# ---- fair_pvp_role_query 渲染 ----

def _render_fair_pvp(monkeypatch, key="rooc", **kwargs):
    captured = {}

    def fake_sections(ctx, pairs, label=""):
        captured["pairs"] = pairs
        return {"count": len(pairs)}

    monkeypatch.setattr(jt, "_exec_sections", fake_sections)
    jt.fair_pvp_role_query(_ctx(key=key, db="pf_" + key), **kwargs)
    return captured


def test_fair_pvp_summary_only(monkeypatch):
    cap = _render_fair_pvp(monkeypatch, season_id="1002", rank_groups=["5-钻石"], limit=30)
    names = [n for n, _ in cap["pairs"]]
    assert names == ["公平众神殿赛季角色汇总"]
    sql = dict(cap["pairs"])["公平众神殿赛季角色汇总"]
    _no_leftover(sql)
    assert "season_id = 1002" in sql
    assert "rank_group_name IN ('5')" in sql
    assert sql.rstrip().endswith("LIMIT 30")


def test_fair_pvp_full(monkeypatch):
    cap = _render_fair_pvp(monkeypatch, fair_role_id="777", job_name="神官",
                           start_date="2026-10-01", end_date="2026-10-15")
    names = [n for n, _ in cap["pairs"]]
    assert names == ["公平众神殿赛季角色汇总", "公平众神殿赛季角色不同职业", "玩法参与流水"]
    by_name = dict(cap["pairs"])
    assert "AND fairroleid = '777'" in by_name["公平众神殿赛季角色汇总"]
    assert "fairroleid = '777'" in by_name["公平众神殿赛季角色不同职业"]
    assert "job_name = '神官'" in by_name["玩法参与流水"]
    for _, sql in cap["pairs"]:
        _no_leftover(sql)


def test_fair_pvp_two_sections_without_job(monkeypatch):
    cap = _render_fair_pvp(monkeypatch, fair_role_id="777",
                           start_date="2026-10-01", end_date="2026-10-15")
    names = [n for n, _ in cap["pairs"]]
    assert names == ["公平众神殿赛季角色汇总", "公平众神殿赛季角色不同职业"]


def test_fair_pvp_validation(monkeypatch):
    with pytest.raises(ValueError, match="段位组"):
        jt.fair_pvp_role_query(_ctx(), rank_groups=["不存在段位"])
    with pytest.raises(ValueError, match="职业名称"):
        jt.fair_pvp_role_query(_ctx(), fair_role_id="1",
                               start_date="2026-10-01", end_date="2026-10-01",
                               job_name="错误职业")
    with pytest.raises(ValueError, match="格式"):
        jt.fair_pvp_role_query(_ctx(), fair_role_id="1", start_date="2026-10-01")


# ---- version_analysis 渲染 ----

def _render_version(monkeypatch, key, region, **kwargs):
    captured = {}

    def fake_sections(ctx, pairs, label=""):
        captured["pairs"] = pairs
        captured["label"] = label
        return {"count": len(pairs)}

    monkeypatch.setattr(jt, "_exec_sections", fake_sections)
    jt.version_analysis(_ctx(key=key, db="pf_" + key), region=region, **kwargs)
    return captured


@pytest.mark.parametrize("key,region,label", [
    ("ro_hmt", "hmt", "ROO版本分析数据获取(rooc).sql"),
    ("ro_sea", "sea", "ROO版本分析数据获取(rooc).sql"),
    ("ro_lna", "lna", "ROO版本分析数据获取LNA(rooc).sql"),
])
def test_version_analysis_render(monkeypatch, key, region, label):
    cap = _render_version(monkeypatch, key, region, version_start_date="2026-10-01")
    assert cap["label"] == label
    assert len(cap["pairs"]) == 8
    for _, sql in cap["pairs"]:
        _no_leftover(sql)
        assert f"dws_ro_{region}_" in sql or f"pf_ro_{region}.dws_" in sql


def test_version_analysis_region_mismatch(monkeypatch):
    with pytest.raises(ValueError, match="请切换游戏"):
        jt.version_analysis(_ctx(key="rooc"), region="hmt", version_start_date="2026-10-01")
    with pytest.raises(ValueError, match="hmt、sea、lna"):
        jt.version_analysis(_ctx(key="rooc"), region="rooc", version_start_date="2026-10-01")


# ---- extract_activity_schedule 确定性解析 ----

def test_extract_general_example():
    text = ("二、波利游戏第二季\n"
            "1、毁葛开启倒计时-15日签到有礼（9月11日维护后-9月18日04:59）\n"
            "2、波利宝箱限时开启（9月11日维护后-9月25日00:00）\n")
    r = jt.extract_activity_schedule(_ctx(), text=text, mode="general")
    acts = r["activities"]
    assert r["count"] == 2
    year = datetime.now().year
    assert acts[0] == {
        "title": "波利游戏第二季", "index": 1, "name": "毁葛开启倒计时-15日签到有礼",
        "class": "", "type": "",
        "start_time": f"{year}-09-11 05:00:00", "end_time": f"{year}-09-18 04:59:59",
        "desc": "",
    }
    assert acts[1]["name"] == "波利宝箱限时开启"
    assert acts[1]["class"] == "核心商业化"
    assert acts[1]["type"] == "波利宝箱限时开启"
    assert acts[1]["start_time"] == f"{year}-09-11 05:00:00"
    assert acts[1]["end_time"] == f"{year}-09-24 23:59:59"   # 结束 00:00 → 前一天 23:59:59


def test_extract_rooc_chain():
    text = ("二、半周年庆典\n"
            "1、时装商店更新（9月11日维护后-9月18日04:59）\n"
            "2、星愿回礼——星座系列时装登场（9月11日维护后-9月25日00:00）\n"
            "3、半周年限时商店开启（9月11日维护后-9月25日00:00）\n"
            "4、半周年储值好礼赠送（9月11日维护后-9月18日04:59）\n"
            "5、奈吉大消除（9月11日维护后-9月18日04:59）\n"
            "6、毁葛开启倒计时-15日签到有礼（9月11日维护后-9月18日04:59）\n")
    r = jt.extract_activity_schedule(_ctx(), text=text, mode="rooc")
    acts = r["activities"]
    assert r["count"] == 6
    got = [(a["name"], a["class"], a["type"]) for a in acts]
    assert got == [
        ("时装商店更新", "常规商业化", "外观商店"),
        ("星愿回礼——星座系列时装登场", "常规商业化", "累充"),   # 含时装但累充优先
        ("半周年限时商店开启", "常规商业化", "金币商店"),
        ("半周年储值好礼赠送", "常规商业化", "充值加赠"),
        ("奈吉大消除", "休闲小游戏", ""),
        ("毁葛开启倒计时-15日签到有礼", "", ""),
    ]
    assert all(a["title"] == "半周年庆典" for a in acts)
    assert [a["index"] for a in acts] == [1, 2, 3, 4, 5, 6]


def test_extract_shop_merge():
    text = ("十、时装商店更新\n"
            "促销时间：2026/10/15 05:00:00 ~ 2026/11/01 04:59:59\n"
            "【限时专区】\n"
            "1. 【冰火鬼面】\n"
            "2. 【捣蛋猫猫】\n"
            "【经典专区】\n"
            "1.【坐骑：拉风南瓜车】\n")
    r = jt.extract_activity_schedule(_ctx(), text=text, mode="rooc")
    acts = r["activities"]
    assert r["count"] == 1
    a = acts[0]
    assert a["name"] == "时装商店更新"
    assert a["index"] == 1
    assert a["class"] == "常规商业化" and a["type"] == "外观商店"
    assert a["start_time"] == "2026-10-15 05:00:00"
    assert a["end_time"] == "2026-11-01 04:59:59"
    assert a["desc"] == "冰火鬼面；捣蛋猫猫；坐骑：拉风南瓜车"   # 分区名不混入


def test_extract_title_as_activity_and_incomplete_dropped():
    text = ("四、周年庆典（9月11日维护后-9月18日04:59）\n"
            "五、神秘活动\n"
            "1、无时间活动\n")
    r = jt.extract_activity_schedule(_ctx(), text=text, mode="general")
    acts = r["activities"]
    assert len(acts) == 1
    assert acts[0]["name"] == "周年庆典" and acts[0]["index"] == 1


def test_extract_cross_year():
    text = "六、跨年活动\n1、跨年礼包（12月28日-1月3日）\n"
    r = jt.extract_activity_schedule(_ctx(), text=text, mode="general")
    acts = r["activities"]
    assert len(acts) == 1
    year = datetime.now().year
    assert acts[0]["start_time"] == f"{year}-12-28 05:00:00"
    assert acts[0]["end_time"] == f"{year + 1}-01-03 23:59:59"


def test_extract_empty_and_validation():
    r = jt.extract_activity_schedule(_ctx(), text="没有任何活动", mode="general")
    assert r["activities"] == [] and r["count"] == 0
    with pytest.raises(ValueError, match="text"):
        jt.extract_activity_schedule(_ctx(), text="")
    with pytest.raises(ValueError, match="mode"):
        jt.extract_activity_schedule(_ctx(), text="x", mode="bad")


# ---- agent_tools 挂载集成 ----

def test_agent_tools_mount():
    from backend.services import agent_tools as at
    names = [t["function"]["name"] for t in at.TOOL_SCHEMAS]
    for expected in ("role_events", "cultivation_overview", "role_list",
                     "fair_pvp_role_query", "version_analysis", "extract_activity_schedule"):
        assert expected in names
        assert expected in at._HANDLERS
    assert at._HANDLERS["role_events"] is jt.role_events
