#!/bin/zsh
# zip 列表与 Office 文字提取的自测：生成各种测试文件，把 App/ZipListing.swift、App/SearchableText.swift
# 和 Tests/ParserSelfTest.swift 编译成 Mac 命令行程序运行。不需要模拟器。
set -euo pipefail

HERE=${0:A:h}
APP_ROOT=${HERE:h}
OUT=$APP_ROOT/build/parsertest
rm -rf $OUT; mkdir -p $OUT/files/src/子文件夹
cd $OUT/files

echo hello > src/a.txt
printf '%.0s0123456789' {1..1000} > src/子文件夹/数据.csv
touch src/.DS_Store
(cd src && ditto -c -k --sequesterRsrc --keepParent . ../mac.zip)
(cd src && zip -q -r -fz ../z64.zip . -x .DS_Store)
printf '季度汇报\n第一段：收入增长 12%%，A&B 公司 <重点>。\nSecond paragraph "quoted".\n' > doc.txt
textutil -convert docx doc.txt -output doc.docx
python3 - <<'PY'
import zipfile
# Windows 中文系统打的包：GBK 文件名、不标 UTF-8（先写同长度的占位名再替换字节）
with zipfile.ZipFile('gbk.zip', 'w') as z:
    z.writestr('ABCD.docx', b'x' * 1000)
    z.writestr('readme.txt', b'hi')
data = open('gbk.zip', 'rb').read().replace(b'ABCD.docx', '报告.docx'.encode('gbk'))
open('gbk.zip', 'wb').write(data)
with zipfile.ZipFile('comment.zip', 'w') as z:
    z.writestr('a.txt', 'a')
    z.comment = b'c' * 60000
open('bad.zip', 'wb').write(b'not a zip at all' * 10)
# 不压缩（存储）的条目：zip 和 docx 各一个
with zipfile.ZipFile('stored.zip', 'w', zipfile.ZIP_STORED) as z:
    z.writestr('folder/note.txt', '存储的条目\n')
with zipfile.ZipFile('stored.docx', 'w', zipfile.ZIP_STORED) as z:
    z.writestr('word/document.xml', '<w:document><w:body><w:p><w:r><w:t>不压缩的 Word</w:t></w:r></w:p></w:body></w:document>')
with zipfile.ZipFile('book.xlsx', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('xl/sharedStrings.xml', '<sst><si><t>客户名称</t></si><si><r><t xml:space="preserve">北京 </t></r>'
               '<r><t>分行</t></r></si><si><t>&#x4E2D;文&amp;符号</t></si></sst>')
with zipfile.ZipFile('deck.pptx', 'w', zipfile.ZIP_DEFLATED) as z:
    for n, t in [(1, '封面标题'), (10, '第十页'), (2, '第二页')]:
        z.writestr(f'ppt/slides/slide{n}.xml', f'<p:sld><a:p><a:r><a:t>{t}</a:t></a:r></a:p></p:sld>')
# 磁盘上 0.5 MB、解开 500 MB 的幻灯片
with zipfile.ZipFile('bomb.pptx', 'w', zipfile.ZIP_DEFLATED) as z:
    filler = ' ' * (10 * 1024 * 1024)
    for n in range(1, 51):
        z.writestr(f'ppt/slides/slide{n}.xml', f'<p:sld><a:p><a:r><a:t>页 {n}</a:t></a:r></a:p>{filler}</p:sld>')
PY

xcrun swiftc -O $APP_ROOT/App/ZipListing.swift $APP_ROOT/App/SearchableText.swift $APP_ROOT/Tests/ParserSelfTest.swift \
  -o $OUT/parser_selftest
$OUT/parser_selftest $OUT/files
