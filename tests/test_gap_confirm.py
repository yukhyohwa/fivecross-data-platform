"""审计 P2-1：缺口修复「预览 + 一键确认」流程的后端单测。

覆盖 _apply_modify_confirm（自动改写确认应用，防篡改 + 护栏复检）与
_apply_kb_bind（知识库绑定确认应用，防篡改重扫），以及 apply_gap_draft 的分发。
"""
import pytest

from backend.services import gap_fix as gf


class FakeSqlStore:
    def __init__(self, files=None):
        self.files = dict(files or {})
        self.written = {}

    def read_sql(self, name):
        return self.files.get(name, "")

    def read_sql_meta(self, name):
        # 通用级默认元数据（对抗审查三轮 F0 的 _sql_target_visible 可见性闸门依赖）；
        # 通用级对任意用户上下文可见，测试语义不变。
        return {"level": "通用", "game": "", "owner": ""}

    def write_sql(self, name, content):
        self.written[name] = content
        self.files[name] = content


class FakeKs:
    def __init__(self):
        self.bound = []

    def add_skill_doc(self, name, doc):
        self.bound.append((name, doc))


SQL_BEFORE = "SELECT * FROM t WHERE dt = '2026-01-01'"
SQL_AFTER = "SELECT * FROM t WHERE dt >= current_date() - 30"


def _gap():
    return {"remedy_type": "sql", "remedy_action": "modify", "issue": "硬编码日期"}


@pytest.fixture()
def quiet(monkeypatch):
    """屏蔽外部依赖：校验/护栏/写盘/登记全部换成记录器。"""
    monkeypatch.setattr(gf, "validate_sql", lambda s: None)
    monkeypatch.setattr(gf, "guard_rewrite", lambda a, b: [])
    monkeypatch.setattr(gf, "detect_hardcoded_dates", lambda s: [])
    recorded = {"rewrites": [], "marked": [], "notes": []}
    monkeypatch.setattr(gf, "_apply_rewrite",
                        lambda *args, **kwargs: recorded["rewrites"].append(args))
    monkeypatch.setattr(gf, "mark_gap",
                        lambda s, g, st: recorded["marked"].append((s, g.get("issue"), st))
                        if s else None)
    monkeypatch.setattr(gf, "_append_skill_note",
                        lambda s, line: recorded["notes"].append((s, line)))
    return recorded


def _draft(store, **over):
    d = {"kind": "sql_modify_confirm", "name": "流水",
         "before_sql": store.read_sql("流水.sql"), "sql": SQL_AFTER,
         "prompt": "改日期", "gap": _gap()}
    d.update(over)
    return d


def test_apply_modify_confirm_happy_path(monkeypatch, quiet):
    store = FakeSqlStore({"流水.sql": SQL_BEFORE})
    monkeypatch.setattr(gf, "sql_store", store)
    r = gf._apply_modify_confirm("专项A", _draft(store), "m", game_key="kof")
    assert r["ok"] and r["name"] == "流水.sql"
    # 写盘经 _apply_rewrite（before 用确认时的盘上内容），登记 fixed，笔记留痕
    assert quiet["rewrites"][0][0] == "专项A" and quiet["rewrites"][0][1] == "流水.sql"
    assert quiet["rewrites"][0][3] == SQL_BEFORE and quiet["rewrites"][0][4] == SQL_AFTER
    assert quiet["marked"] == [("专项A", "硬编码日期", "fixed")]
    assert quiet["notes"] and quiet["notes"][0][0] == "专项A"


def test_apply_modify_confirm_tampered_disk_refused(monkeypatch, quiet):
    """预览期间盘上 SQL 被他人改动 → 拒绝应用，不写盘。"""
    store = FakeSqlStore({"流水.sql": "SELECT 999"})
    monkeypatch.setattr(gf, "sql_store", store)
    # 草稿捕获的是改动前的原文，确认时盘上已是另一份
    r = gf._apply_modify_confirm("专项A", _draft(store, before_sql=SQL_BEFORE), "m")
    assert not r["ok"] and "改动" in r["message"]
    assert quiet["rewrites"] == [] and quiet["marked"] == []


def test_apply_modify_confirm_guard_violation_refused(monkeypatch, quiet):
    store = FakeSqlStore({"流水.sql": SQL_BEFORE})
    monkeypatch.setattr(gf, "sql_store", store)
    monkeypatch.setattr(gf, "guard_rewrite", lambda a, b: ["输出列被删改"])
    r = gf._apply_modify_confirm("专项A", _draft(store), "m")
    assert not r["ok"] and "护栏" in r["message"]
    assert r["violations"] == ["输出列被删改"]
    assert quiet["rewrites"] == []


def test_apply_modify_confirm_leftover_dates_refused(monkeypatch, quiet):
    store = FakeSqlStore({"流水.sql": SQL_BEFORE})
    monkeypatch.setattr(gf, "sql_store", store)
    monkeypatch.setattr(gf, "detect_hardcoded_dates", lambda s: ["2026-01-01"])
    r = gf._apply_modify_confirm("专项A", _draft(store), "m")
    assert not r["ok"] and "硬编码日期" in r["message"]
    assert quiet["rewrites"] == []


def test_apply_modify_confirm_without_skill_still_applies(monkeypatch, quiet):
    store = FakeSqlStore({"流水.sql": SQL_BEFORE})
    monkeypatch.setattr(gf, "sql_store", store)
    r = gf._apply_modify_confirm(None, _draft(store), "m")
    assert r["ok"]
    assert quiet["rewrites"] and quiet["marked"] == [] and quiet["notes"] == []


def test_apply_kb_bind_happy_path(monkeypatch, quiet):
    ks = FakeKs()
    monkeypatch.setattr(gf, "ks", ks)
    monkeypatch.setattr(gf, "_scan_existing_doc", lambda gap, game: "口径说明.md")
    gap = {"remedy_type": "kb", "issue": "缺口径文档"}
    draft = {"kind": "kb_bind_confirm", "doc": "口径说明.md", "gap": gap, "game_key": "kof"}
    r = gf._apply_kb_bind("专项A", draft, game_key="kof")
    assert r["ok"] and r["doc"] == "口径说明.md"
    assert ks.bound == [("专项A", "口径说明.md")]
    assert quiet["marked"] == [("专项A", "缺口径文档", "fixed")]


def test_apply_kb_bind_doc_gone_refused(monkeypatch, quiet):
    ks = FakeKs()
    monkeypatch.setattr(gf, "ks", ks)
    monkeypatch.setattr(gf, "_scan_existing_doc", lambda gap, game: None)
    gap = {"remedy_type": "kb", "issue": "缺口径文档"}
    draft = {"kind": "kb_bind_confirm", "doc": "口径说明.md", "gap": gap}
    r = gf._apply_kb_bind("专项A", draft, game_key="kof")
    assert not r["ok"] and "变化" in r["message"]
    assert ks.bound == [] and quiet["marked"] == []


def test_apply_kb_bind_without_skill_refused(quiet):
    draft = {"kind": "kb_bind_confirm", "doc": "x.md", "gap": {"issue": "i"}}
    r = gf._apply_kb_bind(None, draft, game_key="kof")
    assert not r["ok"] and "专项" in r["message"]


def test_apply_gap_draft_dispatches_confirm_kinds(monkeypatch):
    calls = []
    monkeypatch.setattr(gf, "_apply_modify_confirm", lambda *a, **kw: calls.append("modify") or {"ok": True})
    monkeypatch.setattr(gf, "_apply_kb_bind", lambda *a, **kw: calls.append("kb") or {"ok": True})
    assert gf.apply_gap_draft(None, {"kind": "sql_modify_confirm"}, "m", "kof", None, None)["ok"]
    assert gf.apply_gap_draft(None, {"kind": "kb_bind_confirm"}, "m", "kof", None, None)["ok"]
    assert calls == ["modify", "kb"]


def test_apply_gap_draft_unknown_kind(monkeypatch, quiet):
    r = gf.apply_gap_draft(None, {"kind": "nope"}, "m", "kof", None, None)
    assert not r["ok"] and "未知" in r["message"]
