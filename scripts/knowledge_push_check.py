"""knowledge/ 目录改动是否推 git 的判定工具（2026-10-26 用户规则落地）。

规则（用户拍板）：
  - git diff 无改动 → 不推（肯定不用推）；
  - 有改动时按「最后操作时间」决定：文件 mtime 比 git 提交时间新 → 推；
    git 的提交时间更新或相等 → 不推（说明该状态已进提交/是 checkout 旧态）；
  - 磁盘上已不存在的改动 = 本地删除（改名时旧名也走这里）→ 推，git add 会暂存删除；
  - 未跟踪的新文件 → 推（视为新内容；.gitignore 覆盖的除外）。

用法：
  python scripts/knowledge_push_check.py            # 扫 knowledge/ 目录
  python scripts/knowledge_push_check.py --path X   # 扫指定目录
输出按「推 / 不推」分组，末尾给出可直接执行的 git add 命令。
自测：设环境变量 KNOWLEDGE_PUSH_REPO=<临时 git 仓库> 可把判定指向该仓库。
"""
import argparse
import os
import subprocess
import sys

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

REPO = os.environ.get("KNOWLEDGE_PUSH_REPO") or os.path.dirname(
    os.path.dirname(os.path.abspath(__file__))
)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", REPO, *args],
        capture_output=True, text=True, encoding="utf-8",
    ).stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser(description="按最后操作时间判定 knowledge 改动是否推 git")
    ap.add_argument("--path", default="knowledge", help="要扫描的目录（默认 knowledge）")
    args = ap.parse_args()

    base = os.path.join(REPO, args.path)
    if not os.path.isdir(base):
        print(f"目录不存在：{base}")
        return 1

    # 与 HEAD 有差异的文件 + 未跟踪文件。两条命令均 -c core.quotepath=false，
    # 让中文路径以 UTF-8 原样输出，避免 git 对非 ASCII 路径做 C 风格引号/八进制转义。
    # （不用 porcelain 行解析：其 XY 前缀列在部分状态下不可靠。）
    modified = git("-c", "core.quotepath=false", "diff", "--name-only", "HEAD", "--", args.path).splitlines()
    untracked = git("-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard", "--", args.path).splitlines()
    changed: dict[str, str] = {}  # 相对路径 -> 状态码（M/??）
    for rel in modified:
        if rel.strip():
            changed[rel.strip()] = "M"
    for rel in untracked:
        if rel.strip():
            changed[rel.strip()] = "??"

    if not changed:
        print(f"{args.path}/ 与 HEAD 无任何改动——不用推。")
        return 0

    push, skip = [], []
    for rel, code in sorted(changed.items()):
        if code == "??":
            push.append((rel, "未跟踪新文件"))
            continue
        abs_p = os.path.join(REPO, rel)
        if not os.path.exists(abs_p):
            # 磁盘上已不存在 = 本地删除（改名时旧名也走这里）：删除即最后操作，
            # 必然晚于该文件最近一次提交 → 推；git add 会暂存删除，配对新未跟踪文件即成改名
            push.append((rel, "本地已删除"))
            continue
        mtime = os.path.getmtime(abs_p)
        # :(literal) 关闭路径通配：文件名含 [*? 等字符仍按字面匹配
        git_t = git("log", "-1", "--format=%ct", "--", ":(literal)" + rel)
        if not git_t or not git_t.isdigit():
            # 查询失败时保守按推（文件确实与 HEAD 有差异），并标注原因
            push.append((rel, "git 时间不可得，保守按推"))
            continue
        git_time = float(git_t)
        if mtime > git_time:
            push.append((rel, f"mtime {mtime:.0f} > git {git_time:.0f}"))
        else:
            skip.append((rel, f"mtime {mtime:.0f} <= git {git_time:.0f}"))

    print(f"== 推（{len(push)} 个）==")
    for rel, why in push:
        print(f"  {rel}\t[{why}]")
    print(f"== 不推（{len(skip)} 个：git 时间更新/相等）==")
    for rel, why in skip:
        print(f"  {rel}\t[{why}]")
    if push:
        names = " ".join(f'"{r}"' for r, _ in push)
        print(f"\ngit add {names}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
