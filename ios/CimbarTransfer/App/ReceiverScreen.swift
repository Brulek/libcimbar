import SwiftUI

private enum ScanState: Equatable {
    case idle
    case detecting
}

struct ReceiverScreen: View {
    @ObservedObject var viewModel: NativeReceiverViewModel
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void

    @State private var showCheckmark = false
    @State private var lastCelebratedURL: URL?
    @State private var focusIndicatorPoint: CGPoint?
    @State private var focusIndicatorID = UUID()

    // 动态字体放大时，顶部标题区/底部面板占用更多空间，取景框预留区随之缩放
    @ScaledMetric(relativeTo: .body) private var topReservedHeight: CGFloat = 110
    @ScaledMetric(relativeTo: .body) private var bottomReservedHeight: CGFloat = 180

    private var scanState: ScanState {
        if viewModel.progressValue != nil && viewModel.receivedFileURL == nil {
            return .detecting
        }
        return .idle
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
                .accessibilityLabel("相机预览，轻点对焦，捏合缩放")
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
                    }
                }

            VStack(spacing: 18) {
                ReceiverTopBar(
                    zoomFactor: viewModel.zoomFactor,
                    torchAvailable: viewModel.torchAvailable,
                    torchActive: viewModel.torchActive,
                    onResetZoom: { viewModel.resetZoom() },
                    onToggleTorch: { viewModel.toggleTorch() }
                )
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
        }
        .safeAreaInset(edge: .bottom) {
            ReceiverBottomPanel(
                statusText: viewModel.statusText,
                progressValue: viewModel.progressValue,
                progressLabel: viewModel.progressLabel,
                statsText: viewModel.statsText,
                stallHint: viewModel.stallHint,
                receivedFileURL: viewModel.receivedFileURL,
                showCheckmark: showCheckmark,
                onShare: onShare,
                onPreview: onPreview,
                onContinueScanning: resetScan
            )
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
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

private struct ReceiverTopBar: View {
    let zoomFactor: CGFloat
    let torchAvailable: Bool
    let torchActive: Bool
    let onResetZoom: () -> Void
    let onToggleTorch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("萤传")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("对准发送端动画码")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()

            if zoomFactor > 1.01 {
                Button(action: onResetZoom) {
                    Text(String(format: "%.1f×", zoomFactor))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.yellow)
                        .frame(height: 44)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前变焦 \(String(format: "%.1f", zoomFactor)) 倍，点按恢复 1 倍")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if torchAvailable {
                Button(action: onToggleTorch) {
                    Image(systemName: torchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .foregroundStyle(torchActive ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .stroke(Color.yellow, lineWidth: 1.5)
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

private struct ReceiverBottomPanel: View {
    let statusText: String
    let progressValue: Double?
    let progressLabel: String?
    let statsText: String?
    let stallHint: String?
    let receivedFileURL: URL?
    let showCheckmark: Bool
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void
    let onContinueScanning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let file = receivedFileURL {
                CompletedTransferCard(
                    fileURL: file,
                    highlightShareAction: showCheckmark,
                    onPreview: { onPreview(file) },
                    onShare: { onShare(file) },
                    onContinueScanning: onContinueScanning
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                StatusCapsule(text: statusText)
                ProgressCard(
                    progressValue: progressValue,
                    progressLabel: progressLabel,
                    statsText: statsText,
                    stallHint: stallHint
                )
            }
        }
        .padding(16)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: receivedFileURL != nil)
    }
}

private struct ProgressCard: View {
    let progressValue: Double?
    let progressLabel: String?
    let statsText: String?
    let stallHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = progressValue {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .tint(stallHint == nil ? .accentColor : .orange)
            } else {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .opacity(progressLabel == nil ? 0.45 : 0.7)
            }
            Text(progressLabel ?? "等待识别动画码")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let stats = statsText {
                Text(stats)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            if let hint = stallHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.25), value: stallHint)
        .accessibilityElement(children: .combine)
        .accessibilityValue([progressLabel ?? "等待识别", statsText, stallHint].compactMap { $0 }.joined(separator: "，"))
    }
}

private struct CompletedTransferCard: View {
    let fileURL: URL
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

    private var canSaveToPhotos: Bool {
        PhotoLibrarySaver.canSave(extension: fileURL.pathExtension)
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
            HStack(spacing: 12) {
                FileThumbnailView(
                    url: fileURL,
                    cacheKey: thumbnailKey.isEmpty ? "completed-\(fileURL.lastPathComponent)" : thumbnailKey
                )
                .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(fileURL.lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(fileSize ?? "已接收")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }

            HStack(spacing: 10) {
                Button(action: onPreview) {
                    Label("查看", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                if canSaveToPhotos {
                    Button {
                        Task { await saveToPhotos() }
                    } label: {
                        Label(photoSaved ? "已保存" : "存相册", systemImage: photoSaved ? "checkmark" : "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(photoSaved ? .green : nil)
                    .disabled(photoSaving || photoSaved)
                }

                Button(action: onShare) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(highlightShareAction ? .green : .accentColor)
            }
            .labelStyle(CompactActionLabelStyle())

            Button(action: onContinueScanning) {
                Label("继续扫码", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .task(id: fileURL) {
            let info = Self.loadFileInfo(for: fileURL)
            fileSize = info.size
            thumbnailKey = "completed-\(fileURL.lastPathComponent)-\(info.modified)"
            photoSaving = false
            photoSaved = false
            photoSaveError = nil
        }
        .alert("存到相册失败", isPresented: Binding(
            get: { photoSaveError != nil },
            set: { if !$0 { photoSaveError = nil } }
        )) {
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
            photoSaveError = (error as? LocalizedError)?.errorDescription ?? "保存失败"
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
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.7))
            Text("未授予相机权限")
                .font(.headline)
                .foregroundStyle(.white)
            Text("需要相机权限来扫描 Cimbar 动画码接收文件")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("打开设置", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct StatusCapsule: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thickMaterial, in: Capsule())
        .accessibilityLabel(text)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct ScanFrameOverlay: View {
    let topReservedHeight: CGFloat
    let bottomReservedHeight: CGFloat
    var scanState: ScanState = .idle
    var showCheckmark: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(proxy.size.height - topReservedHeight - bottomReservedHeight, 260)
            let side = min(proxy.size.width - 16, availableHeight)
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

    private var fireflyColor: Color {
        if showCheckmark { return .green }
        switch scanState {
        case .idle:      return Color(red: 1.0, green: 0.86, blue: 0.32)
        case .detecting: return Color(red: 0.55, green: 1.0, blue: 0.55)
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
                    .stroke(fireflyColor.opacity(0.55), lineWidth: 1.5)
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
                        .stroke(fireflyColor.opacity(0.18), lineWidth: 1)
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
