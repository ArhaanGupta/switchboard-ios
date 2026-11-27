import SwiftUI
import SwitchboardCore

/// What gets drawn into the floating window.
struct FloatingContentView: View {
    let mode: FloatingController.Mode
    let timerRemaining: TimeInterval
    let stopwatchElapsed: TimeInterval
    let note: String
    let script: String
    let scrollOffset: CGFloat
    let isRunning: Bool
    let accent: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.08), accent.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            switch mode {
            case .timer:
                bigNumber(Self.clock(timerRemaining), caption: timerRemaining <= 0 ? "Time's up!" : (isRunning ? "Timer" : "Paused"))
            case .stopwatch:
                bigNumber(Self.clock(stopwatchElapsed, tenths: true), caption: isRunning ? "Stopwatch" : "Paused")
            case .note:
                Text(note.isEmpty ? "Empty note" : note)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.4)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .teleprompter:
                GeometryReader { geo in
                    Text(script)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .frame(width: geo.size.width, alignment: .leading)
                        .offset(y: geo.size.height * 0.4 - scrollOffset)
                }
                .clipped()
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Color(white: 0.08), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 50)
                }
            }
        }
    }

    private func bigNumber(_ text: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(text)
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(caption.uppercased())
                .font(.system(size: 20, weight: .semibold))
                .kerning(2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 20)
    }

    static func clock(_ interval: TimeInterval, tenths: Bool = false) -> String {
        let total = max(0, interval)
        let hours = Int(total) / 3600
        let minutes = Int(total) / 60 % 60
        let seconds = Int(total) % 60
        var s = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
        if tenths { s += String(format: ".%d", Int(total * 10) % 10) }
        return s
    }
}

struct FloatingScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var floating = app.floating
        ScrollView {
            VStack(spacing: 18) {
                FloatingLayerView(controller: floating)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 22, style: .continuous))
                    .shadow(color: .purple.opacity(0.3), radius: 16, y: 8)
                    .overlay(alignment: .topTrailing) {
                        if floating.isFloating {
                            Label("Floating", systemImage: "pip.fill")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                                .padding(10)
                        }
                    }

                Picker("Mode", selection: $floating.mode) {
                    ForEach(FloatingController.Mode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: floating.mode) { _, _ in floating.reset() }

                GlassCard {
                    switch floating.mode {
                    case .timer:
                        Stepper(value: $floating.timerMinutes, in: 1...240) {
                            LabeledContent("Duration", value: "\(floating.timerMinutes) min")
                        }
                        .onChange(of: floating.timerMinutes) { _, _ in if !floating.isRunning { floating.reset() } }
                    case .stopwatch:
                        Text("Counts up from zero. Use the play/pause button in the floating window.")
                            .font(.footnote).foregroundStyle(.secondary)
                    case .note:
                        TextField("Note", text: $floating.noteText, axis: .vertical)
                            .lineLimit(2...6)
                            .onChange(of: floating.noteText) { _, _ in floating.reset() }
                    case .teleprompter:
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Script", text: $floating.teleprompterText, axis: .vertical)
                                .lineLimit(4...12)
                            LabeledContent("Speed") {
                                Slider(value: $floating.teleprompterSpeed, in: 5...120)
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    if floating.mode != .note {
                        Button {
                            floating.togglePlay()
                        } label: {
                            Label(floating.isRunning ? "Pause" : "Start",
                                  systemImage: floating.isRunning ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)

                        Button {
                            floating.reset()
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }

                Button {
                    Haptics.tap()
                    floating.isFloating ? floating.stop() : floating.popOut()
                } label: {
                    Label(floating.isFloating ? "Close Floating Window" : "Float Over Other Apps",
                          systemImage: floating.isFloating ? "pip.exit" : "pip.enter")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(.purple)
                .disabled(!floating.isPossible && !floating.isFloating)

                Text("The window keeps running when you switch apps. Drag it anywhere, pinch to resize, or swipe it to the edge to hide it. Picture-in-Picture must be on in Settings → General → Picture in Picture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
        }
        .moduleBackground(ModuleID.floatingWindow.tint)
    }
}
