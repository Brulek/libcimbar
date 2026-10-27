import SwiftUI

/// 品牌色取自 App 图标：深夜蓝底 + 萤火琥珀光
enum Brand {
    /// 萤火光（深色背景上的发光色，相机取景、引导页用）
    static let glow = Color(red: 1.0, green: 0.78, blue: 0.30)
    /// 识别到传输后的状态色
    static let signal = Color(red: 0.62, green: 0.95, blue: 0.55)
    /// 图标底色，与 LaunchBackground 一致
    static let night = Color(red: 0.05, green: 0.07, blue: 0.18)
    static let nightDeep = Color(red: 0.02, green: 0.03, blue: 0.09)
    /// 琥珀色按钮上的文字色：白字在琥珀上对比度不足
    static let ink = Color(red: 0.13, green: 0.09, blue: 0.02)
    /// 深色字（ink）下面的琥珀底。不直接用强调色：「增强对比度」时强调色在浅色模式里变成深棕，
    /// 深色字压在上面只有约 3.7:1；这里那一档反而调亮，四种外观下都在 6:1 以上
    static let fill = Color("BrandFill")
}

extension Brand {
    /// 传输进度的颜色：取景框边线和底部进度条共用。有问题（停滞/相机异常）橙、正在读到码绿、码不在琥珀
    static func progressTint(isTracking: Bool, hasWarning: Bool) -> Color {
        if hasWarning { return .orange }
        return isTracking ? signal : glow
    }
}

/// 琥珀实心主按钮，整宽
struct BrandPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            // 大字号下按钮文字会折行：居中、离圆角留出空隙，英文不至于从词中间断开贴着边
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            // 不可点时系统会把强调色压成灰色，深色字叠上去几乎看不见：改成灰字 + 淡底（深浅背景各一套）
            .foregroundStyle(isEnabled ? AnyShapeStyle(Brand.ink) : AnyShapeStyle(disabledText))
            .background(
                isEnabled ? AnyShapeStyle(Brand.fill) : AnyShapeStyle(disabledFill),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private extension BrandPrimaryButtonStyle {
    var disabledText: Color { colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.35) }
    var disabledFill: Color { colorScheme == .dark ? .white.opacity(0.1) : .black.opacity(0.06) }
}

extension ButtonStyle where Self == BrandPrimaryButtonStyle {
    static var brandPrimary: BrandPrimaryButtonStyle { BrandPrimaryButtonStyle() }
}

extension View {
    /// 相机画面上的浮层底：iOS 26 起用液态玻璃，更早的系统退回毛玻璃
    @ViewBuilder
    func glassChrome<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}

/// iPad 等宽屏上把列表内容收在可读宽度内，避免一行横跨整块屏幕
private struct ReadableListWidth: ViewModifier {
    static let maxWidth: CGFloat = 720

    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *), sizeClass == .regular {
            GeometryReader { proxy in
                content.contentMargins(
                    .horizontal,
                    // 窄于可读宽度时保留内缩分组列表本来的边距（iPad 分栏的右栏就窄于 720）
                    max(20, (proxy.size.width - Self.maxWidth) / 2),
                    for: .scrollContent
                )
            }
        } else {
            content
        }
    }
}

extension View {
    func readableListWidth() -> some View {
        modifier(ReadableListWidth())
    }
}

/// 设置页风格的彩色圆角图标
struct IconTile: View {
    let systemName: String
    let color: Color

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: side * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 带彩色图标的设置行标题
struct TileLabel: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color

    init(_ title: LocalizedStringKey, systemName: String, color: Color) {
        self.title = title
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IconTile(systemName: systemName, color: color)
        }
    }
}
