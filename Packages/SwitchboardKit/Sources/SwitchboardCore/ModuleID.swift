import Foundation

/// Every feature in Switchboard is a module that can be switched on or off.
/// Add a case here (plus a descriptor in the app) to add a new module.
public enum ModuleID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case clipboard
    case stickyNotes
    case shield
    case shareAnywhere
    case floatingWindow

    public var id: String { rawValue }

    /// Modules that need no system-level approval start enabled.
    public var enabledByDefault: Bool {
        switch self {
        case .clipboard, .stickyNotes, .floatingWindow: return true
        case .shield, .shareAnywhere: return false
        }
    }
}
