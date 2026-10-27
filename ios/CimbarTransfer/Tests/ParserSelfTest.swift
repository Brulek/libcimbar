// zip 列表与 Office 文字提取的自测：在 Mac 上编译运行（不需要模拟器），由 scripts/run_parser_selftest.sh 调用。
// 参数是测试文件所在目录，文件由脚本当场生成。
import Foundation

/// App 里 SearchableText 用到的文本读取；这里只测 zip 和 Office，留空即可
enum TextClipboard {
    static func readText(_ url: URL) -> String? { nil }
}

@main
enum ParserSelfTest {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "PASS" : "FAIL")  \(name)  \(detail)")
            if !ok { failures += 1 }
        }

        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

        if let listing = ZipListing.read(file("mac.zip")) {
            check("mac zip", listing.fileCount == 2 && !listing.names.contains { $0.contains("__MACOSX") || $0.hasSuffix(".DS_Store") },
                  "\(listing.fileCount) \(listing.names)")
        } else { check("mac zip", false, "nil") }

        let zip64 = ZipListing.read(file("z64.zip"))
        check("zip64", zip64?.fileCount == 2 && zip64?.totalSize == 10006, "\(String(describing: zip64))")

        let gbk = ZipListing.read(file("gbk.zip"))
        check("GBK names", gbk?.names.first == "报告.docx", "\(gbk?.names ?? [])")

        let huge = ZipListing.read(file("huge.zip"))
        check("huge declared sizes", huge?.fileCount == 2 && huge?.totalSize == .max, "\(String(describing: huge?.totalSize))")
        check("long comment", ZipListing.read(file("comment.zip"))?.fileCount == 1, "")
        check("not a zip", ZipListing.read(file("bad.zip")) == nil, "")

        let storedEntry = ZipArchive.entries(of: file("stored.zip"))?.first { $0.name == "folder/note.txt" }
        let storedData = storedEntry.flatMap { ZipArchive.data(of: $0, in: file("stored.zip"), maxSize: 1024) }
        check("stored entry", storedEntry?.method == 0 && storedData.map { String(decoding: $0, as: UTF8.self) } == "存储的条目\n",
              "\(String(describing: storedEntry?.method))")
        check("stored docx", OfficeText.read(file("stored.docx")) == "不压缩的 Word", "")
        let deflatedEntry = ZipArchive.entries(of: file("mac.zip"))?.first { $0.name.hasSuffix("数据.csv") }
        let deflatedData = deflatedEntry.flatMap { ZipArchive.data(of: $0, in: file("mac.zip"), maxSize: 1 << 20) }
        check("deflated entry", deflatedEntry?.method == 8 && deflatedData?.count == 10000, "\(String(describing: deflatedData?.count))")
        check("size cap", deflatedEntry.flatMap { ZipArchive.data(of: $0, in: file("mac.zip"), maxSize: 100) } == nil, "")

        let docx = OfficeText.read(file("doc.docx")) ?? ""
        check("docx", docx.contains("A&B 公司 <重点>") && docx.contains("Second paragraph \"quoted\"."), docx.debugDescription)

        let xlsx = OfficeText.read(file("book.xlsx")) ?? ""
        check("xlsx", xlsx == "项目名称\n上海 仓库\n中文&符号", xlsx.debugDescription)

        let inline = OfficeText.read(file("inline.xlsx")) ?? ""
        check("xlsx inline strings", inline == "导出的名单\n第二格\n第二张表", inline.debugDescription)

        let pptx = OfficeText.read(file("deck.pptx")) ?? ""
        check("pptx order", pptx.components(separatedBy: "\n").filter { $0.hasPrefix("第") || $0.hasPrefix("封") } == ["封面标题", "第二页", "第十页"],
              pptx.debugDescription)

        check("Word pages", OfficeText.count(file("pages.docx")) == .pages(12), "")
        check("no page count", OfficeText.count(file("doc.docx")) == nil, "")
        check("sheet count", OfficeText.count(file("sheets.xlsx")) == .sheets(3), "")
        check("slide count", OfficeText.count(file("deck.pptx")) == .slides(3), "")

        let start = Date()
        let bomb = OfficeText.read(file("bomb.pptx")) ?? ""
        let seconds = Date().timeIntervalSince(start)
        check("decompression budget", !bomb.contains("页 50") && seconds < 2, String(format: "%.2fs", seconds))

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
