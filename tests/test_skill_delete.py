"""专项删除：打包/扁平两形态彻底删除，不残留扁平件「复活」成同名专项。"""
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


def test_delete_flat_skill_removes_all_artifacts(skill_fs):
    sdir = skill_fs / "knowledge" / "skills"
    ks.write_skill("旧专项", "# 旧专项 方法")
    ks.write_skill_meta("旧专项", {"sqls": [], "level": "通用"})
    ks.write_skill_memory("旧专项", {"skill": "旧专项"})

    ks.delete_skill("旧专项")

    assert ks.list_skills() == []
    assert not (sdir / "旧专项.md").exists()
    assert not (sdir / "旧专项.json").exists()
    assert not (sdir / "旧专项.run.json").exists()


def test_delete_bundle_skill_removes_dir(skill_fs):
    sdir = skill_fs / "knowledge" / "skills"
    b = sdir / "旧包"
    b.mkdir(parents=True)
    (b / "skill.md").write_text("# 旧包", encoding="utf-8")
    (b / "meta.json").write_text(json.dumps({"sqls": [], "level": "通用"}), encoding="utf-8")

    ks.delete_skill("旧包")

    assert ks.list_skills() == []
    assert not (sdir / "旧包").exists()


def test_delete_bundle_with_stale_flat_no_resurrect(skill_fs):
    """打包专项删除时，若历史残留扁平 <名>.md/.json/.run.json（脏数据），须一并清掉，
    否则只删打包目录会让残留扁平件「复活」成通用级同名专项（删除后旧名还在）。"""
    sdir = skill_fs / "knowledge" / "skills"
    b = sdir / "旧包"
    b.mkdir(parents=True)
    (b / "skill.md").write_text("# 旧包", encoding="utf-8")
    (b / "meta.json").write_text(json.dumps({"sqls": [], "level": "通用"}), encoding="utf-8")
    (sdir / "旧包.md").write_text("# 旧包 扁平残留", encoding="utf-8")
    (sdir / "旧包.json").write_text(json.dumps({"sqls": [], "level": "通用"}), encoding="utf-8")
    (sdir / "旧包.run.json").write_text("{}", encoding="utf-8")

    ks.delete_skill("旧包")

    assert ks.list_skills() == []
    assert not (sdir / "旧包.md").exists()
    assert not (sdir / "旧包.json").exists()
    assert not (sdir / "旧包.run.json").exists()
    assert not (sdir / "旧包").exists()
