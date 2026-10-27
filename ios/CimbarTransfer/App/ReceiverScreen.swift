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
    // 按钮行在调用处封顶 xxxLarge，@ScaledMetric 看不到那个封顶，这里按同一档自己封顶，
    // 否则大字号下取景框上方空出一大条
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var topReservedHeight: CGFloat {
        let capped = min(dynamicTypeSize, .xxxLarge)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(capped))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 64, compatibleWith: traits)
    }
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
                    // 帧回放：把正在喂给解码器的那一帧画进取景框，模拟拍到的屏幕。
                    // 和 ScanFrameOverlay 同一套算法，码比取景框略小、落在框正中（小屏上框更小）
                    if let frame = viewModel.replayFrame {
                        GeometryReader { proxy in
                            let available = max(proxy.size.height - topReservedHeight - bottomReservedHeight, 200)
                            let side = min(proxy.size.width - 32, available, 640) * 0.9
                            Image(uiImage: frame)
                                .resizable()
                                .interpolation(.medium)
                                .scaledToFit()
                                .frame(width: side, height: side)
                                .position(x: proxy.size.width / 2, y: topReservedHeight + available / 2)
                        }
                        .background(Color.black)
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
                        // 没有相机权限、相机被占用/过热时都没在扫，萤火虫也别绕圈
                        isPaused: viewModel.isIdlePaused || viewModel.cameraPermissionDenied
                            || viewModel.cameraErrorText != nil,
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
                            // 和底部面板同样封顶：卡片不能滚动，再大就把按钮挤出屏幕
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
                // 底部卡片和取景框挤在一屏里、不能滚动：最大的几档字号下文件名只剩两个字，
                // 封顶在辅助功能第二档（仍远大于默认），保证名字和按钮读得全
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .background(Color.black)
        // 相机界面始终用深色外观，与取景画面一致，不跟随系统浅色
        .environment(\.colorScheme, .dark)
        // 强制深色后，资源里的强调色在「增强对比度」下会取到浅色模式那一档（深棕），
        // 按钮在深色卡片上像是不可点；扫码页直接用品牌琥珀色
        .tint(Brand.glow)
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
        // 小文本要整个读出来解码（最大 512 KB），放到后台，别卡住打勾动画
        if let fileURL {
            let revealed = await Task.detached(priority: .userInitiated) { RevealedFile(url: fileURL) }.value
            guard !Task.isCancelled else { return }
            reveal = revealed
        } else {
            reveal = nil
        }
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
                // 几乎都用自动识别：手动的五种收进二级菜单，一级只剩三项
                Picker("解码模式", selection: $decodeMode) {
                    Text(DecodeMode.auto.title).tag(DecodeMode.auto.rawValue)
                }
                Menu {
                    Picker("指定模式", selection: $decodeMode) {
                        ForEach(DecodeMode.allCases.filter { $0 != .auto }) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } label: {
                    Text("指定模式")
                    if let mode = DecodeMode(rawValue: decodeMode), mode != .auto {
                        Text(mode.title)
                    }
                }
                Divider()
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
                // iPad 接触控板/鼠标时，自绘的玻璃按钮也要有指针高亮
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
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
                        .contentShape(.hoverEffect, Capsule())
                        .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("变焦 \(zoomText)")
                .accessibilityHint(isZoomed ? "恢复到 1 倍" : "放大到 2 倍")
            }

            if torchAvailable {
                Button(action: onToggleTorch) {
                    Image(systemName: torchActive ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .foregroundStyle(torchActive ? Brand.glow : .white)
                        .frame(width: buttonSide, height: buttonSide)
                        .glassChrome(in: Circle())
                        .contentShape(.hoverEffect, Circle())
                        .hoverEffect(.highlight)
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
