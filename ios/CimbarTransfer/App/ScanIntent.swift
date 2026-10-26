import AppIntents
import Combine

/// 进程内的跳转请求：App Intent 在 App 内执行，通过它通知 ContentView 切到扫码页
@MainActor
final class AppNavigator {
    static let shared = AppNavigator()

    /// 不用 @Published：它会把旧值重放给新订阅者，界面重建时会再跳一次扫码页
    let scanRequests = PassthroughSubject<Void, Never>()

    func requestScan() {
        scanRequests.send()
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
