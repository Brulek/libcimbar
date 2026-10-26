import SwiftUI

enum AppTab: Hashable {
    case scan
    case library
    case settings
}

struct ContentView: View {
    @StateObject private var viewModel = NativeReceiverViewModel()
    @StateObject private var cacheStore = ReceivedFileCacheStore()
    @StateObject private var preferences = AppPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    // 调试/自动化钩子：launch argument `-InitialTab library|settings` 可指定初始标签
    // （launch args 会进 UserDefaults 的 argument domain，正常使用不受影响）
    @State private var selectedTab: AppTab = {
        switch UserDefaults.standard.string(forKey: "InitialTab") {
        case "library": return .library
        case "settings": return .settings
        default: return .scan
        }
    }()
    @State private var shareRequest: ShareRequest?
    @State private var previewRequest: PreviewRequest?
    @State private var autoJumpTask: Task<Void, Never>?
    /// 本次打开「我的文件」之前的上次访问时间：之后收到的文件在列表里标为新
    @State private var libraryNewSince: Date = AppPreferences.shared.libraryLastViewed

    private var newFileCount: Int {
        guard selectedTab != .library else { return 0 }
        let lastViewed = preferences.libraryLastViewed
        return cacheStore.cachedFiles.filter { $0.receivedAt > lastViewed }.count
    }

    var body: some View {
        ZStack {
            // 引导未完成时不把主界面挂进视图层级，
            // 避免扫码页的 .task 在引导期间就触发相机权限弹窗
            if preferences.hasCompletedOnboarding {
                mainTabs
                    .transition(.opacity)
            } else {
                OnboardingScreen {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        preferences.hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ReceiverScreen(
                    viewModel: viewModel,
                    onShare: { presentShare(for: [$0]) },
                    onPreview: { presentPreview(for: [$0], at: 0) }
                )
            }
            .tabItem {
                Label("扫码", systemImage: "viewfinder")
            }
            .tag(AppTab.scan)

            NavigationStack {
                LibraryScreen(
                    store: cacheStore,
                    onShareFiles: { presentShare(for: $0) },
                    onPreviewFiles: { presentPreview(for: $0, at: $1) },
                    newSince: libraryNewSince,
                    onGoToScan: { selectedTab = .scan }
                )
            }
            .tabItem {
                Label("我的文件", systemImage: "folder")
            }
            .tag(AppTab.library)
            // 只数上次打开「我的文件」之后收到的，总数没有提醒价值
            .badge(newFileCount)

            NavigationStack {
                SettingsScreen(store: cacheStore)
            }
            .tabItem {
                Label("设置", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .task {
            #if DEBUG
            DemoContent.seedFilesIfRequested()
            #endif
            cacheStore.refresh(cleanup: true)
        }
        .onChange(of: viewModel.receivedFileURL) { newURL in
            // URL 变 nil 说明用户点了「继续扫码」重置，同样要取消待执行的跳转
            autoJumpTask?.cancel()
            guard newURL != nil else { return }
            cacheStore.refresh(cleanup: false)
            if preferences.autoJumpAfterReceive {
                autoJumpTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    // 用户已在交互（重置扫码、分享/预览面板打开、手动切走）就不要再抢着切页
                    guard !Task.isCancelled,
                          viewModel.receivedFileURL != nil,
                          shareRequest == nil,
                          previewRequest == nil,
                          selectedTab == .scan else { return }
                    selectedTab = .library
                }
            }
        }
        .onChange(of: selectedTab) { newValue in
            autoJumpTask?.cancel()
            if newValue == .library {
                cacheStore.refresh(cleanup: false)
                libraryNewSince = preferences.libraryLastViewed
                preferences.libraryLastViewed = Date()
            }
            switch newValue {
            case .scan:
                viewModel.start()
            case .library, .settings:
                viewModel.stop()
            }
        }
        .onChange(of: cacheStore.cachedFiles) { _ in
            // 停在「我的文件」时新到的文件当场就看到了，不再算作未读
            if selectedTab == .library {
                preferences.libraryLastViewed = Date()
            }
            // 在「我的文件」/设置里删除或清空后，扫码页完成卡片若还指向
            // 已删除的文件，会给出死链的「查看/分享」入口——直接重置扫码
            guard let url = viewModel.receivedFileURL,
                  !FileManager.default.fileExists(atPath: url.path) else { return }
            viewModel.resetScan()
        }
        .onChange(of: preferences.decodeMode) { newMode in
            viewModel.setDecodeMode(newMode)
        }
        .onChange(of: preferences.highResolutionCapture) { enabled in
            viewModel.setHighResolutionCapture(enabled)
        }
        .onReceive(AppNavigator.shared.$scanRequest.compactMap { $0 }) { _ in
            // 快捷指令 / 操作按钮：回到扫码页；正在看的预览、分享面板先收起
            shareRequest = nil
            previewRequest = nil
            selectedTab = .scan
        }
        .onChange(of: scenePhase) { newPhase in
            // 回前台只在「扫码」页恢复相机，避免其他页面后台开启相机
            switch newPhase {
            case .active:
                if selectedTab == .scan {
                    viewModel.start()
                }
            case .background:
                viewModel.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .sheet(item: $shareRequest, onDismiss: {
            resumeScanIfAppropriate()
        }) { request in
            ShareSheet(fileURLs: request.urls)
        }
        .sheet(item: $previewRequest, onDismiss: {
            resumeScanIfAppropriate()
        }) { request in
            QuickLookPreview(fileURLs: request.urls, initialIndex: request.index)
                .ignoresSafeArea()
        }
    }

    private func resumeScanIfAppropriate() {
        // 接收完成后解码链已刻意停住（省电），关闭分享/预览面板不应重新拉起；
        // 用户点「继续扫码」时 resetScan 会恢复
        guard viewModel.receivedFileURL == nil else { return }
        viewModel.resumeProcessing()
    }

    private func presentShare(for fileURLs: [URL]) {
        guard shareRequest == nil, !fileURLs.isEmpty else { return }
        autoJumpTask?.cancel()
        viewModel.pauseProcessing()
        shareRequest = ShareRequest(urls: fileURLs)
    }

    private func presentPreview(for fileURLs: [URL], at index: Int) {
        guard previewRequest == nil, !fileURLs.isEmpty else { return }
        autoJumpTask?.cancel()
        viewModel.pauseProcessing()
        previewRequest = PreviewRequest(urls: fileURLs, index: index)
    }
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct PreviewRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
    let index: Int
}
