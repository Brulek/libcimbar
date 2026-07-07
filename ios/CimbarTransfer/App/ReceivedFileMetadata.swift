import Foundation

struct ReceivedFileMetadata: Codable, Hashable {
    let id: UUID
    let originalName: String
    var displayName: String
    let receivedAt: Date
    var fileSize: Int64
    var sha256: String?

    init(
        id: UUID = UUID(),
        originalName: String,
        displayName: String? = nil,
        receivedAt: Date = Date(),
        fileSize: Int64,
        sha256: String? = nil
    ) {
        self.id = id
        self.originalName = originalName
        self.displayName = displayName ?? originalName
        self.receivedAt = receivedAt
        self.fileSize = fileSize
        self.sha256 = sha256
    }
}

final class ReceivedFileMetadataStore {
    static let shared = ReceivedFileMetadataStore()

    private let queue = DispatchQueue(label: "org.cimbar.metadata-store", qos: .utility)
    private var entries: [String: ReceivedFileMetadata] = [:]
    private var loaded = false

    private init() {}

    private var manifestURL: URL? {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent("CimbarTransfer", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return directory.appendingPathComponent("manifest.json", isDirectory: false)
    }

    func metadata(for filename: String) -> ReceivedFileMetadata? {
        queue.sync {
            ensureLoadedLocked()
            return entries[filename]
        }
    }

    func register(filename: String, originalName: String? = nil, fileSize: Int64, receivedAt: Date = Date()) -> ReceivedFileMetadata {
        queue.sync {
            ensureLoadedLocked()
            if let existing = entries[filename] {
                var updated = existing
                updated.fileSize = fileSize
                entries[filename] = updated
                persistLocked()
                return updated
            }
            let metadata = ReceivedFileMetadata(
                originalName: originalName ?? filename,
                displayName: filename,
                receivedAt: receivedAt,
                fileSize: fileSize
            )
            entries[filename] = metadata
            persistLocked()
            return metadata
        }
    }

    func rename(filename: String, to newDisplayName: String) {
        queue.sync {
            ensureLoadedLocked()
            guard var existing = entries[filename] else { return }
            existing.displayName = newDisplayName
            entries[filename] = existing
            persistLocked()
        }
    }

    func remove(filenames: [String]) {
        queue.sync {
            ensureLoadedLocked()
            for name in filenames {
                entries.removeValue(forKey: name)
            }
            persistLocked()
        }
    }

    /// 记录一次性计算出的校验值，之后打开详情页可直接展示
    func updateChecksum(filename: String, sha256: String) {
        queue.sync {
            ensureLoadedLocked()
            guard var existing = entries[filename] else { return }
            existing.sha256 = sha256
            entries[filename] = existing
            persistLocked()
        }
    }

    func renameKey(from oldFilename: String, to newFilename: String) {
        queue.sync {
            ensureLoadedLocked()
            guard let existing = entries[oldFilename] else { return }
            entries.removeValue(forKey: oldFilename)
            entries[newFilename] = existing
            persistLocked()
        }
    }

    func reconcile(presentFilenames: Set<String>) {
        queue.sync {
            ensureLoadedLocked()
            let known = Set(entries.keys)
            let missing = known.subtracting(presentFilenames)
            for name in missing {
                entries.removeValue(forKey: name)
            }
            if !missing.isEmpty {
                persistLocked()
            }
        }
    }

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        guard let url = manifestURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder.fileMetadataDecoder.decode([String: ReceivedFileMetadata].self, from: data)
            entries = decoded
        } catch {
            entries = [:]
        }
    }

    private func persistLocked() {
        guard let url = manifestURL else { return }
        do {
            let data = try JSONEncoder.fileMetadataEncoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persisting metadata is best-effort — if it fails the in-memory state is still authoritative for this session.
        }
    }
}

private extension JSONEncoder {
    static let fileMetadataEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let fileMetadataDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
