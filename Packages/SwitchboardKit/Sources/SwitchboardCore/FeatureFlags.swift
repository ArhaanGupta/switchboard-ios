import Foundation

/// On/off state for each module, stored in the shared App Group defaults so
/// extensions (keyboard, widgets, tunnel) can respect the user's choice.
public struct FeatureFlags {
    public let defaults: UserDefaults

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
    }

    public func isEnabled(_ module: ModuleID) -> Bool {
        defaults.object(forKey: Self.key(module)) as? Bool ?? module.enabledByDefault
    }

    public func setEnabled(_ enabled: Bool, for module: ModuleID) {
        defaults.set(enabled, forKey: Self.key(module))
    }

    public var enabledModules: [ModuleID] {
        ModuleID.allCases.filter(isEnabled)
    }

    static func key(_ module: ModuleID) -> String { "module.enabled.\(module.rawValue)" }
}

/// Keys for small values shared between processes.
public enum SharedKey {
    public static let keyboardLastSeen = "keyboard.lastSeen"
    public static let keyboardHasFullAccess = "keyboard.hasFullAccess"
    /// Jump back to the previous keyboard after pasting a clip (default on).
    public static let keyboardReturnAfterPaste = "keyboard.returnAfterPaste"
    public static let pasteboardChangeCount = "clipboard.lastChangeCount"
    public static let shieldUpstreamDNS = "shield.upstream"
    public static let shieldBlockMode = "shield.blockMode"
}
