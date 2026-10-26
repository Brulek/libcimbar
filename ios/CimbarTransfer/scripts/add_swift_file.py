#!/usr/bin/env python3
"""把 App/ 下新建的 Swift 文件挂进 CimbarTransfer.xcodeproj。

不用 `xcodegen generate` 重建整个工程：重建会丢掉 knownRegions 里的 en，
英文本地化随之失效。这里只追加四处引用（BuildFile / FileReference /
App 分组 / Sources 阶段），其余内容原样保留。

用法：python3 scripts/add_swift_file.py Theme.swift [More.swift ...]
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


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    text = PBXPROJ.read_text()
    for name in sys.argv[1:]:
        text = add(text, name)
    PBXPROJ.write_text(text)


if __name__ == "__main__":
    main()
