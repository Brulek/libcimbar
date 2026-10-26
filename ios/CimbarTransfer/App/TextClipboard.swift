import UIKit

/// 小文本文件的「复制文字」：常有人把链接、口令、一段话写进 txt 发过来，
/// 收到后想直接粘贴，而不是先预览再长按全选
enum TextClipboard {
    static let textExtensions: Set<String> = ["txt", "md", "csv", "json", "log", "xml", "yaml", "yml"]
    /// 再大就不是「一段文字」了，复制到剪贴板也没法用
    static let maxBytes: Int64 = 512 * 1024

    static func canCopy(fileExtension: String, size: Int64) -> Bool {
        textExtensions.contains(fileExtension.lowercased()) && size > 0 && size <= maxBytes
    }

    static func canCopy(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return canCopy(fileExtension: url.pathExtension, size: size)
    }

    /// UTF-8 → 带 BOM 的 UTF-16 → GB18030（中文 Windows 记事本存的 txt 常是 GBK）
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            // Windows 记事本「UTF-8 带 BOM」会留下一个看不见的 U+FEFF，粘贴网址/口令时会出错
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        return String(data: data, encoding: gb18030)
    }

    /// 整个文件只是一个网址（常见用法：把电脑上的链接送到手机）时返回它
    static func singleWebLink(_ url: URL) -> URL? {
        guard let text = readText(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 2048,
              text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let link = URL(string: text),
              let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https",
              link.host?.isEmpty == false else { return nil }
        return link
    }

    /// 复制成功返回 true（文件读不出来或编码不认识时返回 false）
    @discardableResult
    static func copy(_ url: URL) -> Bool {
        guard let text = readText(url) else { return false }
        UIPasteboard.general.string = text
        return true
    }
}
