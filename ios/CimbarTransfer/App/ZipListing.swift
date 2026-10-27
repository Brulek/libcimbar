import Compression
import Foundation

/// 压缩包里有什么：只读 zip 末尾的中央目录（文件名和大小），不解压。
/// 简介页上给看一眼，决定要不要存到「文件」里解压
struct ZipListing: Equatable {
    /// 文件个数（不含文件夹和 macOS 打包时夹带的 __MACOSX、.DS_Store）
    let fileCount: Int
    /// 解压后的总大小
    let totalSize: Int64
    /// 按中央目录里的顺序取前几个文件
    let entries: [ZipArchive.Entry]
    var names: [String] { entries.map(\.name) }

    static let maxNames = 8

    /// `maxNames`：简介页只列几个；按内容搜索时要全部文件名
    static func read(_ url: URL, maxNames: Int = maxNames) -> ZipListing? {
        guard let entries = ZipArchive.entries(of: url) else { return nil }
        let files = entries.filter { !$0.name.hasSuffix("/") && !isMacJunk($0.name) }
        return ZipListing(
            fileCount: files.count,
            // 声明的大小是外部数据（ZIP64 可以写到 2^64），加起来要封顶，不能溢出崩溃
            totalSize: files.reduce(Int64(0)) { sum, entry in
                let (result, overflow) = sum.addingReportingOverflow(Int64(clamping: entry.uncompressedSize))
                return overflow ? .max : result
            },
            entries: Array(files.prefix(maxNames))
        )
    }

    private static func isMacJunk(_ name: String) -> Bool {
        name.hasPrefix("__MACOSX/") || name == ".DS_Store" || name.hasSuffix("/.DS_Store")
    }
}

/// 只读的 zip 读取：中央目录里的条目，以及解出单个条目（存储或 deflate）。
/// 给压缩包列表和 Office 文档（docx/pptx/xlsx 本身就是 zip）的文字搜索用
enum ZipArchive {
    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let isEncrypted: Bool
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    /// 中央目录最多读这么多：再大的包只看前面，不为一个列表读几十 MB
    private static let maxDirectoryBytes = 4 * 1024 * 1024

    static func entries(of url: URL) -> [Entry]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22,
              let directory = locateDirectory(handle, fileSize: fileSize) else { return nil }
        let length = min(directory.size, UInt64(maxDirectoryBytes))
        guard (try? handle.seek(toOffset: directory.offset)) != nil,
              let data = try? handle.read(upToCount: Int(length)) else { return nil }
        let entries = parseEntries([UInt8](data), count: directory.count)
        return entries.isEmpty ? nil : entries
    }

    /// 解出一个条目；超过 `maxSize`、加密、或不是存储/deflate 的返回 nil
    static func data(of entry: Entry, in url: URL, maxSize: Int) -> Data? {
        guard !entry.isEncrypted, entry.uncompressedSize <= UInt64(maxSize),
              entry.compressedSize <= UInt64(maxSize),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: entry.localHeaderOffset)) != nil,
              let header = try? handle.read(upToCount: 30), header.count == 30 else { return nil }
        let h = [UInt8](header)
        guard le32(h, 0) == 0x0403_4b50 else { return nil }
        // 本地头里的文件名、扩展字段长度可能和中央目录里的不一样，按本地头跳
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(le16(h, 26)) + UInt64(le16(h, 28))
        guard (try? handle.seek(toOffset: dataOffset)) != nil,
              let compressed = try? handle.read(upToCount: Int(entry.compressedSize)),
              compressed.count == Int(entry.compressedSize) else { return nil }
        switch entry.method {
        case 0:
            return compressed
        case 8:
            return inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            return nil
        }
    }

    /// zip 的 deflate 是不带头的原始流，正是 Compression 框架的 COMPRESSION_ZLIB
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, expectedSize, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? output : nil
    }

    // MARK: - 结尾记录

    private struct Directory {
        var offset: UInt64
        var size: UInt64
        var count: UInt64
    }

    /// 结尾记录（EOCD）在最后 22 字节到 64 KB（注释最长 65535）之间；ZIP64 时再跟着定位记录找真正的值
    private static func locateDirectory(_ handle: FileHandle, fileSize: UInt64) -> Directory? {
        let tailLength = min(fileSize, 22 + 65_535 + 20)
        guard (try? handle.seek(toOffset: fileSize - tailLength)) != nil,
              let tail = try? handle.read(upToCount: Int(tailLength)), tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
            le32(bytes, $0) == 0x0605_4b50
        }) else { return nil }

        var directory = Directory(
            offset: UInt64(le32(bytes, eocd + 16)),
            size: UInt64(le32(bytes, eocd + 12)),
            count: UInt64(le16(bytes, eocd + 10))
        )
        let needsZip64 = directory.offset == 0xFFFF_FFFF || directory.size == 0xFFFF_FFFF || directory.count == 0xFFFF
        if needsZip64, eocd >= 20, le32(bytes, eocd - 20) == 0x0706_4b50 {
            let recordOffset = le64(bytes, eocd - 20 + 8)
            guard (try? handle.seek(toOffset: recordOffset)) != nil,
                  let record = try? handle.read(upToCount: 56), record.count >= 56 else { return nil }
            let r = [UInt8](record)
            guard le32(r, 0) == 0x0606_4b50 else { return nil }
            directory = Directory(offset: le64(r, 48), size: le64(r, 40), count: le64(r, 32))
        }
        guard directory.offset < fileSize else { return nil }
        return directory
    }

    // MARK: - 中央目录

    private static func parseEntries(_ bytes: [UInt8], count: UInt64) -> [Entry] {
        var entries: [Entry] = []
        var position = 0
        while UInt64(entries.count) < count, position + 46 <= bytes.count, le32(bytes, position) == 0x0201_4b50 {
            let flags = le16(bytes, position + 8)
            var compressed = UInt64(le32(bytes, position + 20))
            var uncompressed = UInt64(le32(bytes, position + 24))
            let nameLength = Int(le16(bytes, position + 28))
            let extraLength = Int(le16(bytes, position + 30))
            let commentLength = Int(le16(bytes, position + 32))
            var localOffset = UInt64(le32(bytes, position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength <= bytes.count else { break }

            // ZIP64 扩展字段（0x0001）：只有在中央目录里填了 0xFFFFFFFF 的值才出现，顺序固定
            if let field = zip64Field(bytes, from: extraStart, length: extraLength) {
                var cursor = field.start
                func nextWide() -> UInt64? {
                    guard cursor + 8 <= field.end else { return nil }
                    defer { cursor += 8 }
                    return le64(bytes, cursor)
                }
                if uncompressed == 0xFFFF_FFFF, let wide = nextWide() { uncompressed = wide }
                if compressed == 0xFFFF_FFFF, let wide = nextWide() { compressed = wide }
                if localOffset == 0xFFFF_FFFF, let wide = nextWide() { localOffset = wide }
            }

            entries.append(Entry(
                name: decodeName(Array(bytes[nameStart..<extraStart]), utf8Flag: flags & 0x0800 != 0),
                method: le16(bytes, position + 10),
                isEncrypted: flags & 0x0001 != 0,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset
            ))
            position = extraStart + extraLength + commentLength
        }
        return entries
    }

    private static func zip64Field(_ bytes: [UInt8], from start: Int, length: Int) -> (start: Int, end: Int)? {
        var position = start
        while position + 4 <= start + length {
            let id = le16(bytes, position)
            let size = Int(le16(bytes, position + 2))
            if id == 0x0001 {
                return (position + 4, min(position + 4 + size, bytes.count))
            }
            position += 4 + size
        }
        return nil
    }

    /// 标了 UTF-8 的按 UTF-8；没标的先试 UTF-8（新工具多半是），不行按 GB18030（Windows 中文系统打的包）
    private static func decodeName(_ raw: [UInt8], utf8Flag: Bool) -> String {
        let data = Data(raw)
        if utf8Flag || String(data: data, encoding: .utf8) != nil {
            return String(decoding: data, as: UTF8.self)
        }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        return String(data: data, encoding: gb18030) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - 小端整数

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
    }
}
