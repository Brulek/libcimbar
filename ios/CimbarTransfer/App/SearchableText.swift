import Foundation
import PDFKit

/// 「我的文件」按内容搜索时读出的文字：小文本全文、PDF 前几页的文字、zip 里的文件名
enum SearchableText {
    /// 每个文件只索引开头 10 万字：过滤在主线程上、每敲一个字跑一遍，几十个大文件全文会卡
    static let maxCharacters = 100_000
    /// PDF 只读前 20 页、20 MB 以内：报告、发票、合同的关键内容一般在前面，扫描件也没有文字可读
    static let maxPDFPages = 20
    static let maxPDFBytes: Int64 = 20 * 1024 * 1024

    /// 小文本以外能按内容搜的：PDF（有大小上限）和 zip（只读末尾的文件名列表，多大都行）
    static func canIndexDocument(fileExtension: String, size: Int64) -> Bool {
        switch fileExtension.lowercased() {
        case "pdf": return size > 0 && size <= maxPDFBytes
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
