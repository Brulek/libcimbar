import SwiftUI
import UIKit

struct SettingsScreen: View {
    @ObservedObject var store: ReceivedFileCacheStore
    /// 「已用空间」点进去：到「我的文件」按大小排，看是什么占地方
    var onShowFilesBySize: () -> Void = {}
    @ObservedObject private var preferences = AppPreferences.shared
    /// 和其他行的图标块（IconTile）一样随字号放大
    @ScaledMetric(relativeTo: .body) private var brandMarkSide: CGFloat = 29
    @State private var clearConfirm = false
    @State private var showingOnboarding = false
    @State private var showingSenderHelp = false
    @State private var clearFeedbackMessage: String?
    @State private var photoAccessDenied = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $preferences.decodeMode) {
                    ForEach(DecodeMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                } label: {
                    TileLabel("解码模式", systemName: "dot.viewfinder", color: .orange)
                }
                Toggle(isOn: $preferences.highResolutionCapture) {
                    TileLabel("高清采集", systemName: "camera.aperture", color: .indigo)
                }
            } header: {
                Text("扫码")
            } footer: {
                Text("自动识别会匹配发送端的 Mode。远距离或对着大屏幕时可打开高清采集，耗电会多一些。")
            }

            Section("收到文件后") {
                Toggle(isOn: $preferences.soundEnabled) {
                    TileLabel("提示音", systemName: "speaker.wave.2.fill", color: .pink)
                }
                Toggle(isOn: $preferences.hapticEnabled) {
                    TileLabel("振动", systemName: "iphone.radiowaves.left.and.right", color: .purple)
                }
                Toggle(isOn: $preferences.autoSaveToPhotos) {
                    TileLabel("照片和视频自动存到相册", systemName: "photo.on.rectangle", color: .orange)
                }
                Toggle(isOn: $preferences.autoJumpAfterReceive) {
                    TileLabel("自动打开「我的文件」", systemName: "folder.fill", color: .blue)
                }
            }

            Section {
                Button(action: onShowFilesBySize) {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(store.cacheSummary)
                                .monospacedDigit()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    } label: {
                        TileLabel("已用空间", systemName: "internaldrive.fill", color: .gray)
                    }
                }
                .tint(.primary)
                .disabled(store.cachedFiles.isEmpty)
                .accessibilityHint("按大小查看文件")
                Picker(selection: Binding(
                    get: { store.retentionPolicy },
                    set: { store.updateRetentionPolicy($0) }
                )) {
                    ForEach(ReceivedFileRetentionPolicy.allCases) { policy in
                        Text(policy.description).tag(policy)
                    }
                } label: {
                    TileLabel("自动清理", systemName: "clock.arrow.circlepath", color: .green)
                }
                Button {
                    openInFilesApp()
                } label: {
                    HStack {
                        TileLabel("在「文件」App 中查看", systemName: "folder", color: .cyan)
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
                Button(role: .destructive) {
                    clearConfirm = true
                } label: {
                    TileLabel("清空所有文件", systemName: "trash.fill", color: .red)
                }
                .tint(.red)
                .disabled(store.cachedFiles.isEmpty)
            } header: {
                Text("存储")
            } footer: {
                Text(retentionHint)
            }

            Section("帮助") {
                Button {
                    showingSenderHelp = true
                } label: {
                    NavigationRowLabel(TileLabel("怎么发送文件", systemName: "questionmark", color: .teal))
                }
                .tint(.primary)
                Button {
                    showingOnboarding = true
                } label: {
                    NavigationRowLabel(TileLabel("查看引导", systemName: "sparkles", color: .mint))
                }
                .tint(.primary)
            }

            Section {
                NavigationLink {
                    AboutScreen()
                } label: {
                    LabeledContent {
                        Text(AppInfo.versionString)
                            .monospacedDigit()
                    } label: {
                        Label {
                            Text("关于萤传")
                        } icon: {
                            Image("BrandMark")
                                .resizable()
                                .scaledToFit()
                                .accessibilityIgnoresInvertColors()
                                .frame(width: brandMarkSide, height: brandMarkSide)
                                .clipShape(RoundedRectangle(cornerRadius: brandMarkSide * 0.24, style: .continuous))
                        }
                    }
                }
            }
        }
        .readableListWidth()
        .navigationTitle("设置")
        .confirmationDialog("清空所有文件？", isPresented: $clearConfirm, titleVisibility: .visible) {
            Button("清空 \(store.cachedFiles.count) 个文件", role: .destructive) {
                store.clearAllCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("有文件没能删除", isPresented: Binding(
            get: { clearFeedbackMessage != nil },
            set: { if !$0 { clearFeedbackMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(clearFeedbackMessage ?? "")
        }
        .onChange(of: preferences.autoSaveToPhotos) { enabled in
            guard enabled else { return }
            Task { @MainActor in
                if !(await PhotoLibrarySaver.requestAddAccess()) {
                    preferences.autoSaveToPhotos = false
                    photoAccessDenied = true
                }
            }
        }
        .alert("没有相册权限", isPresented: $photoAccessDenied) {
            Button("去设置") { AppSettingsOpener.open() }
            Button("好", role: .cancel) {}
        } message: {
            Text("请在设置中允许萤传添加照片")
        }
        .onChange(of: store.feedback) { feedback in
            guard let feedback, feedback.source == .clear else { return }
            clearFeedbackMessage = feedback.message
            store.clearFeedback()
        }
        .sheet(isPresented: $showingSenderHelp) {
            SenderHelpSheet()
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingScreen(isHelpMode: true) {
                showingOnboarding = false
            }
        }
    }

    private func openInFilesApp() {
        guard let directory = try? ReceivedFileCache.directoryURL(),
              var components = URLComponents(url: directory, resolvingAgainstBaseURL: false) else { return }
        // 系统「文件」App 的官方跳转方式：file:// 换成 shareddocuments://
        components.scheme = "shareddocuments"
        guard let url = components.url else { return }
        UIApplication.shared.open(url)
    }

    private var retentionHint: String {
        switch store.retentionPolicy {
        case .keepAll:
            return String(localized: "文件会一直保留，直到你手动删除。")
        case .days30:
            return String(localized: "收到超过 30 天的文件会被自动删除。")
        case .days7:
            return String(localized: "收到超过 7 天的文件会被自动删除。")
        }
    }
}

/// 打开弹层的设置行：主色文字 + 右侧 chevron，与 NavigationLink 行外观一致
private struct NavigationRowLabel<Content: View>: View {
    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    var body: some View {
        HStack {
            content
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
}

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
