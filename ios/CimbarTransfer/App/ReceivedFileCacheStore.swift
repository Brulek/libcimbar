import Foundation

struct CacheActionFeedback: Identifiable, Equatable {
    enum Source {
        case delete
        case clear
    }

    let id = UUID()
    let source: Source
    let message: String
}

@MainActor
final class ReceivedFileCacheStore: ObservableObject {
    @Published private(set) var cacheSummary: String = String(localized: "读取中…")
    @Published private(set) var cachedFiles: [CachedReceivedFile] = []
    @Published private(set) var feedback: CacheActionFeedback?
    @Published var retentionPolicy: ReceivedFileRetentionPolicy = ReceivedFileCache.retentionPolicy

    private let workerQueue = DispatchQueue(label: "org.cimbar.receiver.cache-store", qos: .utility)

    func refresh(cleanup: Bool) {
        workerQueue.async { [weak self] in
            do {
                if cleanup {
                    try ReceivedFileCache.cleanup()
                }
                let files = try ReceivedFileCache.listFiles()
                self?.publish(files: files)
            } catch {
                self?.onMain {
                    $0.cachedFiles = []
                    $0.cacheSummary = String(localized: "存储目录不可用")
                }
            }
        }
    }

    func clearAllCache() {
        workerQueue.async { [weak self] in
            do {
                let failedCount = try ReceivedFileCache.clear()
                let files = try ReceivedFileCache.listFiles()
                self?.publish(files: files)
                self?.publishFeedbackIfFailed(failedCount, source: .clear)
            } catch {
                self?.onMain { $0.refresh(cleanup: false) }
            }
        }
    }

    func deleteFiles(ids: Set<String>) {
        guard !ids.isEmpty else { return }

        workerQueue.async { [weak self] in
            do {
                let allFiles = try ReceivedFileCache.listFiles()
                let selected = allFiles.filter { ids.contains($0.id) }
                let failedCount = try ReceivedFileCache.delete(files: selected)
                let files = try ReceivedFileCache.listFiles()
                self?.publish(files: files)
                self?.publishFeedbackIfFailed(failedCount, source: .delete)
            } catch {
                self?.onMain { $0.refresh(cleanup: false) }
            }
        }
    }

    /// completion 在主线程回调；重命名失败时参数为 nil
    func rename(
        file: CachedReceivedFile,
        to newDisplayName: String,
        completion: (@MainActor (CachedReceivedFile?) -> Void)? = nil
    ) {
        workerQueue.async { [weak self] in
            var renamed: CachedReceivedFile?
            var files: [CachedReceivedFile]?
            do {
                renamed = try ReceivedFileCache.renameFile(file, newDisplayName: newDisplayName)
                files = try ReceivedFileCache.listFiles()
            } catch {
                self?.onMain { $0.refresh(cleanup: false) }
            }
            // 主队列 FIFO：先投递 completion（更新调用方跟踪的文件名），
            // 再发布新列表——否则详情页会先看到旧文件名从列表消失而误判被删除
            if let completion {
                let result = renamed
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        completion(result)
                    }
                }
            }
            if let files {
                self?.publish(files: files)
            }
        }
    }

    func updateRetentionPolicy(_ policy: ReceivedFileRetentionPolicy) {
        ReceivedFileCache.retentionPolicy = policy
        retentionPolicy = policy
        refresh(cleanup: true)
    }

    func clearFeedback() {
        feedback = nil
    }

    nonisolated private func publish(files: [CachedReceivedFile]) {
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.fileSize }
        let summary = ReceivedFileCache.summaryText(for: files.count, totalBytes: totalBytes)
        onMain {
            $0.cachedFiles = files
            $0.cacheSummary = summary
        }
    }

    nonisolated private func publishFeedbackIfFailed(_ failedCount: Int, source: CacheActionFeedback.Source) {
        guard failedCount > 0 else { return }
        let message = source == .clear
            ? String(localized: "有 \(failedCount) 个文件未能清除，请稍后重试")
            : String(localized: "有 \(failedCount) 个文件删除失败，请稍后重试")
        onMain {
            $0.feedback = CacheActionFeedback(source: source, message: message)
        }
    }

    // 用 DispatchQueue.main（FIFO）回主线程：非结构化 Task 之间没有顺序保证，
    // 连续两次 refresh 的结果可能乱序，短暂显示旧列表
    nonisolated private func onMain(_ work: @escaping @MainActor (ReceivedFileCacheStore) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                work(self)
            }
        }
    }
}
