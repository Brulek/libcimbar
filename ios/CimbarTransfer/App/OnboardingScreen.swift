import SwiftUI

struct OnboardingScreen: View {
    /// 从「设置 → 查看使用指南」打开时为 true：可随时关闭、不要求重新勾选承诺
    var isHelpMode: Bool = false
    let onFinished: () -> Void

    @State private var pageIndex: Int = 0
    @State private var confidentialAcknowledged: Bool = false

    private let pages: [OnboardingPage] = OnboardingPage.all

    var body: some View {
        ZStack {
            backgroundGradient
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
                    .padding(.top, 8)
            }
            .padding(.top, 32)

            if isHelpMode {
                closeButton
            }
        }
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
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            Spacer()
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.07, blue: 0.18),
                     Color(red: 0.16, green: 0.1, blue: 0.32),
                     Color(red: 0.04, green: 0.05, blue: 0.12)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { index in
                Circle()
                    .fill(index == pageIndex ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == pageIndex ? 1.2 : 1.0)
                    .animation(.spring(duration: 0.25), value: pageIndex)
            }
        }
        .padding(.vertical, 8)
    }

    private var actionRow: some View {
        VStack(spacing: 12) {
            if isLastPage {
                Button(action: complete) {
                    Text(isHelpMode ? "完成" : "我已了解，开始使用")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canFinish ? Color.white : Color.white.opacity(0.35))
                        .foregroundStyle(canFinish ? Color(red: 0.16, green: 0.1, blue: 0.32) : .white.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canFinish)
            } else {
                HStack(spacing: 12) {
                    Button(action: skip) {
                        Text("跳过")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)

                    Button(action: next) {
                        Text("下一步")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .foregroundStyle(Color(red: 0.16, green: 0.1, blue: 0.32))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
    let id = UUID()
    let symbol: String
    let symbolColor: Color
    let title: String
    let subtitle: String
    let bullets: [Bullet]

    struct Bullet: Identifiable {
        let id = UUID()
        let symbol: String
        let text: String
    }

    static let all: [OnboardingPage] = [
        OnboardingPage(
            symbol: "viewfinder.circle.fill",
            symbolColor: Color(red: 0.55, green: 0.85, blue: 1.0),
            title: "欢迎使用萤传",
            subtitle: "一款基于 libcimbar 协议的离线文件接收工具",
            bullets: [
                Bullet(symbol: "wifi.slash", text: "无需网络，无需配对，全程离线"),
                Bullet(symbol: "lock.shield.fill", text: "数据不上传服务器，文件只在你的设备上"),
                Bullet(symbol: "doc.fill", text: "支持任意文件类型：图片、文档、压缩包等")
            ]
        ),
        OnboardingPage(
            symbol: "iphone.gen3.radiowaves.left.and.right",
            symbolColor: Color(red: 0.65, green: 1.0, blue: 0.78),
            title: "怎么收文件",
            subtitle: "对方用支持 cimbar 的发送端，本机扫一扫即可",
            bullets: [
                Bullet(symbol: "1.circle.fill", text: "发送方在另一台设备上打开 libcimbar 网页或客户端，选择要发送的文件，会显示一段彩色动画码"),
                Bullet(symbol: "2.circle.fill", text: "本机切到「扫码」页，将取景框对准对方屏幕"),
                Bullet(symbol: "3.circle.fill", text: "保持稳定数秒，进度条到 100% 即接收完成"),
                Bullet(symbol: "4.circle.fill", text: "完成后可直接预览、分享，或在「我的文件」中再次打开")
            ]
        ),
        OnboardingPage(
            symbol: "checkmark.seal.fill",
            symbolColor: Color(red: 0.65, green: 1.0, blue: 0.78),
            title: "准备就绪",
            subtitle: "请阅读以下提醒并勾选确认",
            bullets: [
                Bullet(symbol: "exclamationmark.shield.fill", text: "请勿传输、存储、处理任何涉密文件")
            ]
        )
    ]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    @Binding var confidentialAcknowledged: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 28) {
                hero
                if !page.bullets.isEmpty {
                    content
                }
                if page.title == "准备就绪" {
                    confirmationToggle
                }
                Spacer(minLength: 16)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(page.symbolColor.opacity(0.16))
                    .frame(width: 132, height: 132)
                Image(systemName: page.symbol)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(page.symbolColor)
            }
            VStack(spacing: 6) {
                Text(page.title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(page.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(page.bullets) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Image(systemName: bullet.symbol)
                        .font(.subheadline)
                        .foregroundStyle(page.symbolColor)
                        .frame(width: 24, alignment: .center)
                    Text(bullet.text)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var confirmationToggle: some View {
        VStack(spacing: 16) {
            Toggle(isOn: $confidentialAcknowledged) {
                Text("我已阅读上述提醒，承诺不使用本应用传输机密信息")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
            }
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .padding(16)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(confidentialAcknowledged ? Color.green.opacity(0.6) : .white.opacity(0.18), lineWidth: 1)
            )

            VStack(spacing: 8) {
                Text("接下来你将看到")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Label("自动开启相机扫描动画码", systemImage: "viewfinder")
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.footnote)
                Label("接收完成的文件可在「我的文件」标签查看", systemImage: "folder.fill")
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.footnote)
            }
        }
    }
}
