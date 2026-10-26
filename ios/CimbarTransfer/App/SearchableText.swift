import Foundation
import PDFKit

/// 「我的文件」按内容搜索时读出的文字：小文本全文、PDF 前几页的文字、Word/PowerPoint/Excel 里的文字、zip 里的文件名
enum SearchableText {
    /// 每个文件只索引开头 10 万字：过滤在主线程上、每敲一个字跑一遍，几十个大文件全文会卡
    static let maxCharacters = 100_000
    /// PDF 只读前 20 页、20 MB 以内：报告、发票、合同的关键内容一般在前面，扫描件也没有文字可读
    static let maxPDFPages = 20
    static let maxPDFBytes: Int64 = 20 * 1024 * 1024

    /// 小文本以外能按内容搜的：PDF、Office 文档（有大小上限）和 zip（只读末尾的文件名列表，多大都行）
    static func canIndexDocument(fileExtension: String, size: Int64) -> Bool {
        switch fileExtension.lowercased() {
        case "pdf", "docx", "pptx", "xlsx": return size > 0 && size <= maxPDFBytes
        case "zip": return size > 0
        default: return false
        }
    }

    /// 后台调用
    static func read(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return pdfText(url)
        case "zip":
            // 一行一个文件路径，命中时结果里显示的就是包里的那个文件
            return ZipListing.read(url, maxNames: 5_000)?.names.joined(separator: "\n")
        case "docx", "pptx", "xlsx":
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

    private struct Kind {
        /// 要读的 XML 条目
        let parts: (ZipArchive.Entry) -> Bool
        /// 文字所在的标签（如 w:t），以及一段结束的标签（如 w:p）
        let textTag: String
        let breakTag: String
    }

    private static func kind(for fileExtension: String) -> Kind? {
        switch fileExtension.lowercased() {
        case "docx":
            return Kind(parts: { $0.name == "word/document.xml" }, textTag: "w:t", breakTag: "w:p")
        case "pptx":
            return Kind(parts: { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") },
                        textTag: "a:t", breakTag: "a:p")
        case "xlsx":
            return Kind(parts: { $0.name == "xl/sharedStrings.xml" }, textTag: "t", breakTag: "si")
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
        for part in parts {
            guard let data = ZipArchive.data(of: part, in: url, maxSize: maxXMLBytes) else { continue }
            text += extract(String(decoding: data, as: UTF8.self), kind: kind)
            if text.count >= SearchableText.maxCharacters { break }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extract(_ xml: String, kind: Kind) -> String {
        let text = NSRegularExpression.escapedPattern(for: kind.textTag)
        let paragraph = NSRegularExpression.escapedPattern(for: kind.breakTag)
        // <w:t>文字</w:t> 或 <w:t xml:space="preserve">文字</w:t>；</w:p> 换行
        guard let regex = try? NSRegularExpression(pattern: "<\(text)(?:\\s[^>]*)?>([^<]*)</\(text)>|</\(paragraph)>") else { return "" }
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
