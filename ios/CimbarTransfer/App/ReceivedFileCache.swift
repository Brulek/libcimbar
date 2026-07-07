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
}

enum ReceivedFileRetentionPolicy: String, CaseIterable, Identifiable {
    case keepAll
    case days30
    case days7

    var id: String { rawValue }

    var description: String {
        switch self {
        case .keepAll: return "永久保留"
        case .days30: return "保留 30 天"
        case .days7:  return "保留 7 天"
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
        return "\(count) 个文件 · \(size)"
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
        let expired = files.filter { now.timeIntervalSince($0.modifiedAt) > maxAge }
        try delete(files: expired)
    }

    static func currentFileCount() throws -> Int {
        try listFiles().count
    }

    static func listFiles() throws -> [CachedReceivedFile] {
        let fileManager = FileManager.default
        let directory = try directoryURL()
        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey, .isDirectoryKey, .fileSizeKey]
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )

        let metadataStore = ReceivedFileMetadataStore.shared
        var files: [CachedReceivedFile] = []
        var presentNames: Set<String> = []
        for fileURL in fileURLs {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if values.isDirectory == true { continue }
            let lastComponent = fileURL.lastPathComponent
            if lastComponent == "manifest.json" { continue }
            presentNames.insert(lastComponent)
            let modifiedAt = values.contentModificationDate ?? .distantPast
            let fileSize = Int64(values.fileSize ?? 0)
            // manifest 丢失/损坏后懒注册时，用文件创建时间兜底，避免接收时间全部漂移到当下
            let fallbackReceivedAt = values.creationDate ?? modifiedAt
            let metadata = metadataStore.metadata(for: lastComponent)
                ?? metadataStore.register(
                    filename: lastComponent,
                    originalName: lastComponent,
                    fileSize: fileSize,
                    receivedAt: fallbackReceivedAt == .distantPast ? Date() : fallbackReceivedAt
                )
            files.append(
                CachedReceivedFile(
                    url: fileURL,
                    fileName: lastComponent,
                    displayName: metadata.displayName,
                    receivedAt: metadata.receivedAt,
                    modifiedAt: modifiedAt,
                    fileSize: fileSize
                )
            )
        }
        metadataStore.reconcile(presentFilenames: presentNames)
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

    static func renameFile(_ file: CachedReceivedFile, newDisplayName: String) throws -> CachedReceivedFile {
        let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "ReceivedFileCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "新文件名不能为空"])
        }
        ReceivedFileMetadataStore.shared.rename(filename: file.fileName, to: trimmed)
        return CachedReceivedFile(
            url: file.url,
            fileName: file.fileName,
            displayName: trimmed,
            receivedAt: file.receivedAt,
            modifiedAt: file.modifiedAt,
            fileSize: file.fileSize
        )
    }
}
