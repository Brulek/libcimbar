import AppIntents
import Combine

/// 进程内的跳转请求：App Intent 在 App 内执行，通过它通知 ContentView 切到扫码页
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    /// 每次请求换一个新值，ContentView 监听变化
    @Published private(set) var scanRequest: UUID?

    func requestScan() {
        scanRequest = UUID()
    }
}

/// 「快捷指令」、Spotlight、Siri 和操作按钮都能直接打开扫码页
struct StartScanIntent: AppIntent {
    static var title: LocalizedStringResource = "扫码接收文件"
    static var description = IntentDescription("打开萤传的扫码页，对准发送端屏幕上的动画码。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigator.shared.requestScan()
        return .result()
    }
}

struct LumenShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartScanIntent(),
            phrases: [
                "用\(.applicationName)扫码",
                "打开\(.applicationName)扫码",
            ],
            // 显式写成可选类型，走 iOS 16 也可用的那个初始化方法
            shortTitle: "扫码接收" as LocalizedStringResource?,
            systemImageName: "viewfinder"
        )
    }
}
