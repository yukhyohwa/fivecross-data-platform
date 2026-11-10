"""专项 / 快照「留痕编辑」工具：走 analysis 服务函数，与前端页面同一套写链路。

为什么用它而不是直接改磁盘文件：前端页面的「保存 / 快照编辑 / 刷新」最终都落在
analysis/knowledge_store.py 的服务函数上，这些函数做了两件留痕——
  1. 版本回滚：versioning.write_text 覆盖写前自动备份旧内容到 _versions/（7 天保留，可回滚）；
  2. 溯源三态：provenance.json 记录 follow（源与冻结一致）/ adapted（专项本地改编）/ drifted（源已改动）。
直接改文件会跳过 versioning，导致页面「快照与溯源」面板和版本历史与磁盘脱节。

用法（在 data_ai 根目录下运行）：
  python scripts/skill_edit.py status <专项名>
  python scripts/skill_edit.py edit-skill <专项名> <file>                  # 只改 skill.md 文本
  python scripts/skill_edit.py edit-snapshot <专项名> <kind> <key> <file>  # 只改冻结件 → 标 adapted
  python scripts/skill_edit.py edit-both <专项名> <kind> <key> <file>      # 改源+冻结同步 → 保持 follow

kind ∈ {sql, model, knowledge}；key 为冻结件名（sql 带 .sql、model 不带 .py、knowledge 为文档名）。
edit-snapshot = 前端「快照编辑」（本地改编，源不动）；edit-both = 改全局源并同步冻结（源仍是唯一事实）。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

# analysis/ 包已物理合并进 data_ai 根（与 data_ai/backend/config.py 注入一致）
_DATA_AI_ROOT = Path(__file__).resolve().parent.parent
if str(_DATA_AI_ROOT) not in sys.path:
    sys.path.insert(0, str(_DATA_AI_ROOT))

from analysis import code_store, knowledge_store as ks, sql_store, versioning
from analysis.snapshot import fingerprint

_KIND_SECTION = {"sql": "sql", "model": "models", "knowledge": "knowledge"}


def _read(path: str) -> str:
    p = Path(path)
    if not p.is_file():
        raise SystemExit(f"文件不存在：{path}")
    return p.read_text(encoding="utf-8")


def _write_follow_provenance(name: str, kind: str, key: str, content: str) -> None:
    """把溯源标为 follow（源与冻结同内容），刷新 fingerprint / content_fingerprint。"""
    section = _KIND_SECTION[kind]
    prov = ks.read_skill_provenance(name)
    fp = fingerprint(content)
    prov.setdefault(section, {})[key] = {
        "source": key,
        "fingerprint": fp,
        "mode": "follow",
        "content_fingerprint": fp,
    }
    ks.write_skill_provenance(name, prov)


def cmd_status(name: str) -> None:
    if not ks.is_skill_bundle(name):
        print(f"「{name}」不是目录打包形态（无快照），只有 skill.md 文本")
        return
    print("=== 三态溯源（skill_snapshot_states）===")
    for section, entries in ks.skill_snapshot_states(name).items():
        for key, st in entries.items():
            print(f"  [{section}] {key}: state={st['state']} mode={st['mode']} source={st.get('source') or '-'}")
    drift = ks.skill_drift(name)
    print(f"=== 漂移条目（源已改动需刷新）：{len(drift)} ===")
    for d in drift:
        print(f"  {d['kind']} {d['key']}: {d['state']} ({d['name']})")
    print("=== 版本留痕（_versions，每件最近 3 条）===")
    b = ks.SKILLS_DIR / name
    for section in ("sql", "models", "knowledge"):
        d = b / section
        if not d.is_dir():
            continue
        for f in sorted(d.iterdir()):
            if not f.is_file():
                continue
            vs = versioning.list_versions(f)
            print(f"  {section}/{f.name}: {len(vs)} 个版本")
            for v in vs[:3]:
                print(f"      {v['mtime_str']}  {v['file']}")


def cmd_edit_skill(name: str, path: str) -> None:
    ks.write_skill(name, _read(path))
    print(f"OK 已写 skill.md（versioned）：{name}")


def cmd_edit_snapshot(name: str, kind: str, key: str, path: str) -> None:
    text = _read(path)
    ks.write_skill_piece(name, kind, key, text)          # 版本备份
    ks.mark_skill_piece_adapted(name, kind, key, text)   # provenance 标 adapted
    print(f"OK 已改冻结件（adapted + versioned）：{name} {kind} {key}")


def cmd_edit_both(name: str, kind: str, key: str, path: str) -> None:
    text = _read(path)
    # 1) 写全局源（versioned）
    if kind == "sql":
        sql_store.write_sql(key, text)
    elif kind == "model":
        code_store.write_code(key, text)
    elif kind == "knowledge":
        ks.write_doc(key, text)
    else:
        raise SystemExit(f"未知 kind：{kind}（应为 sql / model / knowledge）")
    # 2) 写冻结快照（versioned）
    ks.write_skill_piece(name, kind, key, text)
    # 3) provenance 保持 follow（源与冻结同内容）
    _write_follow_provenance(name, kind, key, text)
    print(f"OK 已改源+冻结（follow + versioned）：{name} {kind} {key}")


def main() -> None:
    # 强制 UTF-8 输出（Windows 控制台默认 GBK 会乱码，中文键名无法读）
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8")
        except Exception:
            pass
    ap = argparse.ArgumentParser(description="专项/快照留痕编辑（走 analysis 服务函数，与前端同链路）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("status"); p.add_argument("name")
    p = sub.add_parser("edit-skill"); p.add_argument("name"); p.add_argument("file")
    p = sub.add_parser("edit-snapshot"); p.add_argument("name"); p.add_argument("kind"); p.add_argument("key"); p.add_argument("file")
    p = sub.add_parser("edit-both"); p.add_argument("name"); p.add_argument("kind"); p.add_argument("key"); p.add_argument("file")
    a = ap.parse_args()
    try:
        if a.cmd == "status":
            cmd_status(a.name)
        elif a.cmd == "edit-skill":
            cmd_edit_skill(a.name, a.file)
        elif a.cmd == "edit-snapshot":
            cmd_edit_snapshot(a.name, a.kind, a.key, a.file)
        elif a.cmd == "edit-both":
            cmd_edit_both(a.name, a.kind, a.key, a.file)
    except ValueError as exc:
        raise SystemExit(f"错误：{exc}")


if __name__ == "__main__":
    main()
