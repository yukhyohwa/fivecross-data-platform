"""三模型报告配置：报告三模型（生成/验证/汇总）的读取与写入。

2026-10-26 起改为「模型管理」store（model_config.json）的适配器：
读写都落在 services/model_config 的统一 store（report_gen/report_ver/report_sum 槽位），
老 data_ai/report_config.json 由 model_config 首次读取时一次性迁移、之后不再参与解析。
本模块保留原有 read/write 函数签名与 /api/reports/config 端点兼容。

另含报告「展示折叠」配置的解析（parse_fold_config）：专项 skill.md 里写一段
「报告展示配置」，声明哪些章节默认展开 / 默认折叠，供前端渲染时精准折叠。
"""
import re


def read_report_config() -> dict:
    """返回报告三模型的生效模型（模型管理 > 环境变量 > 任务默认 > 系统默认）。

    老实现只返回「有覆盖的项或任务默认」；新实现等价地返回三槽位的生效解析值——
    调用方（report_analyze.run_three_model / services.report）直接取 cfg["model_*"] 使用。
    """
    from . import model_config
    return {
        "model_gen": model_config._resolve("report_gen")[0],
        "model_ver": model_config._resolve("report_ver")[0],
        "model_sum": model_config._resolve("report_sum")[0],
    }


def write_report_config(cfg: dict) -> None:
    """把报告三模型写入「模型管理」store（非法模型名/占位名由 model_config 写侧拦截）。"""
    from . import model_config
    model_config.write_model_config({
        "report_gen": (cfg.get("model_gen") or ""),
        "report_ver": (cfg.get("model_ver") or ""),
        "report_sum": (cfg.get("model_sum") or ""),
    })


def parse_fold_config(skill_text: str) -> dict | None:
    """从专项 skill.md 文本解析「报告展示配置」的默认折叠 / 展开章节。

    约定（写在 skill.md 里，机器解析，AI 不要照搬到报告正文）：
        - 默认展开：概览、明细下钻
        - 默认折叠：成因结论、预测

    每个值是锚定词，与报告章节标题做子串匹配（如「🔍 明细下钻 —— …」命中「明细下钻」）；
    命中「默认展开」→ 默认展开，命中「默认折叠」→ 默认折叠，都没命中 → 前端沿用原有默认行为。
    无这两行时返回 None（前端完全沿用现状，向后兼容）。
    """
    if not skill_text:
        return None
    expand: list[str] = []
    collapse: list[str] = []
    for raw in skill_text.splitlines():
        line = re.sub(r"[*_`]", "", raw).strip()
        if not line:
            continue
        line = line.lstrip("-•·").strip()
        for key, target in (("默认展开", expand), ("默认折叠", collapse)):
            # 只认「行首 = 默认展开/默认折叠」的配置行，避免正文里描述性文字（如
            # 「命中『默认展开』→ 默认展开…」）被误当成配置抓进来。
            if not line.startswith(key):
                continue
            rest = line[len(key):].strip().lstrip("：:").strip()
            if rest:
                target.extend(t for t in re.split(r"[、，,;；/|\s]+", rest) if t)
            break
    if expand or collapse:
        return {"expand": expand, "collapse": collapse}
    return None
