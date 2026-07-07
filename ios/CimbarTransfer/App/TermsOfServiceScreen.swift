import SwiftUI

struct TermsOfServiceScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                PolicySection(title: "一、协议接受") {
                    Text("欢迎使用「萤传」（以下简称「本应用」）。在您下载、安装或使用本应用之前，请仔细阅读本协议。一旦您开始使用本应用，即视为您已阅读、理解并同意接受本协议的全部条款。")
                }

                PolicySection(title: "二、服务说明") {
                    Text("本应用提供基于 libcimbar 协议的离线文件接收功能：")
                    PolicyBullet("通过设备相机扫描发送端屏幕的彩色动画码")
                    PolicyBullet("在本机完成数据重组并保存到本应用的文档目录")
                    PolicyBullet("提供文件预览、分享、重命名、删除等管理能力")
                    Text("本应用不提供发送功能，也不提供任何在线服务。")
                }

                PolicySection(title: "三、用户行为规范") {
                    Text("您承诺不会使用本应用从事以下行为：")
                    PolicyBullet("传输或接收任何违反中国法律法规的内容")
                    PolicyBullet("传输商业机密、国家秘密、他人隐私等敏感信息（详见隐私政策中的安全声明）")
                    PolicyBullet("传输侵犯他人知识产权的文件")
                    PolicyBullet("传输含有计算机病毒、木马等恶意代码的文件")
                    PolicyBullet("利用本应用从事任何形式的非法活动")
                    Text("您应对通过本应用接收和处理的所有文件内容承担全部责任。")
                }

                PolicySection(title: "四、文件内容的责任归属") {
                    Text("本应用本身不产生、不审核、不存储任何文件内容到我们的服务器：")
                    PolicyBullet("接收到的文件仅保存在您本机设备上")
                    PolicyBullet("您应自行判断文件来源是否可信")
                    PolicyBullet("因接收非法文件、病毒文件造成的任何损失，由您自行承担")
                    PolicyBullet("我们对您接收的文件内容不负任何审查义务和责任")
                }

                PolicySection(title: "五、知识产权") {
                    Text("本应用的所有权及知识产权由开发者所有，但其中使用的 libcimbar 等开源组件遵循各自的开源许可证（详见「开源许可」页面）。未经允许，您不得反编译、反向工程或修改本应用。")
                }

                PolicySection(title: "六、免责声明") {
                    Text("本应用按「现状」提供，不对以下事项作任何明示或暗示的保证：")
                    PolicyBullet("传输过程的成功率（受光照、距离、设备性能等多种因素影响）")
                    PolicyBullet("接收文件的完整性和正确性")
                    PolicyBullet("应用功能在所有 iOS 设备及版本上的兼容性")
                    PolicyBullet("应用持续可用、无中断、无错误")
                    Text("在法律允许的最大范围内，开发者不对因使用或无法使用本应用导致的任何直接或间接损失承担责任。")
                }

                PolicySection(title: "七、协议的变更与终止") {
                    Text("本协议可能不时更新，我们会在应用内告知您。如您不同意更新后的协议，应停止使用本应用。您也可随时通过卸载本应用终止本协议。")
                }

                PolicySection(title: "八、法律适用") {
                    Text("本协议适用中华人民共和国法律。如发生争议，应通过友好协商解决；协商不成的，可向开发者所在地人民法院提起诉讼。")
                }

                Text("最后更新时间：2026 年 5 月")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
            .padding(20)
        }
        .navigationTitle("用户协议")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("萤传 · 用户协议")
                .font(.title2.weight(.bold))
            Text("使用本应用前请仔细阅读本协议。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
