import SwiftUI

/// 「怎么发送文件」：扫码页的问号和设置页的帮助都打开它
struct SenderHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private static let senderURL = URL(string: "https://cimbar.org")!

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
                    Button {
                        UIPasteboard.general.url = Self.senderURL
                        withAnimation { copied = true }
                    } label: {
                        Label(copied ? "已复制网址" : "复制网址", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: Self.senderURL) {
                        Label("把网址发给发送方", systemImage: "square.and.arrow.up")
                    }
                }

                Section("收不到时") {
                    Label("靠近些，让动画码占满大部分取景框", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("调亮发送端屏幕，避开灯光反光", systemImage: "sun.max")
                    Label("在网页菜单里调低 Framerate", systemImage: "speedometer")
                    // 自测里画面模糊、偏远时 Bm/Bu 仍能收完而 B 不行；萤传自动识别，换了也不用改设置
                    Label("距离远或屏幕小时，把网页菜单里的 Mode 换成 Bm 或 Bu", systemImage: "square.grid.2x2")
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Brand.ink)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
