#!/usr/bin/env python3
"""校验 .xcstrings 的格式与某个语言的翻译质量（不参与 App 构建）。

检查项：
  1. JSON 合法，且按 Xcode 的格式（2 空格缩进、" : " 分隔符、保持原顺序）
     重新序列化后与原文件逐字节一致——不一致说明手工编辑引入了格式漂移，
     Xcode 下次保存会产生大面积 diff。
  2. 目标语言的占位符（%@、%d、%lld、%.1f、%1$@ …）与源语言逐一对应。
  3. 输出目标语言覆盖率，以及缺失翻译的键。

注意：这里只能校验格式，不能证明 Xcode 能编译通过。

用法：
  python3 tools/check_xcstrings.py [--lang zh-Hans] [--list-missing] [文件 ...]
默认检查 DynamicIsland/Localizable.xcstrings。
存在错误时退出码为 1。
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FILES = [ROOT / "DynamicIsland" / "Localizable.xcstrings"]

# printf 风格占位符：可选位置参数 n$，可选 flags/宽度/精度，长度修饰符，转换符
PLACEHOLDER = re.compile(
    r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])"
)


def placeholders(text: str) -> list[str]:
    """返回按参数位置排序的占位符类型列表，%% 不计入。"""
    text = text.replace("%%", "")
    found = []
    implicit = 0
    for match in PLACEHOLDER.finditer(text):
        position, length, conv = match.groups()
        if position is None:
            implicit += 1
            index = implicit
        else:
            index = int(position)
        kind = (length or "") + conv
        # %i 与 %d 等价；%ld/%lld 在 Swift 中都对应 Int
        kind = kind.replace("i", "d")
        found.append((index, kind))
    return [kind for _, kind in sorted(found)]


def iter_units(entry: dict, lang: str):
    """遍历某语言下的所有 stringUnit（包括复数/设备 variations）。"""
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return

    def walk(node, path):
        if isinstance(node, dict):
            if "stringUnit" in node:
                yield path, node["stringUnit"].get("value", "")
            for key, child in node.items():
                if key != "stringUnit":
                    yield from walk(child, path + [key])

    yield from walk(loc, [])


def source_text(key: str, entry: dict, source_lang: str, path: list) -> str:
    loc = entry.get("localizations", {}).get(source_lang)
    node = loc
    for part in path:
        if not isinstance(node, dict) or part not in node:
            node = None
            break
        node = node[part]
    if isinstance(node, dict) and "stringUnit" in node:
        return node["stringUnit"].get("value", key)
    if loc and "stringUnit" in loc:
        return loc["stringUnit"].get("value", key)
    return key


def check_file(path: Path, lang: str, list_missing: bool) -> int:
    errors = 0
    raw = path.read_text(encoding="utf-8")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"[错误] {path}: JSON 不合法: {exc}")
        return 1

    reserialized = json.dumps(data, ensure_ascii=False, indent=2, separators=(",", " : "))
    if raw.endswith("\n"):
        reserialized += "\n"
    if reserialized != raw:
        print(f"[警告] {path}: 与 Xcode 格式不一致（重新序列化后有差异），可能产生无关 diff")

    source_lang = data.get("sourceLanguage", "en")
    strings = data.get("strings", {})
    total = translatable = translated = 0
    missing = []

    for key, entry in strings.items():
        total += 1
        if entry.get("shouldTranslate") is False:
            continue
        translatable += 1
        units = list(iter_units(entry, lang))
        if not units:
            missing.append(key)
            continue
        translated += 1
        for unit_path, value in units:
            src = source_text(key, entry, source_lang, unit_path)
            want, got = placeholders(src), placeholders(value)
            # 复数 variation 的某些分支（如 one）允许省略数字占位符
            if want != got and not ("plural" in unit_path and set(got) <= set(want)):
                errors += 1
                where = "/".join(unit_path) or "-"
                print(f"[错误] 占位符不一致 [{where}] {key!r}\n       源: {want} {src!r}\n       译: {got} {value!r}")

    pct = (translated / translatable * 100) if translatable else 100.0
    print(f"{path.relative_to(ROOT)}: 键 {total}，需翻译 {translatable}，{lang} 已翻译 {translated}（{pct:.1f}%），缺失 {len(missing)}")
    if list_missing:
        for key in missing:
            print(f"  缺失: {key!r}")
    return 1 if errors else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument("--lang", default="zh-Hans")
    parser.add_argument("--list-missing", action="store_true")
    args = parser.parse_args()

    files = [f.resolve() for f in args.files] or DEFAULT_FILES
    status = 0
    for file in files:
        status |= check_file(file, args.lang, args.list_missing)
    return status


if __name__ == "__main__":
    sys.exit(main())
