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

    private var scanState: ScanState {
        if viewModel.progressValue != nil && viewModel.receivedFileURL == nil {
            return .detecting
        }
        return .idle
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: viewModel.session)
                .ignoresSafeArea()
                .accessibilityLabel("相机预览")
                .accessibilityElement(children: .ignore)
                .overlay {
                    ScanFrameOverlay(
                        topReservedHeight: 110,
                        bottomReservedHeight: 180,
                        scanState: scanState,
                        showCheckmark: showCheckmark
                    )
                }
                .overlay {
                    if viewModel.cameraPermissionDenied {
                        PermissionDeniedCard()
                    }
                }

            VStack(spacing: 18) {
                ReceiverTopBar()
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

    private func updateCompletionState(for fileURL: URL?) async {
        guard fileURL != nil else {
            withAnimation {
                showCheckmark = false
            }
            return
        }

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
        }
    }
}

private struct ReceiverBottomPanel: View {
    let statusText: String
    let progressValue: Double?
    let progressLabel: String?
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
                ProgressCard(progressValue: progressValue, progressLabel: progressLabel)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = progressValue {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            } else {
                ProgressView(value: 0)
                    .progressViewStyle(.linear)
                    .opacity(progressLabel == nil ? 0.45 : 0.7)
            }
            Text(progressLabel ?? "等待识别动画码")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(progressLabel ?? "等待识别")
    }
}

private struct CompletedTransferCard: View {
    let fileURL: URL
    let highlightShareAction: Bool
    let onPreview: () -> Void
    let onShare: () -> Void
    let onContinueScanning: () -> Void

    private var fileSize: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CompletedFileIcon(extension: fileURL.pathExtension)
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

                Button(action: onShare) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(highlightShareAction ? .green : .accentColor)
            }

            Button(action: onContinueScanning) {
                Label("继续扫码", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

private struct CompletedFileIcon: View {
    let `extension`: String

    private var symbolName: String {
        switch self.extension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "bmp": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv": return "play.rectangle.fill"
        case "mp3", "wav", "aac", "flac", "m4a": return "music.note"
        case "pdf": return "doc.richtext.fill"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox.fill"
        case "txt", "log", "md": return "doc.text.fill"
        case "json", "xml", "yaml", "yml", "toml": return "curlybraces"
        case "doc", "docx": return "doc.fill"
        case "xls", "xlsx", "csv": return "tablecells.fill"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle.fill"
        default: return "doc"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.tint.opacity(0.18))
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
        }
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

private struct IconButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
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

                if showCheckmark {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                        .shadow(color: .green.opacity(0.6), radius: 10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: side, height: side)
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
