import SwiftUI

struct OnboardingScreen: View {
    /// 从「设置 → 查看引导」打开时为 true：可随时关闭、不要求重新勾选承诺
    var isHelpMode: Bool = false
    let onFinished: () -> Void

    @State private var pageIndex: Int = 0
    @State private var confidentialAcknowledged: Bool = false

    private let pages: [OnboardingPage] = OnboardingPage.all

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                TabView(selection: $pageIndex) {
                    ForEach(pages.indices, id: \.self) { index in
                        OnboardingPageView(
                            page: pages[index],
                            confidentialAcknowledged: $confidentialAcknowledged
                        )
                        .tag(index)
                        .padding(.horizontal, 24)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                pageDots

                actionRow
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 12)
                    .frame(maxWidth: 520)
            }
            .padding(.top, 24)

            if isHelpMode {
                closeButton
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            if isHelpMode {
                confidentialAcknowledged = AppPreferences.shared.hasAcknowledgedConfidentialWarning
            }
        }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onFinished) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.trailing, 16)
    }

    /// 与 App 图标同色的夜空，顶部一团萤火光晕
    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.night, Brand.nightDeep],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Brand.glow.opacity(0.22), .clear],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 10,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { index in
                Capsule()
                    .fill(index == pageIndex ? Brand.glow : Color.white.opacity(0.25))
                    .frame(width: index == pageIndex ? 20 : 8, height: 8)
            }
        }
        .animation(.spring(duration: 0.3), value: pageIndex)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(pageIndex + 1) 页，共 \(pages.count) 页")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if !isLastPage {
                Button(action: skip) {
                    Text("跳过")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }

            Button(action: isLastPage ? complete : next) {
                Text(isLastPage ? (isHelpMode ? "完成" : "开始使用") : "继续")
            }
            .buttonStyle(.brandPrimary)
            .disabled(!canFinish)
        }
        .animation(.easeInOut(duration: 0.2), value: isLastPage)
    }

    private var isLastPage: Bool { pageIndex == pages.count - 1 }
    private var canFinish: Bool { isHelpMode || !isLastPage || confidentialAcknowledged }

    private func next() {
        withAnimation { pageIndex = min(pageIndex + 1, pages.count - 1) }
    }

    private func skip() {
        withAnimation { pageIndex = pages.count - 1 }
    }

    private func complete() {
        // hasCompletedOnboarding 由 onFinished 回调方在 withAnimation 中写入，
        // 在这里抢先写会让过渡动画失效
        if confidentialAcknowledged {
            AppPreferences.shared.hasAcknowledgedConfidentialWarning = true
        }
        onFinished()
    }
}

struct OnboardingPage: Identifiable {
    /// 页面语义标识，供视图做条件判断（不要用本地化后的 title 比较）
    enum Role {
        case welcome
        case howToReceive
        case ready
    }

    enum Hero {
        case brandMark
        case symbol(String)
    }

    let id = UUID()
    let role: Role
    let hero: Hero
    let title: String
    let subtitle: String?
    let bullets: [Bullet]

    struct Bullet: Identifiable {
        let id = UUID()
        let symbol: String
        let text: String
    }

    static let all: [OnboardingPage] = [
        OnboardingPage(
            role: .welcome,
            hero: .brandMark,
            title: String(localized: "萤传"),
            subtitle: String(localized: "扫一扫屏幕上的动画码，文件就到手"),
            bullets: [
                Bullet(symbol: "wifi.slash", text: String(localized: "不联网、不配对，两台设备离得近就行")),
                Bullet(symbol: "lock.fill", text: String(localized: "文件只存在这台设备上")),
                Bullet(symbol: "doc.on.doc.fill", text: String(localized: "照片、文档、压缩包，什么格式都能收"))
            ]
        ),
        OnboardingPage(
            role: .howToReceive,
            hero: .symbol("laptopcomputer.and.iphone"),
            title: String(localized: "三步收文件"),
            subtitle: nil,
            bullets: [
                Bullet(symbol: "1.circle.fill", text: String(localized: "发送方用浏览器打开 cimbar.org，选好文件")),
                Bullet(symbol: "2.circle.fill", text: String(localized: "把屏幕上的动画码放进取景框")),
                Bullet(symbol: "3.circle.fill", text: String(localized: "进度走到 100%，文件就收好了"))
            ]
        ),
        OnboardingPage(
            role: .ready,
            hero: .symbol("hand.raised.fill"),
            title: String(localized: "使用须知"),
            subtitle: nil,
            bullets: [
                Bullet(symbol: "eye.fill", text: String(localized: "动画码显示在屏幕上，附近的人也能拍到")),
                Bullet(symbol: "exclamationmark.shield.fill", text: String(localized: "请勿用萤传传输、存储或处理涉密文件"))
            ]
        )
    ]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    @Binding var confidentialAcknowledged: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 32) {
                hero
                content
                if page.role == .howToReceive {
                    senderLink
                }
                if page.role == .ready {
                    confirmationToggle
                }
                Spacer(minLength: 16)
            }
            .padding(.vertical, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    /// 发送端在另一台设备上，在本机打开网页没用；让用户把网址转给发送方
    private var senderLink: some View {
        ShareLink(item: URL(string: "https://cimbar.org")!) {
            Label("把网址发给发送方", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.glow)
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background(Brand.glow.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        switch page.hero {
        case .brandMark:
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Brand.glow.opacity(0.45), radius: 30, y: 8)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(Brand.glow)
                .frame(width: 120, height: 120)
                .background(Brand.glow.opacity(0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            heroImage
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(page.title)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let subtitle = page.subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 24)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(page.bullets) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Image(systemName: bullet.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.glow)
                        .frame(width: 26, alignment: .center)
                    Text(bullet.text)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmationToggle: some View {
        Toggle(isOn: $confidentialAcknowledged) {
            Text("我已了解，不用萤传传输涉密文件")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .toggleStyle(.switch)
        .tint(Brand.glow)
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(confidentialAcknowledged ? Brand.glow.opacity(0.6) : .white.opacity(0.15), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: confidentialAcknowledged)
    }
}
