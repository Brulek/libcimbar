import SwiftUI

struct ReceiverBottomPanel: View {
    @ObservedObject var viewModel: NativeReceiverViewModel
    let showCheckmark: Bool
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void
    let onContinueScanning: () -> Void
    let onShowSenderHelp: () -> Void

    var body: some View {
        Group {
            if let file = viewModel.receivedFileURL {
                CompletedTransferCard(
                    fileURL: file,
                    duration: viewModel.transferDuration,
                    isDuplicate: viewModel.receivedDuplicate,
                    highlightShareAction: showCheckmark,
                    onPreview: { onPreview(file) },
                    onShare: { onShare(file) },
                    onContinueScanning: onContinueScanning
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if viewModel.scanErrorLatched {
                // 喷泉流已在 sink 中标记完成、无法重放，只有重扫能恢复
                ScanErrorCard(message: viewModel.statusText, onRetry: onContinueScanning)
                    .transition(.opacity)
            } else if let progress = viewModel.progressValue {
                ProgressCard(
                    progress: progress,
                    cameraError: viewModel.cameraErrorText,
                    isTracking: viewModel.isTracking,
                    remainingSeconds: viewModel.remainingSeconds,
                    stallHint: viewModel.stallHint
                )
                .transition(.opacity)
            } else {
                WaitingCard(
                    cameraError: viewModel.cameraErrorText,
                    codeUnreadable: viewModel.codeUnreadable,
                    isManualMode: AppPreferences.shared.decodeMode != 0,
                    onShowSenderHelp: onShowSenderHelp
                )
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: 560)
        .glassChrome(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: viewModel.receivedFileURL != nil)
        .animation(.easeInOut(duration: 0.25), value: viewModel.scanErrorLatched)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isIdlePaused)
        .animation(.easeInOut(duration: 0.25), value: viewModel.codeUnreadable)
        .animation(.easeInOut(duration: 0.25), value: viewModel.progressValue == nil)
    }
}

private struct WaitingCard: View {
    let cameraError: String?
    var codeUnreadable = false
    var isManualMode = false
    let onShowSenderHelp: () -> Void

    private var subtitle: LocalizedStringKey {
        guard codeUnreadable else { return "发送方用浏览器打开 cimbar.org，选好文件即可" }
        // 手动选了模式、又一直读不出来，最可能是和网页不一致
        if isManualMode { return "解码模式和网页上的 Mode 不一致时读不出来，改成「自动识别」最省事" }
        // 很小的文件（比如只有一个网址）发送端会补一大片空白，现在的版本读不出来
        return "靠近些、调亮发送端屏幕。只发一个网址这类很短的文字时可能收不到，和别的文件打包再发"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let cameraError {
                    Label(cameraError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if codeUnreadable {
                    Text("看到了动画码，但读不出来")
                        .font(.headline)
                } else {
                    Text("对准屏幕上的动画码")
                        .font(.headline)
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onShowSenderHelp) {
                Image(systemName: "questionmark")
                    .font(.headline)
                    // 面板字号封顶在辅助功能第二档，按钮固定 44pt（最小点按尺寸）就够
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("怎么发送文件")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProgressCard: View {
    let progress: Double
    /// 传输中途相机被占用/过热，优先于停滞提示展示
    let cameraError: String?
    let isTracking: Bool
    let remainingSeconds: Int?
    let stallHint: String?

    /// 估算可能变长（码短暂离开、速率下降），数字滚动方向跟着变
    @State private var lastRemaining: Int?
    @State private var remainingFalling = true

    private var percentText: String {
        progress.formatted(.percent.precision(.fractionLength(0)))
    }

    /// 进度条下面只放一句当前最该知道的：剩余时间，或者该怎么做
    private var footnote: String {
        guard isTracking else { return String(localized: "暂时读不到动画码，保持对准") }
        guard let remainingSeconds else { return String(localized: "保持对准") }
        if remainingSeconds < 90 {
            return String(localized: "还需约 \(remainingSeconds) 秒")
        }
        let minutes = Int((Double(remainingSeconds) / 60).rounded())
        return String(localized: "还需约 \(minutes) 分钟")
    }

    private var footnoteKind: Int {
        guard isTracking else { return 0 }
        guard let remainingSeconds else { return 1 }
        return remainingSeconds < 90 ? 2 : 3
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 中等大小的文件每秒要跳好几个百分点，滚动数字动画一直播不完，
            // 看着总是糊的；直接换字最清楚
            Text(percentText)
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
            Text("正在接收")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        // 百分比变化时整行不做动画：数字从 9% 跳到 10% 变宽时，旁边的字若还在滑动会和数字叠在一起
        .animation(nil, value: percentText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(Brand.progressTint(isTracking: isTracking, hasWarning: stallHint != nil || cameraError != nil))

            if let warning = cameraError ?? stallHint {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            } else {
                Text(footnote)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    // 只有倒计时数字之间滚动；换成另一句话时整句淡入淡出，
                    // 否则逐字变形，中途是一串糊掉的字
                    .contentTransition(.numericText(countsDown: remainingFalling))
                    .id(footnoteKind)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: stallHint)
        .animation(.easeInOut(duration: 0.25), value: isTracking)
        .animation(.easeInOut(duration: 0.25), value: footnoteKind)
        .onChange(of: remainingSeconds) { newValue in
            if let newValue, let lastRemaining {
                remainingFalling = newValue <= lastRemaining
            }
            lastRemaining = newValue
        }
        .animation(.easeOut(duration: 0.2), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在接收")
        .accessibilityValue([percentText, cameraError ?? stallHint ?? footnote].joined(separator: String(localized: "，")))
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct ScanErrorCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .font(.subheadline.weight(.medium))

            Button(action: onRetry) {
                Label("重新扫描", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.brandPrimary)
        }
    }
}

private struct CompletedTransferCard: View {
    let fileURL: URL
    let duration: TimeInterval?
    let isDuplicate: Bool
    let highlightShareAction: Bool
    let onPreview: () -> Void
    let onShare: () -> Void
    let onContinueScanning: () -> Void

    // 状态缓存文件大小：body 可能因动画每秒重算多次，不能每次都读磁盘
    @State private var fileSize: String?
    // 缩略图缓存键必须含内容成分（mtime）：删除后重收同名文件会复用同一路径，
    // 纯文件名键会命中 NSCache 里旧文件的缩略图
    @State private var thumbnailKey: String = ""
    @State private var photoSaving = false
    @State private var photoSaved = false
    @State private var photoSaveError: String?
    @State private var photoSaveNeedsSettings = false
    @State private var canCopyText = false
    @State private var textCopied = false
    /// 收到的文本只是一个网址：第一个按钮改成「打开链接」（文字已经显示在取景框里，预览没有新东西）
    @State private var webLink: URL?
    @Environment(\.openURL) private var openURL
    @State private var filesExportURLs: [URL] = []
    @State private var savedToFiles = false

    private var canSaveToPhotos: Bool {
        PhotoLibrarySaver.canSave(extension: fileURL.pathExtension)
    }

    /// 压缩包、安装包、未知格式的系统预览只有一个图标和大小，点进去什么也做不了
    private var hasNoPreview: Bool {
        !FilesExport.hasUsefulPreview(fileURL.pathExtension)
    }

    private var detailText: String {
        var parts: [String] = []
        if let fileSize { parts.append(fileSize) }
        if isDuplicate {
            parts.append(String(localized: "已经收到过，没有重复保存"))
        } else if let duration, duration >= 1 {
            let formatted = Duration.seconds(duration.rounded())
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            parts.append(String(localized: "用时 \(formatted)"))
        }
        return parts.isEmpty ? String(localized: "已收到") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let webLink {
            Button {
                openURL(webLink)
            } label: {
                Label("打开链接", systemImage: "safari")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            // 英文按钮上只放得下 Open，由 Safari 图标表示打开的是网页；读屏读全称和网站
            .accessibilityLabel("打开网址")
            .accessibilityHint(Text(verbatim: webLink.host ?? ""))
        } else if !hasNoPreview {
            Button(action: onPreview) {
                Label("预览", systemImage: "eye")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
        }

        if canSaveToPhotos {
            Button {
                Task { await saveToPhotos() }
            } label: {
                Label(photoSaved ? "已存入" : "存相册", systemImage: photoSaved ? "checkmark" : "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            // 不能写 nil：nil 会退回资源里的强调色，强制深色+增强对比度时是深棕
            .tint(photoSaved ? .green : Brand.glow)
            // 存好后不再可点，但不用 disabled：灰掉的样子像出错，绿色对勾才像「完成了」
            .disabled(photoSaving)
            .allowsHitTesting(!photoSaved)
            // 按钮上只写「存相册」，读屏说全：英文里两个按钮都只有一个 Save
            .accessibilityLabel(photoSaved ? "已存到相册" : "存到相册")
            // 语音控制按看得见的字下指令：「存相册」也要认
            .accessibilityInputLabels(photoSaved ? [Text("已存入"), Text("已存到相册")] : [Text("存相册"), Text("存到相册")])
        } else if canCopyText {
            Button {
                Task {
                    if await TextClipboard.copy(fileURL) {
                        withAnimation { textCopied = true }
                    }
                }
            } label: {
                Label(textCopied ? "已复制" : "复制文字", systemImage: textCopied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(textCopied ? .green : Brand.glow)
        } else {
            Button {
                filesExportURLs = [fileURL]
            } label: {
                Label(savedToFiles ? "已存入" : "存到文件", systemImage: savedToFiles ? "checkmark" : "folder")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(savedToFiles ? .green : Brand.glow)
            // 英文按钮上只放得下 Save，由文件夹图标表示存到哪；读屏读全称
            .accessibilityLabel(savedToFiles ? "已存入「文件」" : "存到「文件」")
        }

        Button(action: onShare) {
            Label("分享", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(Brand.ink)
        }
        .buttonStyle(.borderedProminent)
        .tint(Brand.fill)
        .scaleEffect(highlightShareAction ? 1.03 : 1)
    }

    private static func loadFileInfo(for url: URL) -> (size: String?, modified: TimeInterval) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return (nil, 0)
        }
        let size = (attrs[.size] as? NSNumber).map {
            ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file)
        }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, modified)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onPreview) {
                HStack(spacing: 12) {
                    FileThumbnailView(
                        url: fileURL,
                        cacheKey: thumbnailKey.isEmpty ? "completed-\(fileURL.lastPathComponent)" : thumbnailKey
                    )
                    .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fileURL.lastPathComponent)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Text(detailText)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("已收到 \(fileURL.lastPathComponent)")
            .accessibilityValue(detailText)
            // 预览不了的（压缩包等）点了去「我的文件」看简介
            .accessibilityHint(hasNoPreview ? Text("查看文件简介") : Text("打开预览"))

            // 大字号下三个按钮并排放不下，改为竖排，不截断文字
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(spacing: 8) { actionButtons }
            }
            .labelStyle(CompactActionLabelStyle())
            .font(.subheadline.weight(.semibold))

            Button(action: onContinueScanning) {
                Label("继续接收", systemImage: "viewfinder")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .animation(.spring(duration: 0.35), value: highlightShareAction)
        .task(id: fileURL) {
            let info = Self.loadFileInfo(for: fileURL)
            fileSize = info.size
            thumbnailKey = "completed-\(fileURL.lastPathComponent)-\(info.modified)"
            photoSaving = false
            photoSaved = PhotoLibrarySaver.savedPaths.contains(fileURL.path)
            photoSaveError = nil
            canCopyText = TextClipboard.canCopy(fileURL)
            textCopied = false
            let url = fileURL
            webLink = canCopyText
                ? await Task.detached(priority: .userInitiated) { TextClipboard.singleWebLink(url) }.value
                : nil
            savedToFiles = false
            if AppPreferences.shared.autoSaveToPhotos, canSaveToPhotos, !isDuplicate, !photoSaved {
                await saveToPhotos()
            }
        }
        .filesExport(urls: $filesExportURLs) { _ in
            withAnimation { savedToFiles = true }
        }
        .alert("没能存到相册", isPresented: Binding(
            get: { photoSaveError != nil },
            set: { if !$0 { photoSaveError = nil } }
        )) {
            if photoSaveNeedsSettings {
                Button("去设置") { AppSettingsOpener.open() }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(photoSaveError ?? "")
        }
    }

    @MainActor
    private func saveToPhotos() async {
        photoSaving = true
        defer { photoSaving = false }
        // 先登记再存：存的过程中卡片若被重建，不会再发起第二次
        PhotoLibrarySaver.savedPaths.insert(fileURL.path)
        do {
            try await PhotoLibrarySaver.save(fileURL: fileURL)
            withAnimation { photoSaved = true }
        } catch {
            PhotoLibrarySaver.savedPaths.remove(fileURL.path)
            photoSaveNeedsSettings = PhotoLibrarySaver.isPermissionDenied(error)
            photoSaveError = (error as? LocalizedError)?.errorDescription ?? String(localized: "保存失败")
        }
    }
}

/// 三个按钮并排时空间紧张，压缩 Label 的图文间距
private struct CompactActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// 空闲自动暂停后显示在取景框中间
struct IdlePausedCard: View {
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Brand.glow)
            Text("扫描已暂停")
                .font(.headline)
            Text("一段时间没有扫到动画码，已关闭相机省电")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onResume) {
                Label("继续扫描", systemImage: "play.fill")
            }
            .buttonStyle(.brandPrimary)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 320)
        .glassChrome(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct PermissionDeniedCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(Brand.glow)
            Text("需要相机权限")
                .font(.headline)
            Text("萤传通过相机读取屏幕上的动画码，画面不会离开这台设备。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("去设置开启") { AppSettingsOpener.open() }
                .buttonStyle(.brandPrimary)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .glassChrome(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
