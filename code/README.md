# 专项关联代码（数据预测等）

本目录存放与「专项（Skill）」关联的 Python 代码。约定：

- **文件命名**：`<专项名>.py`，与 `knowledge/skills/<专项名>.md` **同名**，即自动关联到对应专项。
  例如专项 `流水达成分析专项` 对应的预测代码就是 `code/流水达成分析专项.py`。
- **层级继承**：代码层级随专项（通用 / 项目 / 个人）继承，本目录不再单独存 meta。
- **读取方式**：`analysis/code_store.code_for_skill(skill_name)` 拿文件名，
  `analysis/code_store.read_code(name)` 读内容；两者都在 `analysis/` 包内。

## 预期的代码契约（将来做数据预测时）

每个预测 `.py` 建议暴露一个标准入口函数，便于 chat / 报告流水线在拿到查询结果后调用：

```python
# code/流水达成分析专项.py
def predict(df, **ctx):
    """输入查询结果 DataFrame，输出预测结果。

    返回可以是：
    - pd.DataFrame：追加到报告「预测结果」一栏；
    - dict / markdown 字符串：作为预测结论拼进报告正文。
    ctx 里会带 {game_key, question, ...} 等上下文。
    """
    ...
```

> 当前流水线**尚未**自动执行这里的代码；`code_store` 已就绪，接入执行时只需：
> 1. 命中专项后 `code_store.code_for_skill(skill)` 判断是否有预测代码；
> 2. 查询结果 `primary_df` 就绪后 `importlib` / 动态加载该 `.py` 并调用 `predict(primary_df, ...)`；
> 3. 把预测结果作为新事件（如 `predict`）推给前端，或在分析阶段拼进参考文本。
