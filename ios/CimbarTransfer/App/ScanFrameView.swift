import SwiftUI

/// 取景框状态：等待（琥珀色、慢）/ 正在识别（绿色、快）
enum ScanState: Equatable {
    case idle
    case detecting
    /// 文件已收到、解码已停：萤火虫不再绕圈，免得看着像还在找码
    case received
}

/// 收完后放进取景框的文件（只给缩略图一定出得来的类型，以及能直接显示文字的小文本）
struct RevealedFile: Equatable {
    let url: URL
    let cacheKey: String
    let isText: Bool

    init?(url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        isText = TextClipboard.canCopy(fileExtension: url.pathExtension, size: size)
        guard isText || ThumbnailLoader.supportsLargePreview(fileExtension: url.pathExtension) else { return nil }
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        self.url = url
        self.cacheKey = "reveal-\(url.lastPathComponent)-\(modified)"
    }
}

struct ScanFrameOverlay: View {
    let topReservedHeight: CGFloat
    let bottomReservedHeight: CGFloat
    var scanState: ScanState = .idle
    var showCheckmark: Bool = false
    var isPaused: Bool = false
    /// 传输进度（0~1）：取景框边线按进度点亮，看着取景框也知道收到哪了
    var progress: Double?
    var progressTint: Color = Brand.glow
    /// 打勾动画结束后，把收到的图片/PDF/视频缩略图放进取景框
    var reveal: RevealedFile?
    var onTapReveal: (URL) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(proxy.size.height - topReservedHeight - bottomReservedHeight, 200)
            let side = min(proxy.size.width - 32, availableHeight, 640)
            let centerY = topReservedHeight + availableHeight / 2
            let center = CGPoint(x: proxy.size.width / 2, y: centerY)
            let cornerRadius = max(28, side * 0.08)

            FireflyScanFrame(
                side: side,
                cornerRadius: cornerRadius,
                scanState: scanState,
                showCheckmark: showCheckmark,
                isPaused: isPaused || reveal != nil
            )
            .overlay {
                if let progress, !showCheckmark, reveal == nil {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .trim(from: 0, to: max(0.002, min(progress, 1)))
                        .stroke(progressTint.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .shadow(color: progressTint.opacity(0.6), radius: 6)
                        .frame(width: side, height: side)
                        // RoundedRectangle 的路径从右边中点起笔；正方形转 -90° 后改从顶边中点顺时针走
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.3), value: progress)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if let reveal {
                    Button {
                        onTapReveal(reveal.url)
                    } label: {
                        Group {
                            if reveal.isText {
                                TextRevealPage(url: reveal.url, side: side)
                            } else {
                                FileThumbnailView(
                                    url: reveal.url,
                                    cacheKey: reveal.cacheKey,
                                    cornerRadius: cornerRadius,
                                    generationSide: side
                                )
                            }
                        }
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Color.green.opacity(0.5), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预览 \(reveal.url.lastPathComponent)")
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            #if DEBUG
            .background {
                if let screen = DemoContent.senderScreen {
                    Image(uiImage: screen)
                        .resizable()
                        .scaledToFit()
                        .frame(width: side * 0.9, height: side * 0.9)
                        .rotation3DEffect(.degrees(6), axis: (x: 0.4, y: -1, z: 0), perspective: 0.6)
                        .blur(radius: 0.6)
                        .shadow(color: Color(red: 0.3, green: 0.4, blue: 0.8).opacity(0.35), radius: 30)
                }
            }
            #endif
            .position(center)
            .animation(.easeInOut(duration: 0.4), value: scanState)
            .animation(.easeInOut(duration: 0.4), value: showCheckmark)
            .animation(.easeInOut(duration: 0.5), value: reveal)
        }
        // 只有放进取景框的缩略图可以点（预览）；其余部分让给下面的相机做对焦/缩放手势
        .allowsHitTesting(reveal != nil)
    }
}

private struct FireflyScanFrame: View {
    let side: CGFloat
    let cornerRadius: CGFloat
    let scanState: ScanState
    let showCheckmark: Bool
    /// 相机已自动暂停：萤火虫停下，不再白跑 60fps 动画
    var isPaused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let trailCount: Int = 16
    /// 萤火虫光晕（44pt + blur）伸出边框的距离
    private static let glowOutset: CGFloat = 40

    private var fireflyColor: Color {
        if showCheckmark { return .green }
        switch scanState {
        case .idle:      return Brand.glow
        case .detecting: return Brand.signal
        case .received:  return .green
        }
    }

    private var orbitPeriod: Double {
        switch scanState {
        case .idle, .received: return 5.5
        case .detecting:       return 2.6
        }
    }

    private var isResting: Bool { isPaused || scanState == .received }

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
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: showCheckmark || isResting)) { context in
                let t = (context.date.timeIntervalSinceReferenceDate / orbitPeriod * 4)
                    .truncatingRemainder(dividingBy: 4)

                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(fireflyColor.opacity(0.28), lineWidth: 1)
                        .frame(width: side, height: side)

                    if !showCheckmark && !isResting {
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

/// 收到的小文本把开头几段直接摊在取景框里：链接、口令、一段话，不用点开就能看到
private struct TextRevealPage: View {
    let url: URL
    /// 取景框边长：字号随框缩放，iPad 的大框里不至于是一角小字
    let side: CGFloat
    @State private var snippet: String?
    /// 编码认不出来时退回类型图标，不留一张空白页
    @State private var unreadable = false

    private static let codeExtensions: Set<String> = ["json", "csv", "log", "xml", "yaml", "yml"]

    private var font: Font {
        let size = min(max(side * 0.043, 15), 22)
        return Self.codeExtensions.contains(url.pathExtension.lowercased())
            ? .system(size: size - 2, design: .monospaced)
            : .system(size: size)
    }

    var body: some View {
        if unreadable {
            FileKindIcon(fileExtension: url.pathExtension, cornerRadius: 0)
        } else {
            page
        }
    }

    private var page: some View {
        Color(white: 0.97)
            .overlay {
                if let snippet {
                    // 从第一行开始排，放不下的在最后一行以省略号结束
                    VStack(alignment: .leading, spacing: 0) {
                        Text(snippet)
                            .font(font)
                            .foregroundStyle(Color(white: 0.12))
                            .lineSpacing(4)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(side * 0.06)
                }
            }
            .task(id: url) {
                let url = url
                snippet = await Task.detached(priority: .userInitiated) {
                    TextClipboard.readText(url).map { String($0.prefix(1500)) }
                }.value
                unreadable = snippet == nil
            }
    }
}
