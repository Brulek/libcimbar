import Foundation
import PDFKit

/// 「我的文件」按内容搜索时读出的文字：小文本全文、PDF 前几页的文字、Word/PowerPoint/Excel 里的文字、zip 里的文件名
enum SearchableText {
    /// 每个文件只索引开头 10 万字：过滤在主线程上、每敲一个字跑一遍，几十个大文件全文会卡
    static let maxCharacters = 100_000
    /// PDF 只读前 20 页、20 MB 以内：报告、发票、合同的关键内容一般在前面，扫描件也没有文字可读
    static let maxPDFPages = 20
    static let maxPDFBytes: Int64 = 20 * 1024 * 1024

    /// Word / PowerPoint / Excel：读得出文字（见 OfficeText）
    static let officeExtensions: Set<String> = ["docx", "pptx", "xlsx"]

    static func isOfficeDocument(_ fileExtension: String) -> Bool {
        officeExtensions.contains(fileExtension.lowercased())
    }

    /// 小文本以外能按内容搜的：PDF、Office 文档（有大小上限）和 zip（只读末尾的文件名列表，多大都行）
    static func canIndexDocument(fileExtension: String, size: Int64) -> Bool {
        let ext = fileExtension.lowercased()
        if ext == "zip" { return size > 0 }
        return (ext == "pdf" || isOfficeDocument(ext)) && size > 0 && size <= maxPDFBytes
    }

    /// 后台调用
    static func read(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return pdfText(url)
        case "zip":
            // 一行一个文件路径，命中时结果里显示的就是包里的那个文件
            return ZipListing.read(url, maxNames: 5_000)?.names.joined(separator: "\n")
        case let ext where isOfficeDocument(ext):
            return OfficeText.read(url).map { String($0.prefix(maxCharacters)) }
        default:
            break
        }
        return TextClipboard.readText(url).map { String($0.prefix(maxCharacters)) }
    }

    private static func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        var text = ""
        for index in 0..<min(document.pageCount, maxPDFPages) {
            if let page = document.page(at: index)?.string {
                text += page + "\n"
            }
            if text.count >= maxCharacters { break }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxCharacters))
    }
}

/// Word / PowerPoint / Excel 文档里的文字。这三种文件本身是 zip，文字在里面的 XML 里：
/// 取出文字节点，段落之间换行，不管格式
enum OfficeText {
    /// 单个 XML 最多解出这么大，太大的文档只是搜不到，不至于卡住
    private static let maxXMLBytes = 16 * 1024 * 1024
    /// 一个文档总共最多解出这么多、读这么多个部分：防止上千页的幻灯片（或故意做的压缩炸弹）把 CPU 和内存占满
    private static let maxTotalBytes = 64 * 1024 * 1024
    private static let maxParts = 500

    private struct Kind {
        /// 要读的 XML 条目
        let parts: (ZipArchive.Entry) -> Bool
        /// 文字所在的标签（如 w:t），以及一段结束的标签（如 w:p）
        let textTag: String
        let breakTags: [String]
    }

    private static func kind(for fileExtension: String) -> Kind? {
        switch fileExtension.lowercased() {
        case "docx":
            return Kind(parts: { $0.name == "word/document.xml" }, textTag: "w:t", breakTags: ["w:p"])
        case "pptx":
            return Kind(parts: { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") },
                        textTag: "a:t", breakTags: ["a:p"])
        case "xlsx":
            // 文字一般在共享字符串表里；有些工具（WPS、程序导出）直接写在单元格里（inlineStr），工作表也读
            return Kind(parts: {
                $0.name == "xl/sharedStrings.xml"
                    || ($0.name.hasPrefix("xl/worksheets/sheet") && $0.name.hasSuffix(".xml"))
            }, textTag: "t", breakTags: ["si", "c"])
        default:
            return nil
        }
    }

    /// 后台调用
    static func read(_ url: URL) -> String? {
        guard let kind = kind(for: url.pathExtension), let entries = ZipArchive.entries(of: url) else { return nil }
        // 幻灯片按页码排（slide2 在 slide10 前面）
        let parts = entries.filter(kind.parts).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var text = ""
        var budget = maxTotalBytes
        var sharedStringsHadText = false
        for part in parts.prefix(maxParts) {
            // Excel：共享字符串表里有字就够了，工作表多半是一大堆数字，不再逐个解
            if sharedStringsHadText, part.name.hasPrefix("xl/worksheets/") { break }
            guard budget > 0,
                  let data = ZipArchive.data(of: part, in: url, maxSize: min(maxXMLBytes, budget)) else { continue }
            budget -= data.count
            let partText = extract(String(decoding: data, as: UTF8.self), kind: kind)
            if part.name == "xl/sharedStrings.xml" {
                sharedStringsHadText = !partText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            text += partText
            if text.count >= SearchableText.maxCharacters { break }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    enum Count: Equatable {
        case pages(Int), slides(Int), sheets(Int)
    }

    /// Word 页数（Word 存盘时写进 docProps/app.xml，没写就没有）、幻灯片张数、工作表个数；后台调用
    static func count(_ url: URL) -> Count? {
        guard let entries = ZipArchive.entries(of: url) else { return nil }
        func parts(prefix: String) -> Int {
            entries.filter { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(".xml") && !$0.name.contains("/_rels/") }.count
        }
        switch url.pathExtension.lowercased() {
        case "pptx":
            let slides = parts(prefix: "ppt/slides/slide")
            return slides > 0 ? .slides(slides) : nil
        case "xlsx":
            let sheets = parts(prefix: "xl/worksheets/sheet")
            return sheets > 0 ? .sheets(sheets) : nil
        default:
            guard let app = entries.first(where: { $0.name == "docProps/app.xml" }),
                  let data = ZipArchive.data(of: app, in: url, maxSize: 256 * 1024) else { return nil }
            let xml = String(decoding: data, as: UTF8.self)
            guard let start = xml.range(of: "<Pages>"),
                  let end = xml.range(of: "</Pages>", range: start.upperBound..<xml.endIndex),
                  let pages = Int(xml[start.upperBound..<end.lowerBound]), pages > 0 else { return nil }
            return .pages(pages)
        }
    }

    private static func extract(_ xml: String, kind: Kind) -> String {
        let text = NSRegularExpression.escapedPattern(for: kind.textTag)
        let paragraph = kind.breakTags.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // <w:t>文字</w:t> 或 <w:t xml:space="preserve">文字</w:t>；</w:p> 换行
        guard let regex = try? NSRegularExpression(pattern: "<\(text)(?:\\s[^>]*)?>([^<]*)</\(text)>|</(?:\(paragraph))>") else { return "" }
        var output = ""
        let ns = xml as NSString
        regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let content = match.range(at: 1)
            if content.location != NSNotFound {
                output += decodeEntities(ns.substring(with: content))
            } else if !output.hasSuffix("\n") {
                output += "\n"
            }
        }
        return output
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        if let numeric = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            var rebuilt = ""
            var last = 0
            for match in numeric.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                rebuilt += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let isHex = match.range(at: 1).length > 0
                let digits = ns.substring(with: match.range(at: 2))
                if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    rebuilt += String(Character(scalar))
                } else {
                    rebuilt += ns.substring(with: match.range)
                }
                last = match.range.location + match.range.length
            }
            rebuilt += ns.substring(from: last)
            result = rebuilt
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
