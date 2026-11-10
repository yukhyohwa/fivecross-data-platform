"""专项上线/下线：meta.online 默认上线（向后兼容），下线后从 list_online_skills 剔除、
新建默认下线、保存/刷新保留现状；上线/下线只影响聊天/Agent 可见性，不影响专项管理列表。"""
import json
from pathlib import Path

import pytest

from analysis import knowledge_store as ks
from analysis import versioning


@pytest.fixture()
def skill_fs(tmp_path, monkeypatch):
    """把 knowledge_store 与 versioning 的根重定向到临时目录，避免测试碰真实知识库/版本库。"""
    monkeypatch.setattr(versioning, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(versioning, "VERSIONS_DIR", tmp_path / "_versions")
    monkeypatch.setattr(ks, "SKILLS_DIR", tmp_path / "knowledge" / "skills")
    monkeypatch.setattr(ks, "DOCS_DIR", tmp_path / "knowledge" / "docs")
    ks.SKILLS_DIR.mkdir(parents=True, exist_ok=True)
    ks.DOCS_DIR.mkdir(parents=True, exist_ok=True)
    return tmp_path


def _flat(name: str, meta: dict | None = None):
    ks.write_skill(name, f"# {name} 方法")
    ks.write_skill_meta(name, meta if meta is not None else {"sqls": [], "level": "通用"})


def test_read_skill_meta_defaults_online_true(skill_fs):
    """历史专项（meta 无 online 字段）按上线处理——新增字段不能让既有专项突然全部下线。"""
    _flat("历史专项", {"sqls": ["a.sql"], "level": "通用"})
    assert ks.read_skill_meta("历史专项")["online"] is True
    assert ks.skill_online("历史专项") is True


def test_set_skill_online_preserves_other_fields(skill_fs):
    """上线/下线只改 online，其它元数据（sqls/level/game/owner/forecast）原样保留。"""
    ks.write_skill("专项甲", "# 专项甲")
    ks.write_skill_meta("专项甲", {
        "sqls": ["a.sql", "b.sql"], "level": "项目", "game": "kof",
        "owner": "u1", "forecast": "churn", "summary": "摘要",
    })

    ks.set_skill_online("专项甲", False)

    meta = ks.read_skill_meta("专项甲")
    assert meta["online"] is False
    assert meta["sqls"] == ["a.sql", "b.sql"]
    assert meta["level"] == "项目"
    assert meta["game"] == "kof"
    assert meta["owner"] == "u1"
    assert meta["forecast"] == "churn"
    assert meta["summary"] == "摘要"
    assert ks.skill_online("专项甲") is False


def test_list_online_skills_filters_offline(skill_fs):
    """下线专项从 list_online_skills 剔除，但仍留在 list_skills（专项管理列表照常展示）。"""
    _flat("已上线", {"sqls": [], "level": "通用"})
    _flat("调试中", {"sqls": [], "level": "通用"})
    ks.set_skill_online("调试中", False)

    assert sorted(ks.list_skills()) == ["已上线", "调试中"]
    assert ks.list_online_skills() == ["已上线"]
    # 下线后再上线，重新回到 list_online_skills
    ks.set_skill_online("调试中", True)
    assert sorted(ks.list_online_skills()) == ["已上线", "调试中"]


def test_online_on_save_new_offline_existing_preserve(skill_fs):
    """保存/刷新：新建默认下线；已存在专项保持现状（上线→上线、下线→下线）。"""
    # 新建（不存在）→ 下线
    assert ks.online_on_save("尚不存在") is False

    # 已存在且上线 → 保持上线
    _flat("已上线", {"sqls": [], "level": "通用"})
    assert ks.online_on_save("已上线") is True

    # 已存在且下线 → 保持下线
    ks.set_skill_online("已上线", False)
    assert ks.online_on_save("已上线") is False


def test_set_online_on_bundle_skill(skill_fs):
    """打包形态专项同样能上线/下线（meta 落在目录内 meta.json）。"""
    sdir = skill_fs / "knowledge" / "skills"
    b = sdir / "打包专项"
    b.mkdir(parents=True)
    (b / "skill.md").write_text("# 打包专项", encoding="utf-8")
    (b / "meta.json").write_text(json.dumps({"sqls": ["a.sql"], "level": "通用"}), encoding="utf-8")

    ks.set_skill_online("打包专项", False)

    assert ks.skill_online("打包专项") is False
    assert ks.list_online_skills() == []
    assert ks.list_skills() == ["打包专项"]
    raw = json.loads((b / "meta.json").read_text(encoding="utf-8"))
    assert raw["online"] is False
    assert raw["sqls"] == ["a.sql"]  # 其它字段原样保留
