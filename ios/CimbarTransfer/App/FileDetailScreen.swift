import AVFoundation
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct FileDetailScreen: View {
    @ObservedObject var store: ReceivedFileCacheStore
    let initialFile: CachedReceivedFile
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void
    /// iPad 分栏时简介页不在导航栈里，dismiss() 什么也不做，由外面清掉选中项
    var onClose: (() -> Void)?
    /// 重命名后文件名（也是 id）变了，分栏里的选中项要跟着换，左边的高亮才不会丢
    var onRenamed: ((CachedReceivedFile) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    @State private var sha256: String?
    @State private var checksumFailed = false
    @State private var copiedChecksum = false
    @State private var renamePresented = false
    @State private var renameText = ""
    @State private var photoSaveMessage: String?
    @State private var photoSaved = false
    @State private var textCopied = false
    /// 文件内容只是一个网址：第一个按钮改成「打开链接」
    @State private var webLink: URL?
    /// 小文本的开头几行：简介页上直接给看，不用再点预览
    @State private var textSnippet: String?
    @State private var filesExportURLs: [URL] = []
    @State private var savedToFiles = false
    @State private var photoSaveNeedsSettings = false
    @State private var renameFailed = false
    @State private var mediaDetail: MediaDetail?
    /// zip 里的文件列表：存到「文件」之前先看看里面有什么
    @State private var zipListing: ZipListing?
    /// 物理重命名会改变文件名（即 id），用本地状态跟踪当前文件
    @State private var trackedFileName: String

    init(
        store: ReceivedFileCacheStore,
        initialFile: CachedReceivedFile,
        onShare: @escaping (URL) -> Void,
        onPreview: @escaping (URL) -> Void,
        onClose: (() -> Void)? = nil,
        onRenamed: ((CachedReceivedFile) -> Void)? = nil
    ) {
        self.store = store
        self.initialFile = initialFile
        self.onShare = onShare
        self.onPreview = onPreview
        self.onClose = onClose
        self.onRenamed = onRenamed
        _trackedFileName = State(initialValue: initialFile.fileName)
    }

    /// 重命名等操作会刷新 store，这里始终取最新快照，避免展示旧显示名
    private var file: CachedReceivedFile {
        store.cachedFiles.first { $0.fileName == trackedFileName } ?? initialFile
    }

    /// 系统给出的类型名，如「PNG 图像」「PDF 文稿」
    private var kindDescription: String {
        UTType(filenameExtension: file.fileExtension)?.localizedDescription
            ?? file.fileExtension.uppercased()
    }

    private var canSaveToPhotos: Bool {
        PhotoLibrarySaver.canSave(extension: file.fileExtension)
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                actions
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            // 只有一个网址时也显示：点「打开链接」之前先看清要去哪
            if let textSnippet {
                Section("内容") {
                    Text(textSnippet)
                        .font(.callout)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }

            if let zipListing, zipListing.fileCount > 0 {
                Section {
                    ForEach(zipListing.names, id: \.self) { name in
                        Label {
                            Text((name as NSString).lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                    if zipListing.fileCount > zipListing.names.count {
                        Text("还有 \(zipListing.fileCount - zipListing.names.count) 个文件")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("压缩包里")
                } footer: {
                    Text("共 \(zipListing.fileCount) 个文件，解压后约 \(ByteCountFormatter.string(fromByteCount: zipListing.totalSize, countStyle: .file))")
                }
            }

            Section("信息") {
                LabeledContent("类型", value: kindDescription)
                LabeledContent("大小") {
                    Text(file.sizeDescription)
                        .monospacedDigit()
                }
                if let mediaDetail {
                    LabeledContent(mediaDetail.label) {
                        Text(mediaDetail.value)
                            .monospacedDigit()
                    }
                }
                LabeledContent("接收时间", value: file.receivedAt.formatted(date: .abbreviated, time: .shortened))
                // 开了「自动清理」时说清哪天删，免得文件莫名其妙不见了
                if let maxAge = store.retentionPolicy.maxAgeSeconds {
                    // 清理只在打开萤传时进行：已经过期还没删的，说「下次打开时」而不是写一个过去的日期
                    let due = file.receivedAt.addingTimeInterval(maxAge)
                    LabeledContent("自动清理", value: due > Date()
                        ? due.formatted(date: .abbreviated, time: .omitted)
                        : String(localized: "下次打开萤传时"))
                }
                // 发送端原名与当前文件名不同（重命名过/同名去重）时才值得展示
                if file.originalName != file.fileName {
                    LabeledContent("原始文件名") {
                        Text(file.originalName)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
                checksumRow
            }

            Section {
                Button(role: .destructive) {
                    // 回到列表后底部有「撤销」，这里不再二次确认。
                    // 文件一从列表移走，下面的 onChange 就会退出本页，这里不再单独 dismiss
                    store.deleteWithUndo(ids: [file.id], message: String(localized: "已删除「\(file.displayName)」"))
                } label: {
                    Label {
                        Text("删除文件")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        // 明确用内缩分组：iPad 分栏右栏里自动样式会变成通栏，操作按钮贴到两边
        .listStyle(.insetGrouped)
        .readableListWidth()
        .navigationTitle("简介")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: file.fileName) {
            await loadChecksum()
        }
        .task(id: file.fileName) {
            mediaDetail = await MediaDetail.load(for: file.url)
        }
        .task(id: file.fileName) {
            guard file.fileExtension.lowercased() == "zip" else {
                zipListing = nil
                return
            }
            let url = file.url
            zipListing = await Task.detached(priority: .userInitiated) { ZipListing.read(url) }.value
        }
        .task(id: file.fileName) {
            guard TextClipboard.canCopy(fileExtension: file.fileExtension, size: file.fileSize) else {
                webLink = nil
                textSnippet = nil
                // Word / PowerPoint / Excel：开头几段文字也直接给看
                if ["docx", "pptx", "xlsx"].contains(file.fileExtension.lowercased()),
                   SearchableText.canIndexDocument(fileExtension: file.fileExtension, size: file.fileSize) {
                    let url = file.url
                    textSnippet = await Task.detached(priority: .userInitiated) {
                        OfficeText.read(url).map { String($0.prefix(600)) }
                    }.value
                }
                return
            }
            let url = file.url
            let (link, snippet) = await Task.detached(priority: .userInitiated) {
                (TextClipboard.singleWebLink(url), TextClipboard.snippet(url))
            }.value
            webLink = link
            textSnippet = snippet
        }
        .onChange(of: store.cachedFiles) { files in
            // 文件被外部删除/清空后自动退出，避免变成预览分享全是死链的僵尸页。
            // （重命名场景不受影响：store.rename 先回调新文件名再发布新列表）
            if !files.contains(where: { $0.fileName == trackedFileName }) {
                if let onClose { onClose() } else { dismiss() }
            }
        }
        .filesExport(urls: $filesExportURLs) { _ in
            withAnimation { savedToFiles = true }
        }
        .alert("重命名", isPresented: $renamePresented) {
            TextField("文件名", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") {
                store.rename(file: file, to: renameText) { renamed in
                    if let renamed {
                        trackedFileName = renamed.fileName
                        onRenamed?(renamed)
                    } else {
                        renameFailed = true
                    }
                }
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        } message: {
            RenameHint(fileExtension: file.fileExtension)
        }
        .alert("没能重命名", isPresented: $renameFailed) {
            Button("好", role: .cancel) {}
        } message: {
            Text("换个名称试试")
        }
        .alert("没能存到相册", isPresented: Binding(
            get: { photoSaveMessage != nil },
            set: { if !$0 { photoSaveMessage = nil } }
        )) {
            if photoSaveNeedsSettings {
                Button("去设置") { AppSettingsOpener.open() }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(photoSaveMessage ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Button {
                onPreview(file.url)
            } label: {
                FileThumbnailView(
                    url: file.url,
                    cacheKey: "detail-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)",
                    cornerRadius: 20,
                    generationSide: 320
                )
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览")
            // 预览不了的类型（压缩包等）：图标只作展示，不变灰
            .allowsHitTesting(FilesExport.hasUsefulPreview(file.fileExtension))
            .accessibilityHidden(!FilesExport.hasUsefulPreview(file.fileExtension))

            Text(file.displayName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // 辅助功能字号下两列也放不下（按钮文字不折行，会被截掉），一行一个
            VStack(spacing: 10) { actionButtons }
        } else {
            // 大字号下四个并排放不下，改成两列
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    actionButtons
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Group {
            if let webLink {
                DetailActionButton(title: "打开链接", systemImage: "safari") {
                    openURL(webLink)
                }
                .accessibilityLabel("打开网址")
                .accessibilityHint(Text(verbatim: webLink.host ?? ""))
            } else if FilesExport.hasUsefulPreview(file.fileExtension) {
                DetailActionButton(title: "预览", systemImage: "eye") {
                    onPreview(file.url)
                }
            }
            DetailActionButton(title: "分享", systemImage: "square.and.arrow.up") {
                onShare(file.url)
            }
            if canSaveToPhotos {
                DetailActionButton(
                    title: photoSaved ? "已存入" : "存相册",
                    systemImage: photoSaved ? "checkmark" : "photo.on.rectangle"
                ) {
                    Task { await saveToPhotos() }
                }
                .tint(photoSaved ? .green : nil)
                .allowsHitTesting(!photoSaved)
            } else if TextClipboard.canCopy(fileExtension: file.fileExtension, size: file.fileSize) {
                DetailActionButton(
                    title: textCopied ? "已复制" : "复制文字",
                    systemImage: textCopied ? "checkmark" : "doc.on.doc"
                ) {
                    Task {
                        if await TextClipboard.copy(file.url) {
                            withAnimation { textCopied = true }
                        }
                    }
                }
                .tint(textCopied ? .green : nil)
            } else {
                DetailActionButton(
                    title: savedToFiles ? "已存入" : "存到文件",
                    systemImage: savedToFiles ? "checkmark" : "folder"
                ) {
                    filesExportURLs = [file.url]
                }
                .tint(savedToFiles ? .green : nil)
                .accessibilityLabel(savedToFiles ? "已存入「文件」" : "存到「文件」")
            }
            DetailActionButton(title: "重命名", systemImage: "pencil") {
                renameText = file.renameStem
                renamePresented = true
            }
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
            LabeledContent("SHA-256", value: String(localized: "计算失败"))
        } else {
            LabeledContent("SHA-256") {
                ProgressView()
            }
        }
    }

    private func loadChecksum() async {
        checksumFailed = false
        // 缓存的校验值只有在文件内容自接收后未被外部改动时才可信
        if let cached = ReceivedFileMetadataStore.shared.metadata(for: file.fileName)?.sha256,
           file.modifiedAt <= file.receivedAt.addingTimeInterval(2) {
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
        } catch is CancellationError {
            // 用户离开页面，.task 被取消——不是失败
        } catch {
            checksumFailed = true
        }
    }

    /// 流式计算，支持大文件而不占内存；随宿主 .task 的取消而中止
    private static func computeSHA256(url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool {
                try handle.read(upToCount: 1 << 20)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            // 大文件哈希让出协作池线程，避免长期独占
            await Task.yield()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private func saveToPhotos() async {
        do {
            try await PhotoLibrarySaver.save(fileURL: file.url)
            PhotoLibrarySaver.savedPaths.insert(file.url.path)
            withAnimation { photoSaved = true }
        } catch {
            photoSaveNeedsSettings = PhotoLibrarySaver.isPermissionDenied(error)
            photoSaveMessage = (error as? LocalizedError)?.errorDescription ?? String(localized: "保存失败")
        }
    }
}

/// 简介页顶部的图标 + 文字操作块（类似「通讯录」联系人页的快捷操作）
private struct DetailActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void
    /// 各图标高矮不一（doc.on.doc 比 eye 高），统一图标区高度让下面的字对齐；随字号放大
    @ScaledMetric(relativeTo: .title3) private var iconHeight: CGFloat = 28

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(height: iconHeight)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(.tint)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
    }
}

/// 简介页里按类型多给一行：图片尺寸、音视频时长、PDF 页数
struct MediaDetail: Equatable {
    let label: String
    let value: String

    static func load(for url: URL) async -> MediaDetail? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) {
            return await Task.detached(priority: .utility) { imageSize(url) }.value
        }
        if type.conforms(to: .audiovisualContent) {
            return await duration(url)
        }
        if type.conforms(to: .pdf) {
            return await Task.detached(priority: .utility) { pageCount(url) }.value
        }
        return nil
    }

    private static func imageSize(_ url: URL) -> MediaDetail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF 方向 5–8 是转了 90°，看到的宽高要对调
        let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let (w, h) = rotated ? (height, width) : (width, height)
        return MediaDetail(label: String(localized: "尺寸"), value: "\(w) × \(h)")
    }

    private static func duration(_ url: URL) async -> MediaDetail? {
        guard let time = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        let value = Duration.seconds(seconds.rounded()).formatted(.time(pattern: pattern))
        return MediaDetail(label: String(localized: "时长"), value: value)
    }

    private static func pageCount(_ url: URL) -> MediaDetail? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        return MediaDetail(label: String(localized: "页数"), value: "\(document.numberOfPages)")
    }
}
