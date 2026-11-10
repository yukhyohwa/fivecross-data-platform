"""P1-15：专项原子重命名——主文件/打包目录 + 元数据/记忆 + 笔记 + _versions 镜像一并迁移，订阅引用同步。"""
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


def _flat_skill(name: str, root: Path):
    ks.write_skill(name, f"# {name} 方法")
    ks.write_skill_meta(name, {"sqls": ["a.sql"], "level": "通用"})
    ks.write_skill_memory(name, {"skill": name})
    ks.write_skill_notes(name, "踩坑笔记")
    return root / "knowledge" / "skills" / f"{name}.md"


def test_flat_rename_moves_all_artifacts(skill_fs):
    old_path = _flat_skill("旧专项", skill_fs)
    versioning.write_text(old_path, "# 旧专项 方法 v2")  # 产生版本镜像

    ks.rename_skill("旧专项", "新专项")

    # 主工件 + 元数据 + 记忆 + 笔记全部迁移，旧名清空
    sdir = skill_fs / "knowledge" / "skills"
    assert (sdir / "新专项.md").exists() and not (sdir / "旧专项.md").exists()
    assert (sdir / "新专项.json").exists() and not (sdir / "旧专项.json").exists()
    assert (sdir / "新专项.run.json").exists() and not (sdir / "旧专项.run.json").exists()
    assert (sdir / ".notes" / "新专项.md").exists() and not (sdir / ".notes" / "旧专项.md").exists()
    assert "新专项" in ks.list_skills() and "旧专项" not in ks.list_skills()
    # 版本历史随名迁移：新名能列出旧版本（v1 + v2 两份）
    vers = versioning.list_versions(sdir / "新专项.md")
    assert len(vers) >= 2


def test_bundle_rename_moves_dir_and_versions(skill_fs):
    sdir = skill_fs / "knowledge" / "skills"
    b = sdir / "旧包"
    b.mkdir(parents=True)
    (b / "skill.md").write_text("# 旧包", encoding="utf-8")
    (b / "meta.json").write_text(json.dumps({"sqls": [], "level": "通用"}), encoding="utf-8")
    (b / "run.json").write_text("{}", encoding="utf-8")
    (b / "sql").mkdir()
    (b / "sql" / "快照.sql").write_text("SELECT 1", encoding="utf-8")
    versioning.write_text(b / "skill.md", "# 旧包 v2")  # 版本镜像 _versions/knowledge/skills/旧包/skill.md/

    ks.rename_skill("旧包", "新包")

    assert (sdir / "新包" / "skill.md").exists() and not (sdir / "旧包").exists()
    assert (sdir / "新包" / "sql" / "快照.sql").exists()  # 内嵌快照原样随目录带走
    assert versioning.list_versions(sdir / "新包" / "skill.md")  # 版本镜像随名迁移


def test_rename_conflicts_and_missing(skill_fs):
    _flat_skill("甲", skill_fs)
    _flat_skill("乙", skill_fs)
    with pytest.raises(ValueError, match="已存在"):
        ks.rename_skill("甲", "乙")
    with pytest.raises(ValueError, match="不存在"):
        ks.rename_skill("丙", "丁")
    # 失败后原文件不受影响
    sdir = skill_fs / "knowledge" / "skills"
    assert (sdir / "甲.md").exists() and (sdir / "乙.md").exists()


def test_rename_idempotent_same_name(skill_fs):
    _flat_skill("同名", skill_fs)
    ks.rename_skill("同名", "同名")  # 不抛错、无副作用
    assert "同名" in ks.list_skills()


def test_save_flat_to_bundle_cleans_stale_flat(skill_fs):
    """保存把扁平专项升级为打包形态时，须清掉扁平 <名>.md/.json/.run.json 残留，
    否则下次改名会被 list_skills 当「旧名复活」的第二个专项列出（命名重复根因）。"""
    _flat_skill("旧专项", skill_fs)
    sdir = skill_fs / "knowledge" / "skills"

    ks.write_skill_bundle("旧专项", "# 旧专项 方法 v2", {"sqls": [], "level": "通用"},
                          sqls={}, models={}, knowledge={}, provenance={})

    assert (sdir / "旧专项" / "skill.md").exists()
    assert not (sdir / "旧专项.md").exists()
    assert not (sdir / "旧专项.json").exists()
    assert not (sdir / "旧专项.run.json").exists()
    assert ks.list_skills() == ["旧专项"]


def test_rename_bundle_with_stale_flat_no_duplicate(skill_fs):
    """打包专项改名时，若历史残留扁平 <旧名>.md/.json/.run.json（脏数据），须一并清掉，
    否则旧名会与新名并存出现。"""
    sdir = skill_fs / "knowledge" / "skills"
    b = sdir / "旧包"
    b.mkdir(parents=True)
    (b / "skill.md").write_text("# 旧包", encoding="utf-8")
    (b / "meta.json").write_text(json.dumps({"sqls": [], "level": "通用"}), encoding="utf-8")
    (sdir / "旧包.md").write_text("# 旧包 扁平残留", encoding="utf-8")
    (sdir / "旧包.json").write_text("{}", encoding="utf-8")
    (sdir / "旧包.run.json").write_text("{}", encoding="utf-8")

    ks.rename_skill("旧包", "新包")

    assert (sdir / "新包" / "skill.md").exists()
    assert not (sdir / "旧包.md").exists()
    assert not (sdir / "旧包.json").exists()
    assert not (sdir / "旧包.run.json").exists()
    assert ks.list_skills() == ["新包"]


def test_full_rename_save_rename_no_stale_duplicate(skill_fs):
    """用户场景端到端：扁平专项 改名→保存(扁平→打包)→再改名，全程不复活旧名。"""
    _flat_skill("旧专项", skill_fs)
    ks.rename_skill("旧专项", "中专项")
    ks.write_skill_bundle("中专项", "# 中专项 v2", {"sqls": [], "level": "通用"},
                          sqls={}, models={}, knowledge={}, provenance={})
    ks.rename_skill("中专项", "新专项")
    assert ks.list_skills() == ["新专项"]


def test_subscription_refs_renamed(tmp_path, monkeypatch):
    from backend.services import subscriptions

    monkeypatch.setattr(subscriptions, "SUB_DIR", tmp_path / "subs")
    a = subscriptions.save_subscription({"name": "绑旧专项", "skill": "旧专项"})
    b = subscriptions.save_subscription({"name": "绑其他", "skill": "其他专项"})

    updated = subscriptions.rename_skill_refs("旧专项", "新专项")
    assert updated == 1
    assert subscriptions.get_subscription(a["id"])["skill"] == "新专项"
    assert subscriptions.get_subscription(b["id"])["skill"] == "其他专项"
