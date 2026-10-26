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

/// 已从列表里移走、等待真正删除的文件（可撤销）
struct PendingDeletion: Identifiable, Equatable {
    let id = UUID()
    let ids: Set<String>
    let message: String
}

@MainActor
final class ReceivedFileCacheStore: ObservableObject {
    @Published private(set) var cacheSummary: String = String(localized: "读取中…")
    /// 界面看到的文件：磁盘上的文件减去待删除/正在删除的
    @Published private(set) var cachedFiles: [CachedReceivedFile] = []
    @Published private(set) var feedback: CacheActionFeedback?
    @Published private(set) var pendingDeletion: PendingDeletion?
    @Published var retentionPolicy: ReceivedFileRetentionPolicy = ReceivedFileCache.retentionPolicy

    /// 撤销窗口：删除后这么久内可以撤销，之后才真正删掉
    static var undoWindow: TimeInterval {
        #if DEBUG
        // 自动化测试时操作慢，可用 `-DemoUndoWindow 30` 拉长
        let override = UserDefaults.standard.double(forKey: "DemoUndoWindow")
        if override > 0 { return override }
        #endif
        return 6
    }

    private let workerQueue = DispatchQueue(label: "org.cimbar.receiver.cache-store", qos: .utility)
    /// 最近一次从磁盘读到的完整列表
    private var diskFiles: [CachedReceivedFile] = []
    /// 已提交删除、但磁盘操作还没回来的文件，期间别让它们在列表里闪回
    private var deletingIDs: Set<String> = []
    private var pendingCommitTask: Task<Void, Never>?

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
        commitPendingDeletion()
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

    /// 先从列表里移走，撤销窗口过后再真正删除；同时只保留一笔待删除，新的一笔会让上一笔立即生效
    func deleteWithUndo(ids: Set<String>, message: String) {
        guard !ids.isEmpty else { return }
        commitPendingDeletion()
        let pending = PendingDeletion(ids: ids, message: message)
        pendingDeletion = pending
        applyVisibleFiles()
        pendingCommitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.undoWindow * 1_000_000_000))
            guard !Task.isCancelled, self?.pendingDeletion?.id == pending.id else { return }
            self?.commitPendingDeletion()
        }
    }

    func undoPendingDeletion() {
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        pendingDeletion = nil
        applyVisibleFiles()
    }

    /// 退到后台、清空全部等场合调用：不等撤销窗口，立即删除
    func commitPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        pendingDeletion = nil
        deleteFiles(ids: pending.ids)
    }

    func deleteFiles(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        deletingIDs.formUnion(ids)

        workerQueue.async { [weak self] in
            do {
                let allFiles = try ReceivedFileCache.listFiles()
                let selected = allFiles.filter { ids.contains($0.id) }
                let failedCount = try ReceivedFileCache.delete(files: selected)
                let files = try ReceivedFileCache.listFiles()
                self?.onMain { $0.deletingIDs.subtract(ids) }
                self?.publish(files: files)
                self?.publishFeedbackIfFailed(failedCount, source: .delete)
            } catch {
                self?.onMain {
                    $0.deletingIDs.subtract(ids)
                    $0.refresh(cleanup: false)
                }
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
        onMain {
            $0.diskFiles = files
            $0.applyVisibleFiles()
        }
    }

    private func applyVisibleFiles() {
        let hidden = deletingIDs.union(pendingDeletion?.ids ?? [])
        let visible = hidden.isEmpty ? diskFiles : diskFiles.filter { !hidden.contains($0.id) }
        let totalBytes = visible.reduce(Int64(0)) { $0 + $1.fileSize }
        cachedFiles = visible
        cacheSummary = ReceivedFileCache.summaryText(for: visible.count, totalBytes: totalBytes)
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
