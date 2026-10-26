import SwiftUI

struct AboutScreen: View {
    var body: some View {
        List {
            Section {
                AppIdentityHeader()
                    .listRowBackground(Color.clear)
            }

            Section {
                NavigationLink {
                    PrivacyPolicyScreen()
                } label: {
                    Label("隐私政策", systemImage: "lock.shield")
                }
                NavigationLink {
                    TermsOfServiceScreen()
                } label: {
                    Label("用户协议", systemImage: "doc.text")
                }
                NavigationLink {
                    OpenSourceLicensesScreen()
                } label: {
                    Label("开源许可", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }

            Section {
                Link(destination: URL(string: "https://cimbar.org")!) {
                    ExternalLinkRow(title: "发送端网页", detail: "cimbar.org", systemImage: "safari")
                }
                Link(destination: URL(string: "https://github.com/sz3/libcimbar")!) {
                    ExternalLinkRow(title: "libcimbar 项目", detail: "GitHub", systemImage: "shippingbox")
                }
                // 与 App Store 上填的支持网址一致
                Link(destination: URL(string: "https://github.com/Brulek/libcimbar/issues")!) {
                    ExternalLinkRow(title: "反馈问题", detail: "GitHub", systemImage: "exclamationmark.bubble")
                }
            } footer: {
                Text("萤传是第三方开发的非官方客户端，与 libcimbar 及 cimbar.org 无隶属关系。解码部分基于 libcimbar（MPL-2.0），针对 iOS 修改过的源文件依 MPL-2.0 提供源代码，详见「开源许可」。")
                    .padding(.top, 4)
            }
        }
        .readableListWidth()
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppIdentityHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Brand.glow.opacity(0.3), radius: 18, y: 6)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text("萤传")
                    .font(.title2.weight(.bold))
                Text("扫一扫屏幕，文件就到手")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("版本 \(AppInfo.versionString)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct ExternalLinkRow: View {
    let title: LocalizedStringKey
    let detail: String
    let systemImage: String

    // 在 Link 里 .primary/.secondary 这类层级样式会被解析成主题色，要用具体的 Color
    var body: some View {
        HStack {
            Label {
                Text(title)
                    .foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
            Text(detail)
                .foregroundStyle(Color.secondary)
            Image(systemName: "arrow.up.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
        }
    }
}
