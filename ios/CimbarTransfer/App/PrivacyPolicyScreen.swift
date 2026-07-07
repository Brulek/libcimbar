import SwiftUI

struct PrivacyPolicyScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                policyHeader

                PolicySection(title: "一、本政策的适用范围") {
                    Text("本隐私政策仅适用于「萤传」iOS 客户端（以下简称「本应用」）。本应用是一款离线的文件接收工具，使用 libcimbar 协议在本机解码相机捕获到的彩色动画码。")
                }

                PolicySection(title: "二、我们收集哪些信息") {
                    Text("本应用 **不收集** 您的任何个人信息，包括但不限于：")
                    PolicyBullet("姓名、电话、邮箱、身份证号、地址等身份信息")
                    PolicyBullet("位置信息、设备 IMEI 或唯一标识")
                    PolicyBullet("通讯录、相册、麦克风等敏感数据")
                    PolicyBullet("您接收到的文件内容")
                    Text("本应用 **不会** 将任何数据上传至任何服务器，也不与第三方共享。")
                }

                PolicySection(title: "三、我们使用哪些权限") {
                    PolicyBullet("**相机权限（必需）**：仅用于扫描发送端的彩色动画码。该权限只在「扫码」页激活时使用，画面仅在本机内存中实时解码，不会被存储或上传。")
                    PolicyBullet("**相册写入权限（可选）**：仅在您主动选择将接收到的图片保存到相册时使用。本应用不读取您相册中的任何内容。")
                }

                PolicySection(title: "四、文件如何存储") {
                    Text("接收到的文件保存在本应用的「文档」目录（Documents/CimbarTransfer/Inbox）。这些文件：")
                    PolicyBullet("仅保存在您本机设备上，不会被上传或同步到任何云端")
                    PolicyBullet("可在系统「文件」App 中浏览")
                    PolicyBullet("您可随时在应用内手动删除，或在「设置 → 保留策略」中配置自动清理规则")
                    PolicyBullet("卸载本应用时，这些文件会随应用一并删除")
                }

                PolicySection(title: "五、本应用的安全声明") {
                    Text("本应用基于 libcimbar 开源项目（Mozilla Public License 2.0）实现解码。其传输方式本质上是公开的视觉编码，不进行加密：")
                    PolicyBullet("彩色动画码在屏幕上完整可见，附近的人可拍摄、录屏甚至远距离捕获")
                    PolicyBullet("**请勿用于传输商业机密、个人隐私文件等敏感内容**")
                    PolicyBullet("如必须传输敏感文件，请先用强密码加密压缩后再发送")
                }

                PolicySection(title: "六、未成年人保护") {
                    Text("本应用面向 4 岁以上用户，不针对未成年人收集任何信息。如发现误收集请联系我们删除。")
                }

                PolicySection(title: "七、政策的变更") {
                    Text("本政策可能不时更新。重大变更将在应用内显著位置告知您。继续使用本应用即视为您同意更新后的政策。")
                }

                PolicySection(title: "八、联系我们") {
                    Text("如对本政策有任何疑问，请通过 App Store 评价或开发者邮箱联系我们。")
                }

                Text("最后更新时间：2026 年 5 月")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            .padding(20)
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var policyHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("萤传 · 隐私政策")
                .font(.title2.weight(.bold))
            Text("我们尊重并保护您的隐私。请在使用前仔细阅读本政策。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct PolicySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
                .font(.body)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PolicyBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(.init(text))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
