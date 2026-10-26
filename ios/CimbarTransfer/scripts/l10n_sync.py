#!/usr/bin/env python3
"""核对 Localizable.xcstrings 与代码里实际用到的本地化键。

先用 SWIFT_EMIT_LOC_STRINGS=YES 编译一次（模拟器 Debug，DerivedData 在 build/），
编译器会为每个 Swift 文件产出 .stringsdata；ObjC++ 的 NSLocalizedString 由本脚本直接扫源码。

用法：
  python3 scripts/l10n_sync.py                 # 报告缺英文翻译的键和已不再使用的键
  python3 scripts/l10n_sync.py --apply en.json # 写入 {中文键: 英文} 翻译；值为 {"one":…,"other":…} 时写复数变体
  python3 scripts/l10n_sync.py --prune         # 删除代码里已不再使用的键
"""
import argparse
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Support" / "Localizable.xcstrings"
STRINGSDATA_DIR = (
    ROOT / "build" / "DerivedData" / "Build" / "Intermediates.noindex"
    / "CimbarTransfer.build" / "Debug-iphonesimulator" / "CimbarTransfer.build"
    / "Objects-normal" / "arm64"
)
OBJC_KEY = re.compile(r'NSLocalizedString\(@"((?:[^"\\]|\\.)*)"')


def used_keys() -> set[str]:
    files = list(STRINGSDATA_DIR.glob("*.stringsdata"))
    if not files:
        sys.exit(f"no .stringsdata under {STRINGSDATA_DIR}; build with SWIFT_EMIT_LOC_STRINGS=YES first")
    keys: set[str] = set()
    for path in files:
        data = json.loads(path.read_text())
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])
    for source in (ROOT / "App").glob("*.mm"):
        for match in OBJC_KEY.finditer(source.read_text()):
            keys.add(match.group(1).encode().decode("unicode_escape").encode("latin1").decode("utf-8"))
    return keys


def has_english(entry: dict) -> bool:
    en = entry.get("localizations", {}).get("en", {})
    return bool(en.get("stringUnit", {}).get("value")) or "variations" in en


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", type=pathlib.Path)
    parser.add_argument("--prune", action="store_true")
    args = parser.parse_args()

    catalog = json.loads(CATALOG.read_text())
    strings: dict = catalog["strings"]
    keys = used_keys()

    if args.apply:
        translations = json.loads(args.apply.read_text())
        for key, value in translations.items():
            entry = strings.setdefault(key, {})
            if isinstance(value, dict):
                # {"one": ..., "other": ...} 写成复数变体
                entry.setdefault("localizations", {})["en"] = {
                    "variations": {"plural": {
                        form: {"stringUnit": {"state": "translated", "value": text}}
                        for form, text in value.items()
                    }}
                }
            else:
                entry.setdefault("localizations", {})["en"] = {
                    "stringUnit": {"state": "translated", "value": value}
                }

    unused = sorted(k for k in strings if k not in keys and k != "")
    if args.prune and len(unused) > len(strings) // 2:
        # 多半是上次编译没开 SWIFT_EMIT_LOC_STRINGS，.stringsdata 不全
        sys.exit(f"refusing to prune {len(unused)} of {len(strings)} keys; rebuild with SWIFT_EMIT_LOC_STRINGS=YES")
    if args.prune:
        for key in unused:
            del strings[key]
        unused = []

    for key in keys:
        # 代码里在用的键不该挂着 stale 标记
        if key in strings and strings[key].get("extractionState") == "stale":
            del strings[key]["extractionState"]

    if args.apply or args.prune:
        catalog["strings"] = dict(sorted(strings.items()))
        CATALOG.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : ")) + "\n")

    missing = sorted(k for k in keys if k not in strings or not has_english(strings[k]))
    print(f"used keys: {len(keys)}  catalog: {len(strings)}")
    print(f"\nmissing English ({len(missing)}):")
    for key in missing:
        print(f"  {json.dumps(key, ensure_ascii=False)}")
    print(f"\nunused ({len(unused)}):")
    for key in unused:
        print(f"  {json.dumps(key, ensure_ascii=False)}")


if __name__ == "__main__":
    main()
