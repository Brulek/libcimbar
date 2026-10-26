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
                    frameCount: viewModel.detectedFrameCount,
                    remainingSeconds: viewModel.remainingSeconds,
                    stallHint: viewModel.stallHint
                )
                .transition(.opacity)
            } else {
                WaitingCard(
                    cameraError: viewModel.cameraErrorText,
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
        .animation(.easeInOut(duration: 0.25), value: viewModel.progressValue == nil)
    }
}

private struct WaitingCard: View {
    let cameraError: String?
    let onShowSenderHelp: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let cameraError {
                    Label(cameraError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text("对准屏幕上的动画码")
                        .font(.headline)
                }
                Text("发送方用浏览器打开 cimbar.org，选好文件即可")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onShowSenderHelp) {
                Image(systemName: "questionmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
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
    let frameCount: Int
    let remainingSeconds: Int?
    let stallHint: String?

    private var percentText: String {
        progress.formatted(.percent.precision(.fractionLength(0)))
    }

    private var remainingText: String? {
        guard isTracking, let remainingSeconds else { return nil }
        if remainingSeconds < 90 {
            return String(localized: "还需约 \(remainingSeconds) 秒")
        }
        let minutes = Int((Double(remainingSeconds) / 60).rounded())
        return String(localized: "还需约 \(minutes) 分钟")
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(percentText)
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
            Text("正在接收")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var remaining: some View {
        if let remainingText {
            Text(remainingText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .transition(.opacity)
        }
    }

    private var footnote: String {
        if !isTracking {
            return String(localized: "暂时读不到动画码，保持对准")
        }
        return String(localized: "已识别 \(frameCount) 帧")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 大字号下一行放不下时，剩余时间换到下一行
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    headline
                    Spacer()
                    remaining
                }
                VStack(alignment: .leading, spacing: 4) {
                    headline
                    remaining
                }
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(stallHint == nil && cameraError == nil ? Color.accentColor : .orange)

            if let warning = cameraError ?? stallHint {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            } else {
                Text(footnote)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: stallHint)
        .animation(.easeInOut(duration: 0.25), value: isTracking)
        .animation(.easeOut(duration: 0.2), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在接收")
        .accessibilityValue([percentText, remainingText, cameraError ?? stallHint ?? footnote].compactMap { $0 }.joined(separator: String(localized: "，")))
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

    private var canSaveToPhotos: Bool {
        PhotoLibrarySaver.canSave(extension: fileURL.pathExtension)
    }

    private var detailText: String {
        var parts: [String] = []
        if let fileSize { parts.append(fileSize) }
        if isDuplicate {
            parts.append(String(localized: "刚才已收到，没有重复保存"))
        } else if let duration, duration >= 1 {
            let formatted = Duration.seconds(duration.rounded())
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            parts.append(String(localized: "用时 \(formatted)"))
        }
        return parts.isEmpty ? String(localized: "已收到") : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: onPreview) {
            Label("预览", systemImage: "eye")
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.bordered)

        if canSaveToPhotos {
            Button {
                Task { await saveToPhotos() }
            } label: {
                Label(photoSaved ? "已存入" : "存相册", systemImage: photoSaved ? "checkmark" : "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            .tint(photoSaved ? .green : nil)
            .disabled(photoSaving || photoSaved)
        }

        Button(action: onShare) {
            Label("分享", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(Brand.ink)
        }
        .buttonStyle(.borderedProminent)
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
            .accessibilityHint("轻点预览")

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
            photoSaved = false
            photoSaveError = nil
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
        do {
            try await PhotoLibrarySaver.save(fileURL: fileURL)
            withAnimation { photoSaved = true }
        } catch {
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
            Text("一段时间没有扫到动画码，已关闭相机省电。")
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
