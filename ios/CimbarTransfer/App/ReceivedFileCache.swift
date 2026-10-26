import Foundation

struct CachedReceivedFile: Identifiable, Hashable {
    let url: URL
    let fileName: String
    let displayName: String
    let receivedAt: Date
    let modifiedAt: Date
    let fileSize: Int64

    var id: String { fileName }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    /// 重命名输入框的初始值：去掉扩展名，扩展名由 renameFile 自动补回
    var renameStem: String {
        let ext = (displayName as NSString).pathExtension
        guard !ext.isEmpty, ext.lowercased() == fileExtension else { return displayName }
        return (displayName as NSString).deletingPathExtension
    }
}

enum ReceivedFileRetentionPolicy: String, CaseIterable, Identifiable {
    case keepAll
    case days30
    case days7

    var id: String { rawValue }

    var description: String {
        switch self {
        case .keepAll: return String(localized: "从不")
        case .days30: return String(localized: "30 天后")
        case .days7:  return String(localized: "7 天后")
        }
    }

    var maxAgeSeconds: TimeInterval? {
        switch self {
        case .keepAll: return nil
        case .days30:  return 30 * 24 * 60 * 60
        case .days7:   return 7 * 24 * 60 * 60
        }
    }
}

enum ReceivedFileCache {
    static let displayPath = "Documents/CimbarTransfer/Inbox"
    private static let retentionDefaultsKey = "org.cimbar.retention-policy"

    static var retentionPolicy: ReceivedFileRetentionPolicy {
        get {
            let raw = UserDefaults.standard.string(forKey: retentionDefaultsKey) ?? ""
            return ReceivedFileRetentionPolicy(rawValue: raw) ?? .keepAll
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: retentionDefaultsKey)
        }
    }

    static func directoryURL() throws -> URL {
        try ReceivedFileStorage.receivedFilesDirectoryURL()
    }

    static func sanitizedFilename(_ filename: String) -> String {
        ReceivedFileStorage.sanitizedFilename(filename)
    }

    static func summaryText(for count: Int, totalBytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return String(localized: "\(count) 个文件 · \(size)")
    }

    @discardableResult
    static func cleanup() throws -> Int {
        try migrateLegacyFiles()
        try applyRetentionPolicy()
        return try currentFileCount()
    }

    static func migrateLegacyFiles() throws {
        let fileManager = FileManager.default
        guard
            let legacyDir = try? ReceivedFileStorage.legacyCachesDirectoryURL(),
            fileManager.fileExists(atPath: legacyDir.path)
        else {
            return
        }
        let entries = (try? fileManager.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for source in entries {
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            // 统一交给 uniqueDestinationURL：与接收路径同一套 sanitize+截断策略，
            // 同名时自动加 " (N)" 后缀避让，绝不覆盖/删除既有文件
            guard let destination = try? ReceivedFileStorage.uniqueDestinationURL(for: source.lastPathComponent) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }
        // 仅当确认全部迁出后才删除旧目录，迁移失败的文件留待下次重试
        let remaining = (try? fileManager.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        if remaining.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }
    }

    static func applyRetentionPolicy() throws {
        guard let maxAge = retentionPolicy.maxAgeSeconds else {
            return
        }
        let now = Date()
        let files = try listFiles()
        // 按「接收时间」（manifest 登记时间）判定过期，而不是文件 mtime：
        // 用户经「文件」App 拖入的旧文件 mtime 可能是数月前，按 mtime 会被立即清掉
        let expired = files.filter { now.timeIntervalSince($0.receivedAt) > maxAge }
        try delete(files: expired)
    }

    static func currentFileCount() throws -> Int {
        try listFiles().count
    }

    static func listFiles() throws -> [CachedReceivedFile] {
        let fileManager = FileManager.default
        let directory = try directoryURL()
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .isDirectoryKey, .fileSizeKey]
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        struct Entry {
            let url: URL
            let name: String
            let modifiedAt: Date
            let fileSize: Int64
            let fallbackReceivedAt: Date
        }

        var entries: [Entry] = []
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true { continue }
            let lastComponent = fileURL.lastPathComponent
            if lastComponent == "manifest.json" { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            // manifest 丢失/损坏后懒注册时优先用「加入目录时间」兜底：
            // 拖入的文件 creationDate/mtime 可能是数月前，addedToDirectoryDate
            // 才是它真正出现在 Inbox 的时刻，避免接收时间漂移或被保留策略误杀
            let fallbackReceivedAt = values.addedToDirectoryDate ?? values.creationDate ?? modifiedAt
            entries.append(
                Entry(
                    url: fileURL,
                    name: lastComponent,
                    modifiedAt: modifiedAt,
                    fileSize: Int64(values.fileSize ?? 0),
                    fallbackReceivedAt: fallbackReceivedAt == .distantPast ? Date() : fallbackReceivedAt
                )
            )
        }

        let metadataStore = ReceivedFileMetadataStore.shared
        let metadataByName = metadataStore.metadataRegisteringMissing(
            entries.map { (filename: $0.name, fileSize: $0.fileSize, fallbackReceivedAt: $0.fallbackReceivedAt) }
        )

        let files: [CachedReceivedFile] = entries.map { entry in
            let metadata = metadataByName[entry.name]
            return CachedReceivedFile(
                url: entry.url,
                fileName: entry.name,
                displayName: metadata?.displayName ?? entry.name,
                receivedAt: metadata?.receivedAt ?? entry.fallbackReceivedAt,
                modifiedAt: entry.modifiedAt,
                fileSize: entry.fileSize
            )
        }
        metadataStore.reconcile(presentFilenames: Set(entries.map { $0.name }))
        return files.sorted { $0.receivedAt > $1.receivedAt }
    }

    @discardableResult
    static func clear() throws -> Int {
        try delete(files: try listFiles())
    }

    /// 返回删除失败的文件数（0 表示全部成功）
    @discardableResult
    static func delete(files: [CachedReceivedFile]) throws -> Int {
        let fileManager = FileManager.default
        var deleted: [String] = []
        var failedCount = 0
        for file in files {
            do {
                try fileManager.removeItem(at: file.url)
                deleted.append(file.fileName)
            } catch {
                // 文件本就不存在视为已删除，其余失败计数上报
                if fileManager.fileExists(atPath: file.url.path) {
                    failedCount += 1
                } else {
                    deleted.append(file.fileName)
                }
            }
        }
        ReceivedFileMetadataStore.shared.remove(filenames: deleted)
        return failedCount
    }

    /// 物理重命名磁盘文件（分享/「文件」App 中同步生效），扩展名保持不变
    static func renameFile(_ file: CachedReceivedFile, newDisplayName: String) throws -> CachedReceivedFile {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ReceivedFileCache", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "新文件名不能为空")])
        }

        var targetName = trimmed
        let originalExtension = file.url.pathExtension
        if !originalExtension.isEmpty,
           (targetName as NSString).pathExtension.lowercased() != originalExtension.lowercased() {
            targetName += ".\(originalExtension)"
        }
        let sanitized = ReceivedFileCache.sanitizedFilename(targetName)

        if sanitized == file.fileName {
            // 磁盘名未变，只同步显示名
            ReceivedFileMetadataStore.shared.rename(filename: file.fileName, to: sanitized)
            return CachedReceivedFile(
                url: file.url,
                fileName: file.fileName,
                displayName: sanitized,
                receivedAt: file.receivedAt,
                modifiedAt: file.modifiedAt,
                fileSize: file.fileSize
            )
        }

        let destination = try ReceivedFileStorage.uniqueDestinationURL(for: sanitized)
        try FileManager.default.moveItem(at: file.url, to: destination)
        let newFileName = destination.lastPathComponent
        ReceivedFileMetadataStore.shared.renameKey(from: file.fileName, to: newFileName)
        ReceivedFileMetadataStore.shared.rename(filename: newFileName, to: newFileName)
        return CachedReceivedFile(
            url: destination,
            fileName: newFileName,
            displayName: newFileName,
            receivedAt: file.receivedAt,
            modifiedAt: file.modifiedAt,
            fileSize: file.fileSize
        )
    }
}
