import Foundation

/// The App Group shared by the app and all of its extensions.
///
/// The identifier is injected through the `SBAppGroupID` Info.plist key
/// (set from the `APP_GROUP_ID` build setting in `project.yml`), so changing
/// the bundle prefix only requires editing one place.
public enum AppGroup {
    public static let infoPlistKey = "SBAppGroupID"

    public static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
    }

    public static var defaults: UserDefaults {
        if let id = identifier, let shared = UserDefaults(suiteName: id) {
            return shared
        }
        return .standard
    }

    /// Shared container directory. Falls back to a temp directory when the
    /// App Group is unavailable (unit tests, previews, misconfigured signing).
    public static var containerURL: URL {
        #if canImport(Darwin)
        if let id = identifier,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        #endif
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchboardGroup", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}
