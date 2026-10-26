#!/usr/bin/env python3
"""把 App/ 下新建的 Swift 文件挂进 CimbarTransfer.xcodeproj。

不用 `xcodegen generate` 重建整个工程：重建会丢掉 knownRegions 里的 en，
英文本地化随之失效。这里只追加四处引用（BuildFile / FileReference /
App 分组 / Sources 阶段），其余内容原样保留。

用法：python3 scripts/add_swift_file.py Theme.swift [More.swift ...]
      python3 scripts/add_swift_file.py --resource PrivacyInfo.xcprivacy      # Support/ 下的资源文件
      python3 scripts/add_swift_file.py --localized AppShortcuts.strings     # Support/<语言>.lproj/ 下的本地化文件
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "CimbarTransfer.xcodeproj" / "project.pbxproj"


def make_id(seed: str) -> str:
    return hashlib.sha1(seed.encode()).hexdigest()[:24].upper()


def add(text: str, name: str) -> str:
    if f"/* {name} */ = {{isa = PBXFileReference" in text:
        print(f"skip {name}: already in project")
        return text
    if not (ROOT / "App" / name).exists():
        sys.exit(f"App/{name} does not exist")

    file_ref = make_id(f"ref:{name}")
    build_file = make_id(f"build:{name}")

    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{build_file} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};\n",
        1,
    )
    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        f"\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n",
        1,
    )

    group = re.search(r"/\* App \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n", text)
    if not group:
        sys.exit("App group not found")
    text = text[: group.end()] + f"\t\t\t\t{file_ref} /* {name} */,\n" + text[group.end():]

    sources = re.search(
        r"isa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n", text
    )
    if not sources:
        sys.exit("Sources build phase not found")
    text = text[: sources.end()] + f"\t\t\t\t{build_file} /* {name} in Sources */,\n" + text[sources.end():]

    print(f"added {name}")
    return text


RESOURCE_TYPES = {".xcstrings": "text.json.xcstrings", ".json": "text.json", ".png": "image.png", ".strings": "text.plist.strings"}


def add_resource(text: str, name: str) -> str:
    if f"/* {name} */ = {{isa = PBXFileReference" in text:
        print(f"skip {name}: already in project")
        return text
    if not (ROOT / "Support" / name).exists():
        sys.exit(f"Support/{name} does not exist")
    file_type = RESOURCE_TYPES.get(pathlib.Path(name).suffix)
    if not file_type:
        sys.exit(f"unknown resource type for {name}")

    file_ref = make_id(f"ref:{name}")
    build_file = make_id(f"build:{name}")
    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{build_file} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_ref} /* {name} */; }};\n",
        1,
    )
    # 与现有 InfoPlist.xcstrings 的写法一致：相对 SOURCE_ROOT 的完整路径
    text = text.replace(
        "/* Begin PBXFileReference section */\n",
        "/* Begin PBXFileReference section */\n"
        f"\t\t{file_ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; name = {name}; path = Support/{name}; sourceTree = SOURCE_ROOT; }};\n",
        1,
    )
    group = re.search(r"/\* Support \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n", text)
    if not group:
        sys.exit("Support group not found")
    text = text[: group.end()] + f"\t\t\t\t{file_ref} /* {name} */,\n" + text[group.end():]
    resources = re.search(
        r"isa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n", text
    )
    if not resources:
        sys.exit("Resources build phase not found")
    text = text[: resources.end()] + f"\t\t\t\t{build_file} /* {name} in Resources */,\n" + text[resources.end():]
    print(f"added resource {name}")
    return text


def add_localized(text: str, name: str) -> str:
    """Support/<lang>.lproj/<name> 挂成一个 PBXVariantGroup（iOS 16 用不了 AppShortcuts.xcstrings）"""
    if f"/* {name} */ = {{\n\t\t\tisa = PBXVariantGroup;" in text:
        print(f"skip {name}: already in project")
        return text
    languages = sorted(d.name[: -len(".lproj")] for d in (ROOT / "Support").glob("*.lproj") if (d / name).exists())
    if not languages:
        sys.exit(f"no Support/*.lproj/{name}")
    file_type = RESOURCE_TYPES.get(pathlib.Path(name).suffix, "text")

    group_id = make_id(f"variant:{name}")
    build_file = make_id(f"build:{name}")
    refs = {lang: make_id(f"ref:{lang}:{name}") for lang in languages}

    text = text.replace(
        "/* Begin PBXBuildFile section */\n",
        "/* Begin PBXBuildFile section */\n"
        f"\t\t{build_file} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {group_id} /* {name} */; }};\n",
        1,
    )
    ref_lines = "".join(
        f"\t\t{ref} /* {lang} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; name = {lang}; path = {lang}.lproj/{name}; sourceTree = \"<group>\"; }};\n"
        for lang, ref in refs.items()
    )
    text = text.replace("/* Begin PBXFileReference section */\n", "/* Begin PBXFileReference section */\n" + ref_lines, 1)

    children = "".join(f"\t\t\t\t{ref} /* {lang} */,\n" for lang, ref in refs.items())
    variant = (
        f"\t\t{group_id} /* {name} */ = {{\n\t\t\tisa = PBXVariantGroup;\n\t\t\tchildren = (\n{children}\t\t\t);\n"
        f"\t\t\tname = {name};\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n"
    )
    if "/* Begin PBXVariantGroup section */\n" in text:
        text = text.replace("/* Begin PBXVariantGroup section */\n", "/* Begin PBXVariantGroup section */\n" + variant, 1)
    else:
        text = text.replace(
            "/* Begin XCBuildConfiguration section */",
            f"/* Begin PBXVariantGroup section */\n{variant}/* End PBXVariantGroup section */\n\n/* Begin XCBuildConfiguration section */",
            1,
        )

    group = re.search(r"/\* Support \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n", text)
    if not group:
        sys.exit("Support group not found")
    text = text[: group.end()] + f"\t\t\t\t{group_id} /* {name} */,\n" + text[group.end():]
    resources = re.search(
        r"isa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n", text
    )
    if not resources:
        sys.exit("Resources build phase not found")
    text = text[: resources.end()] + f"\t\t\t\t{build_file} /* {name} in Resources */,\n" + text[resources.end():]
    print(f"added localized {name} ({', '.join(languages)})")
    return text


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    text = PBXPROJ.read_text()
    args = sys.argv[1:]
    if args[0] == "--resource":
        for name in args[1:]:
            text = add_resource(text, name)
    elif args[0] == "--localized":
        for name in args[1:]:
            text = add_localized(text, name)
    else:
        for name in args:
            text = add(text, name)
    PBXPROJ.write_text(text)


if __name__ == "__main__":
    main()
