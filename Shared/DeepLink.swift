import Foundation
import SwitchboardCore

/// `switchboard://` URLs used by Control Center controls, widgets and the keyboard.
enum DeepLink: Equatable {
    case module(ModuleID)
    case saveClipboard
    case newStickyNote
    case floating(String)        // floating mode raw value
    case receiveFiles
    case scanQR
    case unlockApp

    static let scheme = "switchboard"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .module(let id):
            components.host = "module"
            components.path = "/\(id.rawValue)"
        case .saveClipboard:
            components.host = "clipboard"
            components.path = "/save"
        case .newStickyNote:
            components.host = "sticky"
            components.path = "/new"
        case .floating(let mode):
            components.host = "floating"
            components.path = "/\(mode)"
        case .receiveFiles:
            components.host = "share"
            components.path = "/receive"
        case .scanQR:
            components.host = "qr"
            components.path = "/scan"
        case .unlockApp:
            components.host = "applock"
            components.path = "/unlock"
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let first = url.pathComponents.dropFirst().first ?? ""
        switch (host, first) {
        case ("module", let id):
            guard let module = ModuleID(rawValue: id) else { return nil }
            self = .module(module)
        case ("clipboard", "save"): self = .saveClipboard
        case ("sticky", "new"): self = .newStickyNote
        case ("floating", let mode): self = .floating(mode)
        case ("share", "receive"): self = .receiveFiles
        case ("qr", "scan"): self = .scanQR
        case ("applock", "unlock"): self = .unlockApp
        default: return nil
        }
    }

    var module: ModuleID {
        switch self {
        case .module(let id): return id
        case .saveClipboard: return .clipboard
        case .newStickyNote: return .stickyNotes
        case .floating: return .floatingWindow
        case .receiveFiles: return .shareAnywhere
        case .scanQR: return .qrCode
        case .unlockApp: return .appLock
        }
    }
}
