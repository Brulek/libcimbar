import SwiftUI

struct AboutScreen: View {
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                AppIdentityHeader()

                VStack(alignment: .leading, spacing: 12) {
                    Text("应用简介")
                        .font(.headline)
                    Text("萤传是一款基于 cimbar 动态彩色码协议的离线文件接收工具。通过摄像头扫描发送端屏幕的动画码完成文件传输，无需网络、无需配对。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(label: String(localized: "版本"), value: appVersion)
                    InfoRow(label: "Bundle", value: Bundle.main.bundleIdentifier ?? "—")
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("声明")
                        .font(.headline)
                    Text("本应用使用 libcimbar 开源项目（Mozilla Public License 2.0）实现解码链路，包含少量适配 iOS 的修改；修改后的源文件依 MPL-2.0 以源代码形式提供。详细的开源声明请见「开源许可」页。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("本应用是由第三方开发的非官方客户端，与 libcimbar 开源项目及 cimbar.org 无隶属或合作关系。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppIdentityHeader: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.11, green: 0.09, blue: 0.31),
                                 Color(red: 0.03, green: 0.04, blue: 0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 112, height: 112)
                Image("BrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
            }
            VStack(spacing: 4) {
                Text("萤传")
                    .font(.title.weight(.bold))
                Text("Lumen · 见屏即传")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
    }
}
