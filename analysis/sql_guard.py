"""统一只读 SQL 安全闸门（单一事实来源）。

合并 data_ai 原 validate_sql 的规则（多语句检测、写关键字屏蔽、REPLACE INTO / 文件写出
拦截、长度护栏）与 sql-ide SqlSafetyGuard 的规则（只读类型白名单含 SHOW/EXPLAIN/DESCRIBE、
危险函数屏蔽），作为 data_ai 游戏库 SQL 执行前唯一的只读安全判断。

本模块只依赖标准库 re，不 import 业务模块（避免与 sql_rewriter 互相 import，也避免 db.py
拉进 ai_client/currency 等重依赖）。规则原语从 sql_rewriter.py 原样搬迁，逻辑不变。
"""
import re

# 允许的首语句类型（小写前缀）。validate_sql 收紧为 ("select", "with")；执行层用全量只读集合。
_ALLOWED_STMT_HEADS = ("select", "with", "show", "explain", "describe", "desc")

_BANNED_WORDS = re.compile(
    r"\b(insert|update|delete|drop|alter|truncate|create|grant|call|merge|"
    r"do|set|execute|prepare|deallocate|rename|revoke|analyze|optimize|flush)\b",
    re.IGNORECASE,
)
# MySQL 的 REPLACE INTO（写入语句）；REPLACE(str, from, to) 是纯函数，不拦
_REPLACE_INTO_RE = re.compile(r"\breplace\s+into\b", re.IGNORECASE)
# StarRocks/MySQL 的文件写出与批量导入：SELECT ... INTO OUTFILE / DUMPFILE、LOAD DATA [LOCAL] [INFILE]、BROKER/STREAM/ROUTINE LOAD
_FILE_WRITE_RE = re.compile(
    r"\b(into\s+(outfile|dumpfile)|load\s+data|broker\s+load|stream\s+load|routine\s+load)\b",
    re.IGNORECASE,
)
# 危险函数：只拦函数调用（`\s*(`），避免误伤同名列；INTO OUTFILE/DUMPFILE 已由 _FILE_WRITE_RE 覆盖
_BLOCKED_FUNCTIONS = re.compile(r"\b(sleep|benchmark|load_file)\s*\(", re.IGNORECASE)
_MAX_SQL_LENGTH = 20000


def _has_content_after(sql: str, start: int) -> bool:
    """从 start 位置起，跳过空白与注释（--、#、/* */，判定规则见 _first_code_pos），判断是否还有实质内容。"""
    return _first_code_pos(sql, start) < len(sql)


def _first_code_pos(sql: str, start: int = 0) -> int:
    """返回从 start 起第一条非空白、非注释（--、#、/* */）内容的起始下标；无内容返回 len(sql)。

    注释判定与 MySQL/StarRocks 词法一致：`--` 后必须跟空白/控制字符（或已到串尾）才算注释，
    `--x` 按普通字符处理（如 `a--b` 是合法算术）；`/*!` 开头的 MySQL 可执行版本注释当作代码
    而非注释（MySQL 服务端会真实执行其内容，不能跳过）。
    """
    i = start
    n = len(sql)
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
            continue
        # MySQL/StarRocks 词法：`--` 后跟空白/控制字符（或已到串尾）才是注释
        if c == "-" and i + 1 < n and sql[i + 1] == "-" and (i + 2 >= n or sql[i + 2].isspace()):
            j = sql.find("\n", i)
            if j == -1:
                return n
            i = j + 1
            continue
        if c == "#":
            j = sql.find("\n", i)
            if j == -1:
                return n
            i = j + 1
            continue
        # `/*!` 是可执行版本注释，当作代码不跳过（条件里排除 `/*!`）
        if c == "/" and i + 1 < n and sql[i + 1] == "*" and not (i + 2 < n and sql[i + 2] == "!"):
            j = sql.find("*/", i + 2)
            if j == -1:
                return n
            i = j + 2
            continue
        return i
    return n


def _has_multi_statement(sql: str) -> bool:
    """检测多语句：引号外的分号之后若还跟着非空白、非注释内容，视为多语句。

    注释判定与 MySQL/StarRocks 词法一致：`--` 后必须跟空白/控制字符（或已到串尾）才算注释，
    `--x` 按普通字符处理（如 `a--b` 是合法算术）；`/*!` 开头的 MySQL 可执行版本注释当作代码
    而非注释（MySQL 服务端会真实执行其内容，其中的 `;` 也参与多语句判定）。
    """
    i = 0
    n = len(sql)
    in_single = False
    in_double = False
    in_backtick = False
    while i < n:
        c = sql[i]
        if in_single:
            if c == "\\":
                i += 2
                continue
            if c == "'":
                in_single = False
            i += 1
            continue
        if in_double:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_double = False
            i += 1
            continue
        if in_backtick:
            # MySQL 反引号标识符内 `` 双写转义
            if c == "`":
                if i + 1 < n and sql[i + 1] == "`":
                    i += 2
                    continue
                in_backtick = False
            i += 1
            continue
        if c == "'":
            in_single = True
            i += 1
            continue
        if c == '"':
            in_double = True
            i += 1
            continue
        if c == "`":
            in_backtick = True
            i += 1
            continue
        # MySQL/StarRocks 词法：`--` 后跟空白/控制字符（或已到串尾）才是注释；`--x` 按普通字符处理
        if c == "-" and i + 1 < n and sql[i + 1] == "-" and (i + 2 >= n or sql[i + 2].isspace()):
            j = sql.find("\n", i)
            if j == -1:
                break
            i = j + 1
            continue
        if c == "#":
            j = sql.find("\n", i)
            if j == -1:
                break
            i = j + 1
            continue
        # `/*!` 是可执行版本注释，当作代码不跳过（条件里排除 `/*!`）
        if c == "/" and i + 1 < n and sql[i + 1] == "*" and not (i + 2 < n and sql[i + 2] == "!"):
            j = sql.find("*/", i + 2)
            if j == -1:
                break
            i = j + 2
            continue
        if c == ";":
            if _has_content_after(sql, i + 1):
                return True
        i += 1
    return False


def _code_only(sql: str) -> str:
    """返回「仅代码」视图：注释替换成空格、字符串字面量替换成占位符（'' / ""）。

    供写语句关键字扫描使用——避免把字符串字面量或注释里的 do/set/execute 等词误判为写语句
    （如 `where comment = 'do not set'` 或头部注释里的「执行计划」）。注释不整体删除而是替换成
    一个空格（保留 token 边界）：`INTO/**/OUTFILE` 这种注释拼接不能把两个代码 token 粘成
    `intooutfile` 绕过文件写出拦截，也不能把 `DR/**/OP` 粘成 `drop` 造成误拦。
    注释判定与 MySQL/StarRocks 词法一致：`--` 后必须跟空白/控制字符（或已到串尾）才算注释，
    `--x` 按普通字符处理（如 `a--b` 是合法算术）。`/*!` 开头的 MySQL 可执行版本注释在 MySQL
    服务端会被真实执行（可藏匿写语句/危险函数），代码区命中直接抛 ValueError。
    """
    out: list[str] = []
    i = 0
    n = len(sql)
    while i < n:
        c = sql[i]
        # MySQL/StarRocks 词法：`--` 后跟空白/控制字符（或已到串尾）才是注释
        if c == "-" and i + 1 < n and sql[i + 1] == "-" and (i + 2 >= n or sql[i + 2].isspace()):
            j = sql.find("\n", i)
            i = j + 1 if j != -1 else n
            out.append(" ")
            continue
        if c == "#":
            j = sql.find("\n", i)
            i = j + 1 if j != -1 else n
            out.append(" ")
            continue
        if c == "/" and i + 1 < n and sql[i + 1] == "*":
            if i + 2 < n and sql[i + 2] == "!":
                # MySQL 可执行版本注释 /*!...*/：内容会被 MySQL 服务端真实执行，
                # 不允许其混过只读闸门（无论版本号是否命中）
                raise ValueError("改写后的 SQL 包含 MySQL 可执行注释 /*!...*/，已拒绝")
            j = sql.find("*/", i + 2)
            i = j + 2 if j != -1 else n
            out.append(" ")
            continue
        if c == "'":
            out.append("''")
            i += 1
            while i < n:
                if sql[i] == "\\":
                    i += 2
                    continue
                if sql[i] == "'":
                    if i + 1 < n and sql[i + 1] == "'":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            continue
        if c == '"':
            out.append('""')
            i += 1
            while i < n:
                if sql[i] == "\\":
                    i += 2
                    continue
                if sql[i] == '"':
                    break
                i += 1
            i += 1
            continue
        if c == "`":
            # 反引号标识符（MySQL 表/列名）：整体替换成占位符，`` 双写转义
            out.append("``")
            i += 1
            while i < n:
                if sql[i] == "`":
                    if i + 1 < n and sql[i + 1] == "`":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def guard_readonly_sql(sql: str, allowed_heads=_ALLOWED_STMT_HEADS) -> str:
    """只读安全闸门：首语句类型白名单 + 写关键字/危险函数/文件写出屏蔽 + 多语句 + 长度护栏。

    allowed_heads 控制允许的首语句类型（小写前缀）；默认放行 SELECT/WITH/SHOW/EXPLAIN/DESCRIBE/DESC，
    LLM 生成路径可收紧为 ("select", "with")。通过返回 strip 后的 SQL；不通过抛 ValueError。
    """
    if not sql.strip():
        raise ValueError("改写后的 SQL 为空")
    # 允许 SQL 带结构化头部注释（--/ #/ /* */）；校验首语句时先跳过头部注释再判断类型
    code_head = re.sub(r"\s+", " ", sql[_first_code_pos(sql):]).strip().lower()
    # 词边界匹配（\b）：防 selectable/descent 等前缀误放行；alternation 按长度降序，
    # 保证 describe 先于 desc 匹配
    _head_re = re.compile(
        r"(?:" + "|".join(re.escape(h) for h in sorted(set(allowed_heads), key=len, reverse=True)) + r")\b"
    )
    if not _head_re.match(code_head):
        heads = " 或 ".join(h.upper() for h in allowed_heads)
        raise ValueError(f"改写后的 SQL 必须以 {heads} 开头（只读查询）")
    # 写语句关键字只扫「代码区」（去注释、去字符串字面量），避免误伤字符串/注释里的词。
    # 必须扫原始 SQL（不能先压空白）：`--` 行注释以换行结束，若先规范化，`SELECT 1\n-- c\nDROP` 的
    # 换行被压成空格后，注释会吞掉换行后的 DROP，绕过写关键字屏蔽
    code = _code_only(sql).lower()
    # SHOW CREATE TABLE/VIEW/... 是纯只读的 schema 探查语句（首语句白名单已放行 SHOW），
    # 其语法里的 create 不是写关键字；把 `show create` 整体替换成空后再扫写关键字避免误拦，
    # 其余位置的 create 仍照常拦截
    if _BANNED_WORDS.search(re.sub(r"\bshow\s+create\b", "", code)):
        raise ValueError("改写后的 SQL 包含写语句关键字，已拒绝")
    if _REPLACE_INTO_RE.search(code):
        raise ValueError("改写后的 SQL 包含 REPLACE INTO 写语句，已拒绝")
    if _FILE_WRITE_RE.search(code):
        raise ValueError("改写后的 SQL 包含 INTO OUTFILE / DUMPFILE / LOAD DATA 等文件写出或导入语句，已拒绝")
    if _BLOCKED_FUNCTIONS.search(code):
        raise ValueError("改写后的 SQL 包含危险函数（SLEEP/BENCHMARK/LOAD_FILE），已拒绝")
    if _has_multi_statement(sql):
        raise ValueError("改写后的 SQL 包含多条语句，已拒绝")
    if len(sql) > _MAX_SQL_LENGTH:
        raise ValueError(f"改写后的 SQL 过长（>{_MAX_SQL_LENGTH} 字符），已拒绝")
    return sql.strip()
