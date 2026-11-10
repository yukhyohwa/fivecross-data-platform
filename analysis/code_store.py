"""专项关联的 Python 代码（数据预测等）的文件系统 CRUD。

约定：code/<专项名>.py 与 knowledge/skills/<专项名>.md 同名，即自动关联到对应专项。
层级（通用/项目/个人）随专项继承，无需单独的 meta 文件——专项能看到的代码，
只有它自己的那份。

代码文件本身不在此模块里执行；这里只负责「在哪、有哪些、怎么读」。
将来做数据预测时，由 chat / report 流水线调用 code_for_skill() 拿到文件名，
再 read_code() 读入后在查询结果 DataFrame 上执行。
"""
import json
import os
import re
from pathlib import Path

from . import versioning

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CODE_DIR = PROJECT_ROOT / "code"

CODE_DIR.mkdir(parents=True, exist_ok=True)

_INVALID_NAME_CHARS = re.compile(r'[\\/:*?"<>|]')


def _validate_name(name: str) -> str:
    name = (name or "").strip()
    if not name:
        raise ValueError("名称不能为空")
    if _INVALID_NAME_CHARS.search(name) or name in (".", ".."):
        raise ValueError(f"名称包含非法字符：{name}")
    return name


def _with_ext(name: str) -> str:
    name = _validate_name(name)
    return name if name.endswith(".py") else name + ".py"


def list_code_files() -> list[str]:
    """列出全部代码文件名（含 .py 后缀），按名排序。"""
    return sorted(p.name for p in CODE_DIR.glob("*.py"))


def read_code(name: str) -> str:
    """读取 .py 文件文本；不存在返回空串。name 可带可不带 .py 后缀。"""
    path = CODE_DIR / _with_ext(name)
    return path.read_text(encoding="utf-8") if path.exists() else ""


def write_code(name: str, text: str) -> None:
    """写 .py 文件（\\r\\n → \\n 归一化）。"""
    versioning.write_text(
        CODE_DIR / _with_ext(name), text.replace("\r\n", "\n"), encoding="utf-8", newline="\n"
    )


def delete_code(name: str) -> None:
    """删除 .py 文件及同名 manifest/冻结 SQL（删除前自动进版本库，可回收站恢复）；
    不存在则忽略。"""
    versioning.delete_text(CODE_DIR / _with_ext(name))
    versioning.delete_text(_code_meta_path(name))
    versioning.delete_text(_model_sql_path(name))


def rename_code(old: str, new: str) -> None:
    """原子重命名模型代码（审计建议 7）：.py 主件 + manifest（.py.json）+ 冻结 SQL
    （.sql）+ _versions 镜像一并迁移，不再靠前端「存新名+删旧名」两段式丢版本历史。

    与 rename_skill/rename_doc/rename_sql 同构：先全量存在性检查（目标占用抛
    ValueError），再逐项 os.replace（同卷原子），最后新名 snapshot 留痕。
    """
    old = _with_ext(old)
    new = _with_ext(new)
    if old == new:
        return
    if new in list_code_files():
        raise ValueError(f"目标代码「{new}」已存在，请换一个名称")
    if not (CODE_DIR / old).exists():
        raise ValueError(f"代码「{old}」不存在")
    old_stem, new_stem = old[: -len(".py")], new[: -len(".py")]
    vroot = versioning.VERSIONS_DIR / CODE_DIR.relative_to(versioning.PROJECT_ROOT)
    # 目标残留预检（对抗审查）：镜像目标被回收站残留占用时，磁盘改名已发生而镜像
    # os.replace 崩溃 → 半迁移。先拦，提示去回收站处理。
    for p in (
        _code_meta_path(new), _model_sql_path(new_stem),
        vroot / f"{new_stem}.py", vroot / f"{new_stem}.py.json", vroot / f"{new_stem}.sql",
    ):
        if p.exists():
            raise ValueError(
                f"目标代码「{new}」存在残留（元数据/冻结 SQL/回收站历史），请先在回收站恢复或彻底删除")
    for src, dst in (
        (CODE_DIR / old, CODE_DIR / new),
        (_code_meta_path(old), _code_meta_path(new)),
        (_model_sql_path(old_stem), _model_sql_path(new_stem)),
    ):
        if not src.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)
    for suffix in (".py", ".py.json", ".sql"):
        src, dst = vroot / f"{old_stem}{suffix}", vroot / f"{new_stem}{suffix}"
        if not src.exists():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)
    versioning.snapshot(CODE_DIR / new)


# ---- 模型专属修改 SQL（code/<名>.sql）：生成模型时对绑定取数 SQL 改造后冻结 ----

def _model_sql_path(name: str) -> Path:
    """返回模型专属冻结 SQL 路径 code/<裸名>.sql（与 .py 同级，随 versioning 版本化）。"""
    stem = _validate_name(name)
    if stem.endswith(".py"):
        stem = stem[:-3]
    return CODE_DIR / f"{stem}.sql"


def read_model_sql(name: str) -> str:
    """读模型专属冻结 SQL；不存在返回空串。name 可带/不带 .py 后缀。"""
    path = _model_sql_path(name)
    return path.read_text(encoding="utf-8") if path.exists() else ""


def write_model_sql(name: str, text: str) -> None:
    """写模型专属冻结 SQL（\r\n → \n 归一化，随版本化快照）。"""
    versioning.write_text(
        _model_sql_path(name), text.replace("\r\n", "\n"), encoding="utf-8", newline="\n"
    )


def delete_model_sql(name: str) -> None:
    """删除模型专属冻结 SQL（删除前自动进版本库，可回收站恢复）；不存在则忽略。"""
    versioning.delete_text(_model_sql_path(name))


# ---- 模型代码 manifest（code/<名>.py.json）：注册成 forecast 能力的元数据 ----

def _code_meta_path(name: str) -> Path:
    """返回 <名>.py.json 路径（与 SQL 的 <名>.sql.json 同构）。"""
    return CODE_DIR / f"{_with_ext(name)}.json"


def read_code_meta(name: str) -> dict:
    """读模型 manifest（code/<名>.py.json）；缺文件/损坏返回空 dict。

    返回结构：{"name","desc","input","granularity","sql","hist_days"/"hist_months",
              "horizon_days"/"horizon_months","window","level","game"}（与 forecast 能力项同键、去 func）。
    """
    path = _code_meta_path(name)
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def write_code_meta(name: str, meta: dict) -> None:
    """写模型 manifest（utf-8，ensure_ascii=False，缩进 2，随版本化留痕）。"""
    versioning.write_text(
        _code_meta_path(name),
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8",
        newline="\n",
    )


def list_code_manifests() -> list[str]:
    """列出有 manifest 的代码文件名（含 .py 后缀），按名排序。"""
    return sorted(p.name[: -len(".json")] for p in CODE_DIR.glob("*.py.json"))


def code_for_skill(skill_name: str) -> str:
    """返回专项同名代码文件名（不含 .py），不存在返回 ""。"""
    try:
        name = _validate_name(skill_name)
    except ValueError:
        return ""
    return name if (CODE_DIR / f"{name}.py").exists() else ""
