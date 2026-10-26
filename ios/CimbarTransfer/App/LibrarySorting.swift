import Foundation

// 「我的文件」的排序和分组：纯函数，不碰界面状态

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case dateDescending
    case dateAscending
    case nameAscending
    case sizeDescending
    case kind

    var id: String { rawValue }

    /// 记住所选排序的 UserDefaults 键（设置页「已用空间」也会改它）
    static let defaultsKey = "org.cimbar.library-sort"

    var displayName: String {
        switch self {
        case .dateDescending: return String(localized: "最新优先")
        case .dateAscending:  return String(localized: "最早优先")
        case .nameAscending:  return String(localized: "名称")
        case .sizeDescending: return String(localized: "大小")
        case .kind:           return String(localized: "类型")
        }
    }

    var symbol: String {
        switch self {
        case .dateDescending: return "arrow.down"
        case .dateAscending:  return "arrow.up"
        case .nameAscending:  return "abc"
        case .sizeDescending: return "internaldrive"
        case .kind:           return "square.grid.2x2"
        }
    }

    var isByDate: Bool {
        self == .dateDescending || self == .dateAscending
    }
}

/// 按「类型」排序时的分组，顺序即显示顺序
enum LibraryFileKind: Int, CaseIterable {
    case media, document, audio, archive, other

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "txt", "md", "rtf", "csv", "json", "xml", "yaml", "yml", "log", "html", "htm",
    ]
    private static let audioExtensions: Set<String> = ["mp3", "wav", "aac", "flac", "m4a"]

    init(fileExtension: String) {
        if PhotoLibrarySaver.canSave(extension: fileExtension) {
            self = .media
        } else if Self.documentExtensions.contains(fileExtension) {
            self = .document
        } else if Self.audioExtensions.contains(fileExtension) {
            self = .audio
        } else if FilesExport.isArchive(fileExtension) {
            self = .archive
        } else {
            self = .other
        }
    }

    var title: String {
        switch self {
        case .media:    return String(localized: "照片和视频")
        case .document: return String(localized: "文档")
        case .audio:    return String(localized: "音频")
        case .archive:  return String(localized: "压缩包")
        case .other:    return String(localized: "其他")
        }
    }
}

/// 按接收日期分组的列表分段
struct LibrarySection: Identifiable {
    let id: String
    let title: String?
    let files: [CachedReceivedFile]
}

enum LibraryOrdering {
    static func nameOrder(_ a: CachedReceivedFile, _ b: CachedReceivedFile) -> Bool {
        a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }

    static func sorted(_ files: [CachedReceivedFile], by sortOption: LibrarySortOption) -> [CachedReceivedFile] {
        switch sortOption {
        // 同一时刻登记的文件（比如一次从「文件」App 拖进来一批）按名称排，每次打开顺序一样
        case .dateDescending: return files.sorted { $0.receivedAt != $1.receivedAt ? $0.receivedAt > $1.receivedAt : Self.nameOrder($0, $1) }
        case .dateAscending:  return files.sorted { $0.receivedAt != $1.receivedAt ? $0.receivedAt < $1.receivedAt : Self.nameOrder($0, $1) }
        case .nameAscending:  return files.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .sizeDescending: return files.sorted { $0.fileSize != $1.fileSize ? $0.fileSize > $1.fileSize : Self.nameOrder($0, $1) }
        case .kind:
            // 同类里新的在前
            return files.sorted {
                let lhs = LibraryFileKind(fileExtension: $0.fileExtension).rawValue
                let rhs = LibraryFileKind(fileExtension: $1.fileExtension).rawValue
                if lhs != rhs { return lhs < rhs }
                return $0.receivedAt != $1.receivedAt ? $0.receivedAt > $1.receivedAt : Self.nameOrder($0, $1)
            }
        }
    }

    /// 按日期排序时分成「今天 / 昨天 / 近 7 天 / 更早」，按类型排序时按类型分组，其余排序和搜索时不分组。
    /// `today` 是「今天」所在的任意时刻，由列表传入（过了午夜会换）
    static func sections(
        for files: [CachedReceivedFile],
        sortedBy sortOption: LibrarySortOption,
        searching: Bool,
        today: Date
    ) -> [LibrarySection] {
        if sortOption == .kind, !searching {
            return LibraryFileKind.allCases.compactMap { kind in
                let members = files.filter { LibraryFileKind(fileExtension: $0.fileExtension) == kind }
                return members.isEmpty ? nil : LibrarySection(id: "kind-\(kind.rawValue)", title: kind.title, files: members)
            }
        }
        guard sortOption.isByDate, !searching else {
            return [LibrarySection(id: "all", title: nil, files: files)]
        }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: today)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday

        func bucket(_ date: Date) -> Int {
            if date >= startOfToday { return 0 }
            if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
               date >= startOfYesterday { return 1 }
            if date >= weekAgo { return 2 }
            return 3
        }
        let titles = [
            String(localized: "今天"),
            String(localized: "昨天"),
            String(localized: "近 7 天"),
            String(localized: "更早"),
        ]
        var result: [LibrarySection] = []
        for file in files {
            let index = bucket(file.receivedAt)
            if result.last?.id == "bucket-\(index)" {
                let last = result.removeLast()
                result.append(LibrarySection(id: last.id, title: last.title, files: last.files + [file]))
            } else {
                result.append(LibrarySection(id: "bucket-\(index)", title: titles[index], files: [file]))
            }
        }
        return result
    }
}
