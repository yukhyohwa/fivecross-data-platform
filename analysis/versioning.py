"""文件版本化回滚：覆盖写前自动备份旧内容到 _versions/，保留最近 N 天。

镜像规则：_versions/<原文件相对 PROJECT_ROOT 的路径>/<时间戳>_<指纹8>.<后缀>
- snapshot()：写前调用，把当前内容备份成带时间戳 + 内容指纹的版本文件。
- prune()：清理超过保留期的版本。
- restore()：把某个版本文件拷回目标（回滚本身也先备份当前，可再反悔）。
- list_versions()：按时间倒序列出某文件的全部版本。
- diff_version()：「版本 vs 当前」统一 diff（P1-16 版本对比）。

版本库放在 _versions/ 下、与检索/列表目录（sql/ knowledge/ code/）完全隔离，
不会进 TF-IDF 索引，也不会被 list_* 扫到。
"""
import difflib
import hashlib
import os
import shutil
import time
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
VERSIONS_DIR = PROJECT_ROOT / "_versions"

RETENTION_DAYS = 30  # 2026-10-21 由 7 天提到 30 天（用户拍板：误操作宽限期 7 天太短）
_SECONDS_PER_DAY = 86400


def _fp8(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()[:8]


def _versions_subdir(target: Path) -> Path:
    """目标文件在 _versions/ 下的镜像目录（镜像其相对 PROJECT_ROOT 的路径）。"""
    try:
        rel = target.resolve().relative_to(PROJECT_ROOT.resolve())
    except ValueError:
        rel = Path(target.name)
    return VERSIONS_DIR / rel


def snapshot(target: Path) -> None:
    """把 target 当前内容备份进版本库。不存在或与最新版本内容一致则跳过。"""
    if not target.is_file():
        return
    data = target.read_bytes()
    vdir = _versions_subdir(target)
    vdir.mkdir(parents=True, exist_ok=True)
    prev = sorted(vdir.glob("*" + target.suffix))
    if prev and prev[-1].read_bytes() == data:
        return  # 与最近一个版本内容相同，不重复备份
    ts = time.strftime("%Y%m%d_%H%M%S")
    dest = vdir / f"{ts}_{_fp8(data)}{target.suffix}"
    if dest.exists():
        return
    # 用 copy（非 copy2）：版本文件 mtime = 备份时刻，供 7 天保留期按「何时被替换」计算。
    shutil.copy(target, dest)
    prune(target)


def prune(target: Path, days: int = RETENTION_DAYS) -> None:
    """删除超过保留期的版本文件。"""
    vdir = _versions_subdir(target)
    if not vdir.is_dir():
        return
    cutoff = time.time() - days * _SECONDS_PER_DAY
    for vf in vdir.iterdir():
        try:
            if vf.is_file() and vf.stat().st_mtime < cutoff:
                vf.unlink()
        except OSError:
            pass


def list_versions(target: Path) -> list[dict]:
    """按时间倒序列出某文件的版本（每项含文件名/大小/可读时间）。"""
    vdir = _versions_subdir(target)
    if not vdir.is_dir():
        return []
    out = []
    for vf in sorted(vdir.glob("*" + target.suffix), reverse=True):
        st = vf.stat()
        out.append({
            "file": vf.name,
            "size": st.st_size,
            "mtime": st.st_mtime,
            "mtime_str": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(st.st_mtime)),
        })
    return out


def restore(target: Path, version_file: str) -> bool:
    """把指定版本文件回滚到 target。回滚前先备份当前，避免误操作不可逆。"""
    vdir = _versions_subdir(target)
    vf = (vdir / version_file).resolve()
    # 防路径穿越：解析后的版本文件必须仍落在目标版本目录内，拒绝 ../../ 读取任意文件。
    try:
        vf.relative_to(vdir.resolve())
    except ValueError:
        return False
    if not vf.is_file():
        return False
    snapshot(target)
    shutil.copy(vf, target)
    return True


# diff 单侧读取上限：超过截断并标注，防超大工件把对比接口响应撑爆（P1-16）。
_DIFF_MAX_BYTES = 512 * 1024


def _diff_lines(data: bytes) -> tuple[list[str], bool]:
    """按行拆分（任意编码容错），超过 _DIFF_MAX_BYTES 截断。返回 (行列表, 是否截断)。"""
    truncated = len(data) > _DIFF_MAX_BYTES
    text = data[:_DIFF_MAX_BYTES].decode("utf-8", errors="replace")
    return text.splitlines(), truncated


def diff_version(target: Path, version_file: str) -> tuple[str, bool] | None:
    """「版本 vs 当前内容」统一 diff（P1-16）：- 行 = 历史版本，+ 行 = 当前。
    版本文件不存在/路径越界返回 None；返回 (diff 文本, 是否截断)。"""
    vdir = _versions_subdir(target)
    vf = (vdir / version_file).resolve()
    try:
        vf.relative_to(vdir.resolve())
    except ValueError:
        return None  # 防路径穿越：与 restore 同口径
    if not vf.is_file():
        return None
    old_lines, old_trunc = _diff_lines(vf.read_bytes())
    new_lines, new_trunc = _diff_lines(target.read_bytes() if target.is_file() else b"")
    diff = list(difflib.unified_diff(
        old_lines, new_lines, fromfile=f"版本 {version_file}", tofile="当前", lineterm=""))
    body = "\n".join(diff)
    if old_trunc or new_trunc:
        body += "\n…（文件过大，diff 已截断）"
    return body, old_trunc or new_trunc


def write_text(target: Path, text: str, **kw) -> None:
    """带版本备份的 write_text：先 snapshot，再写临时文件后原子替换，避免中途崩溃留半截文件。"""
    snapshot(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(text, **kw)
    os.replace(tmp, target)


# ── 删除侧版本化（审计建议 1，2026-10-21） ─────────────────────────

def delete_text(target: Path) -> None:
    """删除前自动快照：不存在则跳过，存在则先 snapshot 再删除。
    版本镜像保留在 _versions——源文件删除后 restore() 仍可从镜像重建（回收站底座）。"""
    if not target.is_file():
        return
    snapshot(target)
    target.unlink()


def delete_tree(target: Path) -> None:
    """整目录删除前逐文件快照（专项目录打包形态：skill.md/meta.json/run.json/
    provenance.json/sql/*/models/*/knowledge/*），再 rmtree——目录内每个文件
    在 _versions 都有版本，可逐件 restore。"""
    if not target.is_dir():
        return
    for p in sorted(target.rglob("*")):
        if p.is_file():
            snapshot(p)
    shutil.rmtree(target)


def _prune_dir(vdir: Path, days: int = RETENTION_DAYS) -> None:
    """清理单个镜像目录里超过保留期的版本（prune 的目录版，供回收站按需清理）。"""
    cutoff = time.time() - days * _SECONDS_PER_DAY
    for vf in list(vdir.iterdir()):
        try:
            if vf.is_file() and vf.stat().st_mtime < cutoff:
                vf.unlink()
        except OSError:
            pass


def list_deleted() -> list[dict]:
    """回收站（审计建议 8）：列出源文件已不存在、镜像目录仍有版本的「已删工件」。
    顺带对每个镜像目录做保留期清理——已删工件的可恢复窗口与版本保留期（30 天）天然一致。"""
    out = []
    for vdir in sorted(VERSIONS_DIR.rglob("*")):
        if not vdir.is_dir():
            continue
        vs = [p for p in vdir.iterdir() if p.is_file()]
        if not vs:
            continue
        rel = vdir.relative_to(VERSIONS_DIR)
        if (PROJECT_ROOT / rel).is_file():
            continue  # 源仍在，不是已删工件
        _prune_dir(vdir)
        vs = [p for p in vdir.iterdir() if p.is_file()]
        if not vs:
            continue  # 全部超期已清，不再列出
        latest = sorted(vs, key=lambda p: p.stat().st_mtime, reverse=True)[0].stat()
        out.append({
            "rel": str(rel).replace("\\", "/"),
            "versions": len(vs),
            "latest_mtime": latest.st_mtime,
            "latest_str": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(latest.st_mtime)),
        })
    out.sort(key=lambda x: -x["latest_mtime"])
    return out


def purge_versions(target: Path) -> int:
    """永久删除某源路径的全部版本（回收站「彻底删除」，不可恢复）。返回删除的版本数。

    防御（对抗审查）：只有「自身就是版本目录（含版本文件、无子目录）」才整目录删除——
    rel 指到中间镜像目录（如 sql/）时 rmtree 会把整棵版本树连根删掉；无版本文件时
    同样不删（空镜像目录壳由 list_deleted 的 prune 自然清空）。
    """
    vdir = _versions_subdir(target)
    if not vdir.is_dir():
        return 0
    entries = list(vdir.iterdir())
    if not entries:
        return 0
    if any(p.is_dir() for p in entries):
        return 0  # 中间目录（含子镜像目录），拒绝整树删除
    n = sum(1 for p in entries if p.is_file())
    if n == 0:
        return 0
    shutil.rmtree(vdir, ignore_errors=True)
    return n
