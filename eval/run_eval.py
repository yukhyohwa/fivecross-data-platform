"""SQL 生成质量评估 / 回归：跑一批「问题 → 期望 SQL 特征」用例，检查生成结果。

用法（在 data_ai/ 下）：
    python -m eval.run_eval                  # 跑全部用例
    python -m eval.run_eval --only 充值      # 只跑 name 含该子串的用例
    python -m eval.run_eval --run-sql        # 额外把生成的 SQL 真跑一遍（需连库）

用例格式见 eval_cases.json：每条 {name, game, question, expect_keywords[], expect_sql?}。
通过标准：生成的 SQL 含全部 expect_keywords（大小写不敏感）；给定 expect_sql 时做归一化后包含匹配。
结果写 eval/report.json 并打印汇总。
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent                 # data_ai/eval
DATA_AI_ROOT = HERE.parent                               # data_ai（analysis 包 + backend 都在这里）
BACKEND_ROOT = HERE.parent                               # data_ai（使 `import backend.*` 可用）

# analysis 包已合并进 data_ai 根；data_ai 根同时提供 backend 的 config/schema_context
for p in (DATA_AI_ROOT, BACKEND_ROOT):
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from dotenv import load_dotenv  # noqa: E402

load_dotenv(DATA_AI_ROOT / ".env")

from backend import config  # noqa: E402
from backend.services import schema_context  # noqa: E402
from analysis import sql_gen  # noqa: E402


def _normalize(sql: str) -> str:
    return re.sub(r"\s+", " ", sql or "").strip().lower()


def load_cases(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data if isinstance(data, list) else data.get("cases", [])


def game_db(game_key: str) -> str:
    try:
        games = json.loads(config.GAMES_PATH.read_text(encoding="utf-8"))
        if isinstance(games, dict):
            games = games.get("games", [])
        for g in games:
            if g.get("key") == game_key:
                return g.get("db") or config.DEFAULT_TARGET_DB
    except Exception:
        pass
    return config.DEFAULT_TARGET_DB


def run_case(engine, model, case, run_sql: bool) -> dict:
    game_key = case.get("game") or "kof"
    question = case["question"]
    target_db = game_db(game_key)
    schema_text, ref_docs, _ = schema_context.build_sql_context(engine, target_db, game=game_key, question=question)
    doc_texts = [(name, text) for name, text in ref_docs]
    try:
        sql = sql_gen.generate_sql(model, schema_text, question, doc_texts, [], None)
    except Exception as e:  # noqa: BLE001 —— 单条失败不拖垮整批
        return {"name": case.get("name"), "status": "error", "detail": str(e)}

    norm = _normalize(sql)
    keywords = [str(k).lower() for k in case.get("expect_keywords", [])]
    missing = [k for k in keywords if k not in norm]
    checks = {"keywords_ok": not missing, "missing": missing}
    if case.get("expect_sql"):
        checks["sql_ok"] = _normalize(case["expect_sql"]) in norm

    executed = None
    if run_sql:
        from analysis.db import run_raw_sql
        from backend.services import games as games_svc
        try:
            df = run_raw_sql(engine, games_svc.apply_sql(sql, target_db))
            executed = {"ok": True, "rows": int(len(df))}
        except Exception as e:  # noqa: BLE001
            executed = {"ok": False, "detail": str(e)}

    passed = checks["keywords_ok"] and checks.get("sql_ok", True)
    return {
        "name": case.get("name") or question[:20],
        "game": game_key,
        "question": question,
        "status": "pass" if passed else "fail",
        "sql": sql,
        "checks": checks,
        "executed": executed,
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="只跑 name 含该子串的用例")
    ap.add_argument("--run-sql", action="store_true", help="额外真跑生成的 SQL（需连库）")
    ap.add_argument("--model", default="", help="模型名，缺省用 config.default_model()")
    ap.add_argument("--cases", default="", help="用例文件路径，缺省 eval/eval_cases.json")
    args = ap.parse_args()

    cases_path = Path(args.cases) if args.cases else HERE / "eval_cases.json"
    if not cases_path.exists():
        print(f"用例文件不存在：{cases_path}")
        sys.exit(1)
    cases = load_cases(cases_path)
    only = args.only.strip().lower()
    if only:
        cases = [c for c in cases if only in (c.get("name", "") or "").lower()]
    if not cases:
        print("没有匹配的用例")
        sys.exit(0)

    model = args.model or config.default_model()
    engine = config.build_engine()

    results = [run_case(engine, model, c, args.run_sql) for c in cases]
    passed = sum(1 for r in results if r["status"] == "pass")
    report = {
        "model": model,
        "total": len(results),
        "passed": passed,
        "failed": len(results) - passed,
        "results": results,
    }
    (HERE / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n===== SQL 评估：{passed}/{len(results)} 通过（模型 {model}）=====")
    for r in results:
        mark = "✅" if r["status"] == "pass" else "❌"
        line = f"{mark} [{r['name']}] {r['question']}"
        if r["status"] == "error":
            line += f"  —— 错误：{r['detail']}"
        elif r["status"] == "fail":
            detail = []
            if not r["checks"].get("keywords_ok"):
                detail.append("缺关键词: " + "、".join(r["checks"]["missing"]))
            if r["checks"].get("sql_ok") is False:
                detail.append("与期望 SQL 不符")
            line += "  —— " + "；".join(detail)
        if r.get("executed") is not None:
            e = r["executed"]
            line += f"  [执行: {'OK ' + str(e['rows']) + ' 行' if e['ok'] else '失败 ' + e['detail']}]"
        print(line)
    print(f"\n报告已写入 {HERE / 'report.json'}\n")


if __name__ == "__main__":
    main()
