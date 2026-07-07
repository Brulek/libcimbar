import CryptoKit
import SwiftUI

struct FileDetailScreen: View {
    @ObservedObject var store: ReceivedFileCacheStore
    let initialFile: CachedReceivedFile
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sha256: String?
    @State private var checksumFailed = false
    @State private var copiedChecksum = false
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var deleteConfirm = false
    @State private var photoSaveMessage: String?

    /// 重命名等操作会刷新 store，这里始终取最新快照，避免展示旧显示名
    private var file: CachedReceivedFile {
        store.cachedFiles.first { $0.id == initialFile.id } ?? initialFile
    }

    private var originalName: String {
        ReceivedFileMetadataStore.shared.metadata(for: file.fileName)?.originalName ?? file.fileName
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    FileThumbnailView(
                        url: file.url,
                        cacheKey: "detail-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)",
                        cornerRadius: 16,
                        generationSide: 160
                    )
                    .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.displayName)
                            .font(.headline)
                            .lineLimit(2)
                        Text(file.sizeDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("详情") {
                LabeledContent("接收时间", value: file.receivedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("原始文件名") {
                    Text(originalName)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("保存文件名") {
                    Text(file.fileName)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                checksumRow
            }

            Section {
                Button {
                    onPreview(file.url)
                } label: {
                    Label("预览", systemImage: "eye")
                }
                Button {
                    onShare(file.url)
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                if PhotoLibrarySaver.canSave(extension: file.fileExtension) {
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Label("存到相册", systemImage: "photo.on.rectangle")
                    }
                }
                Button {
                    renameText = file.displayName
                    renamePresented = true
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
            }

            Section {
                Button(role: .destructive) {
                    deleteConfirm = true
                } label: {
                    Label("删除文件", systemImage: "trash")
                }
            }
        }
        .navigationTitle("文件详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: file.fileName) {
            await loadChecksum()
        }
        .alert("重命名", isPresented: $renamePresented) {
            TextField("文件名", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") {
                store.rename(file: file, to: renameText)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅修改显示名称，不会改变实际文件名")
        }
        .alert("删除文件", isPresented: $deleteConfirm) {
            Button("删除", role: .destructive) {
                store.deleteFiles(ids: [file.id])
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除「\(file.displayName)」，无法恢复。")
        }
        .alert("存到相册", isPresented: Binding(
            get: { photoSaveMessage != nil },
            set: { if !$0 { photoSaveMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(photoSaveMessage ?? "")
        }
    }

    @ViewBuilder
    private var checksumRow: some View {
        if let sha256 {
            Button {
                UIPasteboard.general.string = sha256
                copiedChecksum = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    copiedChecksum = false
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SHA-256")
                            .foregroundStyle(.primary)
                        Spacer()
                        Label(copiedChecksum ? "已复制" : "复制", systemImage: copiedChecksum ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copiedChecksum ? .green : .secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    Text(sha256)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .buttonStyle(.plain)
        } else if checksumFailed {
            LabeledContent("SHA-256", value: "计算失败")
        } else {
            LabeledContent("SHA-256") {
                ProgressView()
            }
        }
    }

    private func loadChecksum() async {
        checksumFailed = false
        if let cached = ReceivedFileMetadataStore.shared.metadata(for: file.fileName)?.sha256 {
            sha256 = cached
            return
        }
        sha256 = nil
        let url = file.url
        let filename = file.fileName
        do {
            let digest = try await Self.computeSHA256(url: url)
            ReceivedFileMetadataStore.shared.updateChecksum(filename: filename, sha256: digest)
            // 计算期间用户可能已切换到其他文件详情
            if file.fileName == filename {
                sha256 = digest
            }
        } catch {
            checksumFailed = true
        }
    }

    /// 流式计算，支持大文件而不占内存
    private static func computeSHA256(url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try autoreleasepool {
                    try handle.read(upToCount: 1 << 20)
                }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    @MainActor
    private func saveToPhotos() async {
        do {
            try await PhotoLibrarySaver.save(fileURL: file.url)
            photoSaveMessage = "已保存到相册"
        } catch {
            photoSaveMessage = (error as? LocalizedError)?.errorDescription ?? "保存失败"
        }
    }
}
