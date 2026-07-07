import Foundation
import SwiftUI

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private static let onboardingCompletedKey = "org.cimbar.onboarding-completed-v1"
    private static let confidentialAcknowledgedKey = "org.cimbar.confidential-acknowledged-v1"
    private static let soundEnabledKey = "org.cimbar.sound-enabled"
    private static let hapticEnabledKey = "org.cimbar.haptic-enabled"
    private static let autoJumpAfterReceiveKey = "org.cimbar.auto-jump-after-receive"

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
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
    }
}
