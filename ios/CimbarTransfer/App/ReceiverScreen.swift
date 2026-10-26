import SwiftUI

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
    /// 收到的文件在取景框里展示的缩略图；缓存键带修改时间（重收同名文件时不串图）
    @State private var reveal: RevealedFile?

    // 底部面板通过 safeAreaInset 已从取景区扣除，这里只需让出顶部按钮行；
    // 动态字体放大时按钮变高，预留随之缩放
    @ScaledMetric(relativeTo: .body) private var topReservedHeight: CGFloat = 64
    private let bottomReservedHeight: CGFloat = 20

    /// 还没开始接收就自动暂停了：底部「对准动画码」的提示与暂停卡片矛盾，收起
    private var isPausedWhileWaiting: Bool {
        viewModel.isIdlePaused && viewModel.progressValue == nil
            && viewModel.receivedFileURL == nil && !viewModel.scanErrorLatched
    }

    private var scanState: ScanState {
        if viewModel.receivedFileURL != nil { return .received }
        return viewModel.isTracking ? .detecting : .idle
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
                .accessibilityIgnoresInvertColors()
                .accessibilityLabel("相机取景，轻点对焦，捏合缩放")
                .accessibilityElement(children: .ignore)
                #if DEBUG
                .overlay {
                    // 帧回放：把正在喂给解码器的那一帧画进取景框，模拟拍到的屏幕
                    // （与取景框同样的上下预留，码才落在框正中）
                    if let frame = viewModel.replayFrame {
                        ZStack {
                            Color.black.ignoresSafeArea()
                            Image(uiImage: frame)
                                .resizable()
                                .interpolation(.medium)
                                .scaledToFit()
                                // 取景框最大 640pt（iPad），码比框略小
                                .frame(maxWidth: 580, maxHeight: 580)
                                .padding(.horizontal, 40)
                                .padding(.top, topReservedHeight)
                                .padding(.bottom, bottomReservedHeight)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if DemoContent.senderScreen != nil {
                        RadialGradient(
                            colors: [Color(red: 0.14, green: 0.16, blue: 0.22), .black],
                            center: UnitPoint(x: 0.5, y: 0.42),
                            startRadius: 40,
                            endRadius: 520
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }
                }
                #endif
                .overlay {
                    ScanFrameOverlay(
                        topReservedHeight: topReservedHeight,
                        bottomReservedHeight: bottomReservedHeight,
                        scanState: scanState,
                        showCheckmark: showCheckmark,
                        isPaused: viewModel.isIdlePaused,
                        progress: viewModel.receivedFileURL == nil ? viewModel.progressValue : nil,
                        progressTint: Brand.progressTint(
                            isTracking: viewModel.isTracking,
                            hasWarning: viewModel.stallHint != nil || viewModel.cameraErrorText != nil
                        ),
                        reveal: showCheckmark ? nil : reveal,
                        onTapReveal: { onPreview($0) }
                    )
                }
                .overlay {
                    // 收完文件后自动暂停不用提示：卡片上的「继续接收」会重新打开相机
                    if viewModel.isIdlePaused && viewModel.receivedFileURL == nil {
                        // 与取景框同样的上下预留，卡片才会落在取景框正中
                        IdlePausedCard { viewModel.start() }
                            .padding(.top, topReservedHeight)
                            .padding(.bottom, bottomReservedHeight)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
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
                    // 相机自动暂停时手电筒/变焦没有意义，先收起来
                    canQuickZoom: viewModel.canQuickZoom && !viewModel.isIdlePaused,
                    torchAvailable: viewModel.torchAvailable && !viewModel.isIdlePaused,
                    torchActive: viewModel.torchActive,
                    onToggleZoom: { viewModel.toggleQuickZoom() },
                    onToggleTorch: { viewModel.toggleTorch() }
                )
                // 相机浮层按钮和系统相机一样封顶字号：再大就挤掉取景区，模式名也会被压没。
                // 要加在调用处，按钮尺寸的 @ScaledMetric 才会跟着封顶
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.cameraPermissionDenied && !isPausedWhileWaiting {
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
        // 收完后放着没动、相机已自动暂停：「继续接收」顺带把相机打开
        if viewModel.isIdlePaused {
            viewModel.start()
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
        reveal = fileURL.flatMap(RevealedFile.init(url:))
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
    let canQuickZoom: Bool
    let torchAvailable: Bool
    let torchActive: Bool
    let onToggleZoom: () -> Void
    let onToggleTorch: () -> Void

    private var isZoomed: Bool { zoomFactor > 1.01 }

    private var zoomText: String {
        // 整数倍不带小数：1×、2×；捏合出来的非整数倍保留一位
        let rounded = (zoomFactor * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))×" : String(format: "%.1f×", rounded)
    }

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
                        .lineLimit(1)
                        .fixedSize()
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

            if canQuickZoom || isZoomed {
                Button(action: onToggleZoom) {
                    Text(zoomText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isZoomed ? Brand.glow : .white)
                        .frame(minWidth: buttonSide, minHeight: buttonSide)
                        .padding(.horizontal, isZoomed && zoomText.count > 2 ? 6 : 0)
                        .glassChrome(in: Capsule())
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("变焦 \(zoomText)")
                .accessibilityHint(isZoomed ? "轻点恢复 1 倍" : "轻点放大到 2 倍")
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
        .animation(.easeInOut(duration: 0.2), value: zoomFactor)
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
