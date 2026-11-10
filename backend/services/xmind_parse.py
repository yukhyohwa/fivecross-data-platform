"""解析 .xmind 文件，抽取思维导图主题为大纲文本。

.xmind 本质是 zip 压缩包：
  - 新版（XMind 2020+ / Zen）内含 content.json（树状 JSON）
  - 旧版（XMind 8）内含 content.xml
这里两者都兼容，只抽取主题标题、按层级缩进成大纲（供 AI 汇总用，不还原样式/备注/图片）。
"""
import io
import json
import zipfile
import xml.etree.ElementTree as ET


def _walk_json(topic: dict, lines: list[str], depth: int) -> None:
    title = (topic.get("title") or "").strip()
    if title:
        lines.append("  " * depth + "- " + title)
    children = topic.get("children") or {}
    subs = list(children.get("attached") or []) + list(children.get("detached") or [])
    for c in subs:
        if isinstance(c, dict):
            _walk_json(c, lines, depth + 1)


def _parse_json(data: bytes) -> str:
    sheets = json.loads(data.decode("utf-8"))
    if isinstance(sheets, dict):
        sheets = [sheets]
    lines: list[str] = []
    for sheet in sheets:
        root = sheet.get("rootTopic") if isinstance(sheet, dict) else None
        if root:
            _walk_json(root, lines, 0)
    return "\n".join(lines)


def _walk_xml(topic, lines: list[str], depth: int) -> None:
    title_el = topic.find("title")
    title = (title_el.text or "").strip() if title_el is not None else ""
    if title:
        lines.append("  " * depth + "- " + title)
    children = topic.find("children")
    if children is not None:
        for topics in children.findall("topics"):
            for sub in topics.findall("topic"):
                _walk_xml(sub, lines, depth + 1)


def _parse_xml(data: bytes) -> str:
    root = ET.fromstring(data)
    for elem in root.iter():
        if "}" in elem.tag:  # 去掉命名空间前缀
            elem.tag = elem.tag.split("}", 1)[1]
    lines: list[str] = []
    for sheet in root.iter("sheet"):
        for topic in list(sheet):
            if topic.tag == "topic":
                _walk_xml(topic, lines, 0)
    return "\n".join(lines)


_MAX_MEMBER_BYTES = 20 * 1024 * 1024  # 单个成员解压后上限 20MB，防 zip 解压炸弹


def _read_limited(zf: zipfile.ZipFile, name: str) -> bytes:
    """限长读取 zip 成员：至多解压 _MAX_MEMBER_BYTES + 1 字节，超限即拒（防解压炸弹）。"""
    with zf.open(name) as f:
        data = f.read(_MAX_MEMBER_BYTES + 1)
    if len(data) > _MAX_MEMBER_BYTES:
        raise ValueError(f"文件成员「{name}」解压后超过 {_MAX_MEMBER_BYTES} 字节，已拒绝解析")
    return data


def parse(data: bytes) -> str:
    """data: .xmind 文件的原始字节。返回大纲文本。"""
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        raise ValueError("不是有效的 zip 文件（.xmind 应是 zip 包）")
    names = zf.namelist()
    if "content.json" in names:
        text = _parse_json(_read_limited(zf, "content.json"))
    elif "content.xml" in names:
        text = _parse_xml(_read_limited(zf, "content.xml"))
    else:
        raise ValueError("文件里找不到 content.json / content.xml，可能不是 XMind 导出文件")
    if not text.strip():
        raise ValueError("没有解析到任何主题内容")
    return text
