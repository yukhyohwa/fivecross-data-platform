"""P1-16 diff：versioning.diff_version「版本 vs 当前」统一 diff——基本 diff、缺失、路径越界、超大截断。"""
from analysis import versioning


def _setup(tmp_path, monkeypatch, old: str, new: str):
    target = tmp_path / "a.sql"
    vdir = tmp_path / "_versions" / "a.sql"
    vdir.mkdir(parents=True)
    vf = vdir / "20260101_000000_abc123.sql"
    vf.write_text(old, encoding="utf-8")
    if new is not None:
        target.write_text(new, encoding="utf-8")
    monkeypatch.setattr(versioning, "VERSIONS_DIR", tmp_path / "_versions")
    monkeypatch.setattr(versioning, "PROJECT_ROOT", tmp_path)
    return target, vf.name


def test_diff_version_basic(tmp_path, monkeypatch):
    target, vname = _setup(tmp_path, monkeypatch, "SELECT 1;\n", "SELECT 1;\nSELECT 2;\n")
    text, truncated = versioning.diff_version(target, vname)
    assert not truncated
    assert "\n SELECT 1;" in text  # 上下文行（版本里没有删除，行首一个空格前缀）
    assert "+SELECT 2;" in text   # 新增行
    assert f"版本 {vname}" in text


def test_diff_version_deletion(tmp_path, monkeypatch):
    target, vname = _setup(tmp_path, monkeypatch, "SELECT 1;\nSELECT 2;\n", "SELECT 1;\n")
    text, truncated = versioning.diff_version(target, vname)
    assert not truncated
    assert "-SELECT 2;" in text  # 删除行


def test_diff_version_target_missing(tmp_path, monkeypatch):
    target, vname = _setup(tmp_path, monkeypatch, "SELECT 1;\n", None)
    text, truncated = versioning.diff_version(target, vname)
    assert not truncated
    assert "-SELECT 1;" in text  # 当前不存在 → 全部视为删除


def test_diff_version_missing_returns_none(tmp_path, monkeypatch):
    target, _ = _setup(tmp_path, monkeypatch, "SELECT 1;\n", "SELECT 1;\n")
    assert versioning.diff_version(target, "nope.sql") is None


def test_diff_version_path_traversal_returns_none(tmp_path, monkeypatch):
    target, _ = _setup(tmp_path, monkeypatch, "SELECT 1;\n", "SELECT 1;\n")
    # 越界版本名 → None（与 restore 同口径防穿越）
    assert versioning.diff_version(target, "../evil.sql") is None


def test_diff_version_large_truncated(tmp_path, monkeypatch):
    target, vname = _setup(tmp_path, monkeypatch, "x" * (600 * 1024), "y" * 10)
    text, truncated = versioning.diff_version(target, vname)
    assert truncated
    assert "截断" in text  # 文案只断言关键词，避免与实现逐字绑定
