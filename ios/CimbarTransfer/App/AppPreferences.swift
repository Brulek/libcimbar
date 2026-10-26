import Foundation
import SwiftUI

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private static let onboardingCompletedKey = "org.cimbar.onboarding-completed-v1"
    private static let confidentialAcknowledgedKey = "org.cimbar.confidential-acknowledged-v1"
    private static let soundEnabledKey = "org.cimbar.sound-enabled"
    private static let hapticEnabledKey = "org.cimbar.haptic-enabled"
    private static let autoJumpAfterReceiveKey = "org.cimbar.auto-jump-after-receive"
    private static let decodeModeKey = "org.cimbar.decode-mode"
    private static let highResolutionCaptureKey = "org.cimbar.high-resolution-capture"
    private static let libraryLastViewedKey = "org.cimbar.library-last-viewed"
    private static let autoSaveToPhotosKey = "org.cimbar.auto-save-to-photos"

    /// cimbar mode_val 的合法取值，与 Config::temp_conf 对齐；0 为自动识别
    static let validDecodeModes: Set<Int> = Set(DecodeMode.allCases.map(\.rawValue))

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardingCompletedKey) }
    }

    @Published var hasAcknowledgedConfidentialWarning: Bool {
        didSet { UserDefaults.standard.set(hasAcknowledgedConfidentialWarning, forKey: Self.confidentialAcknowledgedKey) }
    }

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Self.soundEnabledKey) }
    }

    @Published var hapticEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticEnabled, forKey: Self.hapticEnabledKey) }
    }

    @Published var autoJumpAfterReceive: Bool {
        didSet { UserDefaults.standard.set(autoJumpAfterReceive, forKey: Self.autoJumpAfterReceiveKey) }
    }

    @Published var decodeMode: Int {
        didSet { UserDefaults.standard.set(decodeMode, forKey: Self.decodeModeKey) }
    }

    @Published var highResolutionCapture: Bool {
        didSet { UserDefaults.standard.set(highResolutionCapture, forKey: Self.highResolutionCaptureKey) }
    }

    /// 收到照片/视频后自动存到相册（默认关）
    @Published var autoSaveToPhotos: Bool {
        didSet { UserDefaults.standard.set(autoSaveToPhotos, forKey: Self.autoSaveToPhotosKey) }
    }

    /// 上次打开「我的文件」的时间；之后收到的文件在标签上计为新文件
    @Published var libraryLastViewed: Date {
        didSet { UserDefaults.standard.set(libraryLastViewed.timeIntervalSince1970, forKey: Self.libraryLastViewedKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.soundEnabledKey) == nil {
            defaults.set(true, forKey: Self.soundEnabledKey)
        }
        if defaults.object(forKey: Self.hapticEnabledKey) == nil {
            defaults.set(true, forKey: Self.hapticEnabledKey)
        }
        if defaults.object(forKey: Self.autoJumpAfterReceiveKey) == nil {
            defaults.set(false, forKey: Self.autoJumpAfterReceiveKey)
        }

        self.hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingCompletedKey)
        self.hasAcknowledgedConfidentialWarning = defaults.bool(forKey: Self.confidentialAcknowledgedKey)
        self.soundEnabled = defaults.bool(forKey: Self.soundEnabledKey)
        self.hapticEnabled = defaults.bool(forKey: Self.hapticEnabledKey)
        self.autoJumpAfterReceive = defaults.bool(forKey: Self.autoJumpAfterReceiveKey)
        // 未设置过时 integer(forKey:) 返回 0，即自动识别
        let storedMode = defaults.integer(forKey: Self.decodeModeKey)
        self.decodeMode = Self.validDecodeModes.contains(storedMode) ? storedMode : DecodeMode.auto.rawValue
        self.highResolutionCapture = defaults.bool(forKey: Self.highResolutionCaptureKey)
        self.autoSaveToPhotos = defaults.bool(forKey: Self.autoSaveToPhotosKey)
        // 首次运行（含从旧版升级）时把已有文件视为已读，不要一上来就挂一个大数字
        if defaults.object(forKey: Self.libraryLastViewedKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: Self.libraryLastViewedKey)
        }
        self.libraryLastViewed = Date(timeIntervalSince1970: defaults.double(forKey: Self.libraryLastViewedKey))
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
    }
}

/// 解码模式。名称与发送端 cimbar.org 菜单里的 Mode 一致（B / Bm / Bu / 4C）
enum DecodeMode: Int, CaseIterable, Identifiable {
    case auto = 0
    case b = 68
    case bm = 67
    case bu = 66
    case color4 = 4
    case color8 = 8

    var id: Int { rawValue }

    /// 发送端菜单上的写法
    var code: String {
        switch self {
        case .auto: return String(localized: "自动")
        case .b: return "B"
        case .bm: return "Bm"
        case .bu: return "Bu"
        case .color4: return "4C"
        case .color8: return "8C"
        }
    }

    var title: String {
        switch self {
        case .auto: return String(localized: "自动识别")
        case .color8: return String(localized: "8C（旧版）")
        default: return code
        }
    }

    static func code(for rawValue: Int) -> String? {
        DecodeMode(rawValue: rawValue)?.code
    }
}
