import AppIntents
import SwiftUI
import WidgetKit

// Control Center / Lock Screen / Action button controls — the iOS take on
// Android Quick Settings tiles. Each one deep-links into the app, which does
// the work in the foreground (needed for clipboard access and networking).

struct SaveClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.switchboard.control.saveClipboard") {
            ControlWidgetButton(action: OpenURLIntent(DeepLink.saveClipboard.url)) {
                Label("Save Clipboard", systemImage: "doc.on.clipboard.fill")
            }
        }
        .displayName("Save Clipboard")
        .description("Add what you just copied to your Switchboard history.")
    }
}

struct NewStickyNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.switchboard.control.newNote") {
            ControlWidgetButton(action: OpenURLIntent(DeepLink.newStickyNote.url)) {
                Label("New Sticky Note", systemImage: "note.text.badge.plus")
            }
        }
        .displayName("New Sticky Note")
        .description("Jot a note you can pin to the Lock Screen.")
    }
}

struct FloatingTimerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.switchboard.control.floatingTimer") {
            ControlWidgetButton(action: OpenURLIntent(DeepLink.floating("timer").url)) {
                Label("Floating Timer", systemImage: "pip.fill")
            }
        }
        .displayName("Floating Timer")
        .description("Open a timer that floats over other apps.")
    }
}

struct ReceiveFilesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.switchboard.control.receive") {
            ControlWidgetButton(action: OpenURLIntent(DeepLink.receiveFiles.url)) {
                Label("Receive Files", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .displayName("Receive Files")
        .description("Become visible to Windows, Linux and Android devices running LocalSend.")
    }
}

struct ScanQRControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.switchboard.control.scanQR") {
            ControlWidgetButton(action: OpenURLIntent(DeepLink.scanQR.url)) {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
            }
        }
        .displayName("Scan QR Code")
        .description("Scan a code and keep it in your history.")
    }
}
