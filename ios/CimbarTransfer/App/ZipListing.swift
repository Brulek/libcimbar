import Foundation

/// 压缩包里有什么：只读 zip 末尾的中央目录（文件名和大小），不解压。
/// 简介页上给看一眼，决定要不要存到「文件」里解压
struct ZipListing: Equatable {
    /// 文件个数（不含文件夹和 macOS 打包时夹带的 __MACOSX、.DS_Store）
    let fileCount: Int
    /// 解压后的总大小
    let totalSize: Int64
    /// 按中央目录里的顺序取前几个文件的路径
    let names: [String]

    static let maxNames = 8
    /// 中央目录最多读这么多：再大的包只看前面，不为一个列表读几十 MB
    private static let maxDirectoryBytes = 4 * 1024 * 1024

    /// `maxNames`：简介页只列几个；按内容搜索时要全部文件名
    static func read(_ url: URL, maxNames: Int = maxNames) -> ZipListing? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= 22,
              let directory = locateDirectory(handle, fileSize: fileSize) else { return nil }
        let length = min(directory.size, UInt64(maxDirectoryBytes))
        guard (try? handle.seek(toOffset: directory.offset)) != nil,
              let data = try? handle.read(upToCount: Int(length)) else { return nil }
        return parseEntries(data, count: directory.count, maxNames: maxNames)
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

    private static func parseEntries(_ data: Data, count: UInt64, maxNames: Int) -> ZipListing? {
        let bytes = [UInt8](data)
        var position = 0
        var fileCount = 0
        var totalSize: Int64 = 0
        var names: [String] = []
        var parsed: UInt64 = 0
        while parsed < count, position + 46 <= bytes.count, le32(bytes, position) == 0x0201_4b50 {
            let flags = le16(bytes, position + 8)
            var uncompressed = UInt64(le32(bytes, position + 24))
            let nameLength = Int(le16(bytes, position + 28))
            let extraLength = Int(le16(bytes, position + 30))
            let commentLength = Int(le16(bytes, position + 32))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            guard extraStart + extraLength <= bytes.count else { break }

            if uncompressed == 0xFFFF_FFFF {
                uncompressed = zip64Size(bytes, from: extraStart, length: extraLength) ?? 0
            }
            let name = decodeName(Array(bytes[nameStart..<extraStart]), utf8Flag: flags & 0x0800 != 0)
            if !name.hasSuffix("/"), !isMacJunk(name) {
                fileCount += 1
                totalSize += Int64(clamping: uncompressed)
                if names.count < maxNames {
                    names.append(name)
                }
            }
            position = extraStart + extraLength + commentLength
            parsed += 1
        }
        guard parsed > 0 else { return nil }
        return ZipListing(fileCount: fileCount, totalSize: totalSize, names: names)
    }

    /// ZIP64 扩展字段（0x0001）里的第一个值是解压后大小
    private static func zip64Size(_ bytes: [UInt8], from start: Int, length: Int) -> UInt64? {
        var position = start
        while position + 4 <= start + length {
            let id = le16(bytes, position)
            let size = Int(le16(bytes, position + 2))
            if id == 0x0001, size >= 8, position + 12 <= bytes.count {
                return le64(bytes, position + 4)
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

    private static func isMacJunk(_ name: String) -> Bool {
        name.hasPrefix("__MACOSX/") || name == ".DS_Store" || name.hasSuffix("/.DS_Store")
    }

    // MARK: - 小端整数

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 2 <= b.count else { return 0 }
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
