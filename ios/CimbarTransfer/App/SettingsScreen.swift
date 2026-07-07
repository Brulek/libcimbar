import SwiftUI

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
                    LabeledContent("应用信息", value: "萤传")
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

    private var retentionHint: String {
        switch store.retentionPolicy {
        case .keepAll:
            return "默认设置。文件不会被自动删除，需要手动清理。"
        case .days30:
            return "超过 30 天未被修改的文件会在下次启动时清理。"
        case .days7:
            return "超过 7 天未被修改的文件会在下次启动时清理。"
        }
    }
}
