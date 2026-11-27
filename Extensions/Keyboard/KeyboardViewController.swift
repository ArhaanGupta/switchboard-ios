import ClipboardCore
import SwiftUI
import SwitchboardCore
import UIKit

/// The Switchboard clipboard keyboard: tap a clip or snippet to type it.
/// While the keyboard is visible it also records new clipboard contents,
/// which is how history builds up without opening the app.
final class KeyboardViewController: UIInputViewController {
    private let state = KeyboardState()
    private var host: UIHostingController<KeyboardRootView>?
    private var pollTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        state.actions = KeyboardActions(
            insert: { [weak self] text in self?.insert(text) },
            deleteBackward: { [weak self] in self?.textDocumentProxy.deleteBackward() },
            space: { [weak self] in self?.textDocumentProxy.insertText(" ") },
            newline: { [weak self] in self?.textDocumentProxy.insertText("\n") },
            nextKeyboard: { [weak self] in self?.advanceToNextInputMode() },
            dismiss: { [weak self] in self?.dismissKeyboard() },
            togglePin: { [weak self] item in
                ClipboardStore.shared.togglePin(item.id)
                self?.state.reload()
            },
            delete: { [weak self] item in
                ClipboardStore.shared.delete(item.id)
                self?.state.reload()
            }
        )

        let root = KeyboardRootView(state: state)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 290)
        height.priority = .defaultHigh
        height.isActive = true
        host.didMove(toParent: self)
        self.host = host
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let defaults = AppGroup.defaults
        defaults.set(Date(), forKey: SharedKey.keyboardLastSeen)
        defaults.set(hasFullAccess, forKey: SharedKey.keyboardHasFullAccess)

        state.hasFullAccess = hasFullAccess
        state.moduleEnabled = FeatureFlags().isEnabled(.clipboard)
        state.showsGlobe = needsInputModeSwitchKey
        captureClipboardIfChanged()
        state.reload()

        // Catch copies made while the keyboard stays on screen.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.captureClipboardIfChanged()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func captureClipboardIfChanged() {
        guard hasFullAccess, state.moduleEnabled else { return }
        let board = UIPasteboard.general
        let defaults = AppGroup.defaults
        let last = defaults.integer(forKey: SharedKey.pasteboardChangeCount)
        guard board.changeCount != last else { return }
        defaults.set(board.changeCount, forKey: SharedKey.pasteboardChangeCount)
        guard board.hasStrings || board.hasURLs,
              let text = board.string ?? board.url?.absoluteString else { return }
        if ClipboardStore.shared.add(text: text) != nil {
            state.reload()
        }
    }

    private func insert(_ text: String) {
        textDocumentProxy.insertText(text)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // One-tap flow: paste the clip, then hop back to the keyboard you were typing with.
        let returnAfterPaste = AppGroup.defaults.object(forKey: SharedKey.keyboardReturnAfterPaste) as? Bool ?? true
        if returnAfterPaste {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.advanceToNextInputMode()
            }
        }
    }
}

struct KeyboardActions {
    var insert: (String) -> Void = { _ in }
    var deleteBackward: () -> Void = {}
    var space: () -> Void = {}
    var newline: () -> Void = {}
    var nextKeyboard: () -> Void = {}
    var dismiss: () -> Void = {}
    var togglePin: (ClipItem) -> Void = { _ in }
    var delete: (ClipItem) -> Void = { _ in }
}

@MainActor
@Observable
final class KeyboardState {
    var items: [ClipItem] = []
    var snippets: [Snippet] = []
    var hasFullAccess = false
    var moduleEnabled = true
    var showsGlobe = true
    var actions = KeyboardActions()

    func reload() {
        guard hasFullAccess else { return }
        let db = ClipboardStore.shared.database()
        items = db.items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.lastUsedAt > $1.lastUsedAt
        }
        snippets = db.snippets
    }

    func render(_ snippet: Snippet) -> String {
        TemplateRenderer(clipboard: hasFullAccess ? UIPasteboard.general.string : nil).render(snippet.body)
    }
}
