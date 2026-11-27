import SwiftUI
import WidgetKit

@main
struct SwitchboardWidgets: WidgetBundle {
    var body: some Widget {
        StickyNoteWidget()
        StickyNoteLiveActivity()
        SaveClipboardControl()
        NewStickyNoteControl()
        FloatingTimerControl()
        ReceiveFilesControl()
    }
}
