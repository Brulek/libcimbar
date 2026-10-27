import CoreImage.CIFilterBuiltins
import SwiftUI

/// 「怎么发送文件」：扫码页的问号和设置页的帮助都打开它
struct SenderHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StepRow(number: 1, text: "在电脑或另一台手机的浏览器里打开 cimbar.org")
                    StepRow(number: 2, text: "打开网页菜单，点 Find File 选择文件，也可以直接把文件拖进网页")
                    StepRow(number: 3, text: "网页开始播放动画码后，用萤传对准它，进度到 100% 即完成")
                } footer: {
                    Text("网页菜单里的 Mode 保持默认即可，萤传会自动识别。")
                }

                Section {
                    // 发送方是另一台手机时，用它的相机扫一下就能打开，不用手打网址
                    if let qrImage = SenderSite.qrImage {
                        // 大字号下说明文字放到码的下面，挤在旁边会一行一两个字
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                            : AnyLayout(HStackLayout(spacing: 16))
                        layout {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 112, height: 112)
                                .padding(8)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityIgnoresInvertColors()
                                .accessibilityLabel("cimbar.org 的二维码")
                            Text("发送方是手机：用它的相机扫这个码，直接打开 cimbar.org")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        UIPasteboard.general.url = SenderSite.url
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "已复制网址" : "复制网址", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: SenderSite.url) {
                        Label("把网址发给发送方", systemImage: "square.and.arrow.up")
                    }
                }

                Section("收不到时") {
                    Label("靠近些，让动画码占满大部分取景框", systemImage: "arrow.up.left.and.arrow.down.right")
                    // Pro 机型主摄最近对焦约 20 cm，两部手机贴太近会糊
                    Label("发送端是手机、贴得很近时画面会糊：点 2×，再把手机拿远一点", systemImage: "camera.macro")
                    Label("调亮发送端屏幕，避开灯光反光", systemImage: "sun.max")
                    Label("在网页菜单里调低 Framerate", systemImage: "speedometer")
                    // 自测里画面模糊、偏远时 Bm/Bu 仍能收完而 B 不行；萤传自动识别，换了也不用改设置
                    Label("距离远或屏幕小时，把网页菜单里的 Mode 换成 Bm 或 Bu", systemImage: "square.grid.2x2")
                    // 不足一个喷泉块的文件，发送端用 0 填满（zstd_compressor.h 的 pad），新打开的接收端读不出来
                    Label("只发一个网址这类很短的文字时，和别的文件一起打包再发", systemImage: "doc.zipper")
                }
                .font(.subheadline)
            }
            .navigationTitle("怎么发送文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

}

private struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey
    /// 圆圈跟着序号的字号放大，固定 24pt 时大字号下数字会溢出圆圈
    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Brand.ink)
                .frame(width: badgeSize, height: badgeSize)
                .background(Brand.fill, in: Circle())
                .brandFillOutline(Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// 发送端网页：网址和它的二维码（引导页、「怎么发送文件」共用）
enum SenderSite {
    static let url = URL(string: "https://cimbar.org")!

    /// 网址是固定的，只生成一次；本机生成，不联网
    static let qrImage: UIImage? = {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }()
}
