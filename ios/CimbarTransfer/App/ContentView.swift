import Combine
import SwiftUI

enum AppTab: Hashable {
    case scan
    case library
    case settings
}

/// 只负责持有扫码 VM，本身从不发布变化。
/// 扫码时 VM 每秒发布约 10 次进度；若 ContentView 直接用 @StateObject 观察它，
/// 整个 TabView（连同「我的文件」列表）都会跟着每秒重算 10 次。
/// 只有扫码页观察 VM，这里需要的「收到文件」事件单独转发
private final class ReceiverHolder: ObservableObject {
    let viewModel = NativeReceiverViewModel()
    /// 不能直接 onReceive(viewModel.$receivedFileURL)：SwiftUI 每次刷新都会重新订阅，
    /// @Published 又会给新订阅者重放当前值，于是「刷新列表 → 重绘 → 重放 → 再刷新」停不下来。
    /// PassthroughSubject 只在值真正变化时发一次
    let receivedFileChanges = PassthroughSubject<URL?, Never>()
    private var subscription: AnyCancellable?

    init() {
        subscription = viewModel.$receivedFileURL
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] url in self?.receivedFileChanges.send(url) }
    }
}

struct ContentView: View {
    @StateObject private var receiverHolder = ReceiverHolder()
    private var viewModel: NativeReceiverViewModel { receiverHolder.viewModel }
    @StateObject private var cacheStore = ReceivedFileCacheStore()
    @StateObject private var preferences = AppPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iPad 分栏时右栏显示的文件
    @State private var libraryDetail: CachedReceivedFile?
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

            libraryTab
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
        // iPad 外接键盘：⌘1/⌘2/⌘3 切标签（按住 ⌘ 时系统会列出来）
        .background {
            VStack {
                Button("扫码") { selectedTab = .scan }
                    .keyboardShortcut("1", modifiers: .command)
                Button("我的文件") { selectedTab = .library }
                    .keyboardShortcut("2", modifiers: .command)
                Button("设置") { selectedTab = .settings }
                    .keyboardShortcut("3", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .task {
            #if DEBUG
            DemoContent.seedFilesIfRequested()
            #endif
            cacheStore.refresh(cleanup: true)
        }
        .onReceive(receiverHolder.receivedFileChanges) { newURL in
            // URL 变 nil 说明用户点了「继续扫码」重置，同样要取消待执行的跳转
            autoJumpTask?.cancel()
            guard newURL != nil else { return }
            cacheStore.refresh(cleanup: false)
            if preferences.autoJumpAfterReceive {
                autoJumpTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    // 用户已在交互（重置扫码、打开了任何面板——分享、预览、存到文件、提示框，
                    // 或手动切走）就不要再抢着切页
                    guard !Task.isCancelled,
                          viewModel.receivedFileURL != nil,
                          shareRequest == nil,
                          previewRequest == nil,
                          !Self.isPresentingModal,
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
        .onReceive(AppNavigator.shared.scanRequests) { _ in
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
                // 撤销窗口内被切到后台：直接删掉，免得下次打开文件又「复活」
                cacheStore.commitPendingDeletion()
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
            QuickLookPreview(fileURLs: request.urls, initialIndex: request.index) { _ in
                cacheStore.refresh(cleanup: false)
            }
                .ignoresSafeArea()
        }
    }

    /// 当前窗口上是否正开着某个面板（子视图自己弹出的 sheet、alert 也算）
    private static var isPresentingModal: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }

    /// iPad 全屏（宽尺寸）时左边列表、右边简介；iPhone 和分屏变窄时照旧推入简介页
    @ViewBuilder
    private var libraryTab: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                libraryScreen(splitDetail: $libraryDetail)
                    // 默认侧栏太窄：文件名被截断、日期折行
                    .navigationSplitViewColumnWidth(min: 360, ideal: 420, max: 520)
            } detail: {
                NavigationStack {
                    if let file = libraryDetail {
                        FileDetailScreen(
                            store: cacheStore,
                            initialFile: file,
                            onShare: { presentShare(for: [$0]) },
                            onPreview: { presentPreview(for: [$0], at: 0) },
                            onClose: { libraryDetail = nil },
                            onRenamed: { libraryDetail = $0 }
                        )
                        .id(file.id)
                    } else {
                        LibraryDetailPlaceholder()
                    }
                }
            }
        } else {
            NavigationStack {
                libraryScreen(splitDetail: nil)
            }
        }
    }

    private func libraryScreen(splitDetail: Binding<CachedReceivedFile?>?) -> some View {
        LibraryScreen(
            store: cacheStore,
            onShareFiles: { presentShare(for: $0) },
            onPreviewFiles: { presentPreview(for: $0, at: $1) },
            newSince: libraryNewSince,
            onGoToScan: { selectedTab = .scan },
            splitDetail: splitDetail
        )
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

/// iPad 分栏右栏还没选文件时
private struct LibraryDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("轻点文件右边的 ⓘ 查看简介")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
