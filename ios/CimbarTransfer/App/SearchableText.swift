import Foundation
import PDFKit

/// 「我的文件」按内容搜索时读出的文字：小文本全文、PDF 前几页的文字
enum SearchableText {
    /// 每个文件只索引开头 10 万字：过滤在主线程上、每敲一个字跑一遍，几十个大文件全文会卡
    static let maxCharacters = 100_000
    /// PDF 只读前 20 页、20 MB 以内：报告、发票、合同的关键内容一般在前面，扫描件也没有文字可读
    static let maxPDFPages = 20
    static let maxPDFBytes: Int64 = 20 * 1024 * 1024

    static func canIndexPDF(fileExtension: String, size: Int64) -> Bool {
        fileExtension.lowercased() == "pdf" && size > 0 && size <= maxPDFBytes
    }

    /// 后台调用
    static func read(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return pdfText(url)
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
