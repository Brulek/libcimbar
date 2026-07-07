import SwiftUI
import UIKit

struct SettingsScreen: View {
    @ObservedObject var store: ReceivedFileCacheStore
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var clearConfirm = false
    @State private var showingOnboarding = false
    @State private var clearFeedbackMessage: String?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section("扫码") {
                Picker("解码模式", selection: $preferences.decodeMode) {
                    Text("标准（Mode B）").tag(68)
                    Text("兼容 4C（旧版）").tag(4)
                    Text("兼容 8C（旧版）").tag(8)
                    Text("Mini 小码").tag(67)
                    Text("Micro 微码").tag(66)
                }
                Toggle(isOn: $preferences.highResolutionCapture) {
                    Label("高精度采集（1080p）", systemImage: "camera.metering.center.weighted")
                }
                Text("解码模式需与发送端一致，cimbar.org 当前默认为标准 Mode B；切换模式会重置正在进行的扫码。1080p 采集可提高远距/大屏识别率，但更耗电。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("接收") {
                Toggle(isOn: $preferences.soundEnabled) {
                    Label("接收完成提示音", systemImage: "speaker.wave.2.fill")
                }
                Toggle(isOn: $preferences.hapticEnabled) {
                    Label("触觉反馈", systemImage: "iphone.radiowaves.left.and.right")
                }
                Toggle(isOn: $preferences.autoJumpAfterReceive) {
                    Label("接收后自动打开「我的文件」", systemImage: "arrow.right.circle.fill")
                }
            }

            Section("存储") {
                LabeledContent("已接收", value: store.cacheSummary)
                LabeledContent("保存位置", value: ReceivedFileCache.displayPath)
                Button {
                    openInFilesApp()
                } label: {
                    Label("在「文件」App 中查看", systemImage: "folder.badge.gearshape")
                }
                Text("文件保存在 App 的文档目录，可在系统「文件」App 中浏览。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("保留策略") {
                Picker("保留时长", selection: Binding(
                    get: { store.retentionPolicy },
                    set: { store.updateRetentionPolicy($0) }
                )) {
                    ForEach(ReceivedFileRetentionPolicy.allCases) { policy in
                        Text(policy.description).tag(policy)
                    }
                }
                Text(retentionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("清空所有文件", role: .destructive) {
                    clearConfirm = true
                }
                .disabled(store.cachedFiles.isEmpty)
            }

            Section("帮助") {
                Button {
                    showingOnboarding = true
                } label: {
                    Label("查看使用指南", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://cimbar.org")!) {
                    Label("发送端网页（cimbar.org）", systemImage: "safari")
                }
                Link(destination: URL(string: "https://github.com/sz3/libcimbar")!) {
                    Label("libcimbar 开源项目", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Text("发送文件：在对方设备的浏览器打开 cimbar.org，选择文件生成动画码，用本机扫描即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("法律") {
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
            }

            Section("关于") {
                NavigationLink {
                    AboutScreen()
                } label: {
                    LabeledContent("应用信息", value: String(localized: "萤传"))
                }
                NavigationLink {
                    OpenSourceLicensesScreen()
                } label: {
                    Text("开源许可")
                }
                LabeledContent("版本", value: appVersion)
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("确认清空所有文件？", isPresented: $clearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                store.clearAllCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("操作不可撤销。")
        }
        .alert("清空未完全成功", isPresented: Binding(
            get: { clearFeedbackMessage != nil },
            set: { if !$0 { clearFeedbackMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(clearFeedbackMessage ?? "")
        }
        .onChange(of: store.feedback) { feedback in
            guard let feedback, feedback.source == .clear else { return }
            clearFeedbackMessage = feedback.message
            store.clearFeedback()
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
            return String(localized: "默认设置。文件不会被自动删除，需要手动清理。")
        case .days30:
            return String(localized: "接收超过 30 天的文件会被自动清理（切换后立即生效，并在每次启动时检查）。")
        case .days7:
            return String(localized: "接收超过 7 天的文件会被自动清理（切换后立即生效，并在每次启动时检查）。")
        }
    }
}
