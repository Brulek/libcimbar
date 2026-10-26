import SwiftUI

private enum ScanState: Equatable {
    case idle
    case detecting
}

struct ReceiverScreen: View {
    @ObservedObject var viewModel: NativeReceiverViewModel
    @ObservedObject private var preferences = AppPreferences.shared
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void

    @State private var showCheckmark = false
    @State private var lastCelebratedURL: URL?
    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorID = UUID()
    @State private var showingSenderHelp = false

    // 底部面板通过 safeAreaInset 已从取景区扣除，这里只需让出顶部按钮行；
    // 动态字体放大时按钮变高，预留随之缩放
    @ScaledMetric(relativeTo: .body) private var topReservedHeight: CGFloat = 64
    private let bottomReservedHeight: CGFloat = 20

    private var scanState: ScanState {
        viewModel.isTracking && viewModel.receivedFileURL == nil ? .detecting : .idle
    }

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: viewModel.session,
                onTapToFocus: { devicePoint, viewPoint in
                    viewModel.focus(atDevicePoint: devicePoint)
                    presentFocusIndicator(at: viewPoint)
                },
                onPinchBegan: { viewModel.beginZoomGesture() },
                onPinchChanged: { viewModel.updateZoomGesture(scale: $0) },
                onDoubleTap: { viewModel.resetZoom() }
            )
                .ignoresSafeArea()
                .accessibilityLabel("相机取景，轻点对焦，捏合缩放")
                .accessibilityElement(children: .ignore)
                .overlay {
                    ScanFrameOverlay(
                        topReservedHeight: topReservedHeight,
                        bottomReservedHeight: bottomReservedHeight,
                        scanState: scanState,
                        showCheckmark: showCheckmark
                    )
                }
                .overlay {
                    if let point = focusIndicatorPoint {
                        FocusIndicatorView()
                            .position(point)
                            .id(focusIndicatorID)
                    }
                }
                .overlay {
                    if viewModel.cameraPermissionDenied {
                        PermissionDeniedCard()
                            .padding(.horizontal, 24)
                    }
                }

            VStack {
                ReceiverTopBar(
                    decodeMode: $preferences.decodeMode,
                    highResolution: $preferences.highResolutionCapture,
                    detectedMode: viewModel.detectedMode,
                    zoomFactor: viewModel.zoomFactor,
                    torchAvailable: viewModel.torchAvailable,
                    torchActive: viewModel.torchActive,
                    onResetZoom: { viewModel.resetZoom() },
                    onToggleTorch: { viewModel.toggleTorch() }
                )
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.cameraPermissionDenied {
                ReceiverBottomPanel(
                    viewModel: viewModel,
                    showCheckmark: showCheckmark,
                    onShare: onShare,
                    onPreview: onPreview,
                    onContinueScanning: resetScan,
                    onShowSenderHelp: { showingSenderHelp = true }
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .background(Color.black)
        // 相机界面始终用深色外观，与取景画面一致，不跟随系统浅色
        .environment(\.colorScheme, .dark)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSenderHelp) {
            SenderHelpSheet()
        }
        .task {
            viewModel.start()
        }
        .task(id: viewModel.receivedFileURL) {
            await updateCompletionState(for: viewModel.receivedFileURL)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private func resetScan() {
        withAnimation {
            viewModel.resetScan()
        }
    }

    private func presentFocusIndicator(at point: CGPoint) {
        let id = UUID()
        focusIndicatorID = id
        focusIndicatorPoint = point
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if focusIndicatorID == id {
                withAnimation(.easeOut(duration: 0.2)) {
                    focusIndicatorPoint = nil
                }
            }
        }
    }

    private func updateCompletionState(for fileURL: URL?) async {
        guard let fileURL else {
            lastCelebratedURL = nil
            withAnimation {
                showCheckmark = false
            }
            return
        }

        // .task(id:) 在每次页面出现时都会重跑；同一个文件只庆祝一次，
        // 避免切走再切回时重放 2.5 秒打勾动画。庆祝中途切走会取消收尾的
        // sleep，重进时必须补上 showCheckmark 复位，否则绿勾永久卡住
        guard fileURL != lastCelebratedURL else {
            withAnimation { showCheckmark = false }
            return
        }
        lastCelebratedURL = fileURL

        withAnimation(.spring(duration: 0.4)) {
            showCheckmark = true
        }

        do {
            try await Task.sleep(nanoseconds: 2_500_000_000)
        } catch {
            return
        }

        guard !Task.isCancelled else { return }

        withAnimation {
            showCheckmark = false
        }
    }
}

// MARK: - 顶部按钮

private struct ReceiverTopBar: View {
    @Binding var decodeMode: Int
    @Binding var highResolution: Bool
    let detectedMode: Int
    let zoomFactor: CGFloat
    let torchAvailable: Bool
    let torchActive: Bool
    let onResetZoom: () -> Void
    let onToggleTorch: () -> Void

    @ScaledMetric(relativeTo: .body) private var buttonSide: CGFloat = 44

    /// 自动模式识别出发送端模式后显示「自动 · B」，方便核对
    private var modeTitle: String {
        guard let mode = DecodeMode(rawValue: decodeMode) else { return "" }
        if mode == .auto, detectedMode != DecodeMode.auto.rawValue,
           let detected = DecodeMode.code(for: detectedMode) {
            return String(localized: "自动 · \(detected)")
        }
        return mode.code
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("解码模式", selection: $decodeMode) {
                    ForEach(DecodeMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Toggle(isOn: $highResolution) {
                    Label("高清采集", systemImage: "camera.aperture")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dot.viewfinder")
                    Text(modeTitle)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: buttonSide)
                .glassChrome(in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel("解码模式")
            .accessibilityValue(modeTitle)

            Spacer()

            if zoomFactor > 1.01 {
                Button(action: onResetZoom) {
                    Text(String(format: "%.1f×", zoomFactor))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Brand.glow)
                        .padding(.horizontal, 12)
                        .frame(height: buttonSide)
                        .glassChrome(in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("变焦 \(String(format: "%.1f", zoomFactor)) 倍")
                .accessibilityHint("轻点恢复 1 倍")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if torchAvailable {
                Button(action: onToggleTorch) {
                    Image(systemName: torchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .foregroundStyle(torchActive ? Brand.glow : .white)
                        .frame(width: buttonSide, height: buttonSide)
                        .glassChrome(in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(torchActive ? "关闭手电筒" : "打开手电筒")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: zoomFactor > 1.01)
        .animation(.easeInOut(duration: 0.2), value: torchActive)
    }
}

private struct FocusIndicatorView: View {
    @State private var appeared = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Brand.glow, lineWidth: 1.5)
            .frame(width: 68, height: 68)
            .scaleEffect(appeared ? 1.0 : 1.45)
            .opacity(appeared ? 1.0 : 0.4)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .onAppear {
                withAnimation(.spring(duration: 0.3)) {
                    appeared = true
                }
            }
            .allowsHitTesting(false)
    }
}

// MARK: - 底部面板

private struct ReceiverBottomPanel: View {
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

    private var footnote: String {
        if !isTracking {
            return String(localized: "动画码已离开取景框，对准后继续")
        }
        return String(localized: "已识别 \(frameCount) 帧")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(percentText)
                    .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("正在接收")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let remainingText {
                    Text(remainingText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(stallHint == nil ? Color.accentColor : .orange)

            if let stallHint {
                Label(stallHint, systemImage: "exclamationmark.triangle.fill")
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
        .accessibilityValue([percentText, remainingText, stallHint ?? footnote].compactMap { $0 }.joined(separator: String(localized: "，")))
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
        if let duration, duration >= 1 {
            let formatted = Duration.seconds(duration.rounded())
                .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            parts.append(String(localized: "用时 \(formatted)"))
        }
        return parts.isEmpty ? String(localized: "已收到") : parts.joined(separator: " · ")
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

            HStack(spacing: 10) {
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
        .minimumScaleFactor(0.8)
    }
}

private struct PermissionDeniedCard: View {
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

// MARK: - 发送端说明

struct SenderHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private static let senderURL = URL(string: "https://cimbar.org")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StepRow(number: 1, text: "在电脑或另一台手机的浏览器里打开 cimbar.org")
                    StepRow(number: 2, text: "打开网页菜单，点 Find File 选择文件，也可以直接把文件拖进网页")
                    StepRow(number: 3, text: "网页开始播放动画码后，用萤传对准它，进度到 100% 即完成")
                } footer: {
                    Text("网页菜单里的 Mode 保持默认即可，萤传会自动识别。")
                }

                Section {
                    Button {
                        UIPasteboard.general.url = Self.senderURL
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "已复制网址" : "复制网址", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: Self.senderURL) {
                        Label("把网址发给发送方", systemImage: "square.and.arrow.up")
                    }
                }

                Section("收不到时") {
                    Label("靠近些，让动画码占满大部分取景框", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("调亮发送端屏幕，避开灯光反光", systemImage: "sun.max")
                    Label("在网页菜单里调低 Framerate", systemImage: "speedometer")
                }
                .font(.subheadline)
            }
            .navigationTitle("怎么发送文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Brand.ink)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 取景框

private struct ScanFrameOverlay: View {
    let topReservedHeight: CGFloat
    let bottomReservedHeight: CGFloat
    var scanState: ScanState = .idle
    var showCheckmark: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(proxy.size.height - topReservedHeight - bottomReservedHeight, 200)
            let side = min(proxy.size.width - 32, availableHeight, 520)
            let centerY = topReservedHeight + availableHeight / 2
            let center = CGPoint(x: proxy.size.width / 2, y: centerY)
            let cornerRadius = max(28, side * 0.08)

            FireflyScanFrame(
                side: side,
                cornerRadius: cornerRadius,
                scanState: scanState,
                showCheckmark: showCheckmark
            )
            .position(center)
            .animation(.easeInOut(duration: 0.4), value: scanState)
            .animation(.easeInOut(duration: 0.4), value: showCheckmark)
        }
        .allowsHitTesting(false)
    }
}

private struct FireflyScanFrame: View {
    let side: CGFloat
    let cornerRadius: CGFloat
    let scanState: ScanState
    let showCheckmark: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trailCount: Int = 16
    /// 萤火虫光晕（44pt + blur）伸出边框的距离
    private static let glowOutset: CGFloat = 40

    private var fireflyColor: Color {
        if showCheckmark { return .green }
        switch scanState {
        case .idle:      return Brand.glow
        case .detecting: return Brand.signal
        }
    }

    private var orbitPeriod: Double {
        switch scanState {
        case .idle:      return 5.5
        case .detecting: return 2.6
        }
    }

    var body: some View {
        if reduceMotion {
            // 「减弱动态效果」下不跑 60fps 环绕动画，用静态描边表达同样的状态色
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(fireflyColor.opacity(0.6), lineWidth: 1.5)
                    .frame(width: side, height: side)
                checkmarkOverlay
            }
            .frame(width: side, height: side)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: showCheckmark)) { context in
                let t = (context.date.timeIntervalSinceReferenceDate / orbitPeriod * 4)
                    .truncatingRemainder(dividingBy: 4)

                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(fireflyColor.opacity(0.28), lineWidth: 1)
                        .frame(width: side, height: side)

                    if !showCheckmark {
                        fireflySwarm(t: t)
                    }

                    checkmarkOverlay
                }
                .frame(width: side, height: side)
            }
        }
    }

    @ViewBuilder
    private var checkmarkOverlay: some View {
        if showCheckmark {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
                .shadow(color: .green.opacity(0.6), radius: 10)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func fireflySwarm(t: Double) -> some View {
        ZStack {
            ForEach(0..<trailCount, id: \.self) { i in
                let lag = Double(i) * 0.035
                let phase = ((t - lag) + 4).truncatingRemainder(dividingBy: 4)
                let pos = perimeterPoint(t: phase)
                let progress = Double(i) / Double(trailCount)
                let size = 9.0 - progress * 6.0
                let alpha = (1.0 - progress) * 0.55
                Circle()
                    .fill(fireflyColor)
                    .frame(width: size, height: size)
                    .blur(radius: 1.5 + progress * 4.5)
                    .opacity(alpha)
                    .offset(x: pos.x, y: pos.y)
            }

            Firefly(color: fireflyColor)
                .offset(x: perimeterPoint(t: t).x,
                        y: perimeterPoint(t: t).y)
        }
        // drawingGroup 会按自身尺寸裁剪：不撑开到取景框 + 光晕外延，
        // ZStack 只有萤火虫本身 44pt 大，偏移到边框上的光点全部被裁掉
        .frame(width: side + Self.glowOutset * 2, height: side + Self.glowOutset * 2)
        // 16 个独立 blur 是 16 次离屏渲染；合并成单个 Metal 图层后一次完成
        .drawingGroup()
    }

    private func perimeterPoint(t: Double) -> CGPoint {
        let half = side / 2
        let r = min(cornerRadius, half)
        let straight = max(side - 2 * r, 0)
        let arc = (.pi / 2) * r
        let total = 4 * straight + 4 * arc
        guard total > 0 else { return .zero }
        var d = (t / 4) * total

        // Top straight: left → right
        if d < straight {
            return CGPoint(x: -half + r + d, y: -half)
        }
        d -= straight
        // Top-right arc: -π/2 → 0
        if d < arc {
            let a = d / r - .pi / 2
            return CGPoint(x: half - r + cos(a) * r, y: -half + r + sin(a) * r)
        }
        d -= arc
        // Right straight: top → bottom
        if d < straight {
            return CGPoint(x: half, y: -half + r + d)
        }
        d -= straight
        // Bottom-right arc: 0 → π/2
        if d < arc {
            let a = d / r
            return CGPoint(x: half - r + cos(a) * r, y: half - r + sin(a) * r)
        }
        d -= arc
        // Bottom straight: right → left
        if d < straight {
            return CGPoint(x: half - r - d, y: half)
        }
        d -= straight
        // Bottom-left arc: π/2 → π
        if d < arc {
            let a = d / r + .pi / 2
            return CGPoint(x: -half + r + cos(a) * r, y: half - r + sin(a) * r)
        }
        d -= arc
        // Left straight: bottom → top
        if d < straight {
            return CGPoint(x: -half, y: half - r - d)
        }
        d -= straight
        // Top-left arc: π → 3π/2
        let a = d / r + .pi
        return CGPoint(x: -half + r + cos(a) * r, y: -half + r + sin(a) * r)
    }
}

private struct Firefly: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: 44, height: 44)
                .blur(radius: 12)
            Circle()
                .fill(color.opacity(0.85))
                .frame(width: 18, height: 18)
                .blur(radius: 3)
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
        }
    }
}
