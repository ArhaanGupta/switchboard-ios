import AVFoundation
import AVKit
import CoreMedia
import SwiftUI
import UIKit

/// Floats live SwiftUI content over other apps by rendering it into a
/// Picture-in-Picture video stream (AVSampleBufferDisplayLayer).
@MainActor
@Observable
final class FloatingController: NSObject {
    enum Mode: String, CaseIterable, Identifiable {
        case timer, stopwatch, note, teleprompter
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .timer: "timer"
            case .stopwatch: "stopwatch"
            case .note: "note.text"
            case .teleprompter: "text.alignleft"
            }
        }
    }

    // Configuration
    var mode: Mode = .timer { didSet { renderFrame() } }
    var timerMinutes = 5
    var noteText = "Remember to…"
    var teleprompterText = "Paste your script here. It scrolls in the floating window while you record or present in another app."
    var teleprompterSpeed: Double = 30 // points per second
    var accent: Color = .purple

    // Runtime state
    private(set) var isFloating = false
    private(set) var isRunning = false {
        didSet { playbackPaused.write { $0 = !isRunning } }
    }
    private(set) var isPossible = false
    private(set) var timerEnd: Date?
    private(set) var pausedRemaining: TimeInterval?
    private(set) var stopwatchStart: Date?
    private(set) var stopwatchAccumulated: TimeInterval = 0
    private var teleprompterOffset: CGFloat = 0
    private var lastTick = Date()

    /// Readable from PiP callbacks on any thread.
    @ObservationIgnored private let playbackPaused = Locked(true)
    let displayLayer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var ticker: Timer?
    private let renderSize = CGSize(width: 480, height: 270)

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    // MARK: Setup

    /// Call once the display layer is in the view hierarchy.
    func prepare() {
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        startTicker()
        renderFrame()
    }

    func popOut() {
        renderFrame()
        pip?.startPictureInPicture()
    }

    func stop() {
        pip?.stopPictureInPicture()
        isRunning = false
        timerEnd = nil
        pausedRemaining = nil
        stopwatchStart = nil
        stopwatchAccumulated = 0
        teleprompterOffset = 0
        renderFrame()
    }

    // MARK: Play / pause

    func togglePlay() {
        isRunning ? pause() : play()
    }

    func play() {
        switch mode {
        case .timer:
            let remaining = pausedRemaining ?? TimeInterval(timerMinutes * 60)
            timerEnd = Date().addingTimeInterval(remaining)
            pausedRemaining = nil
        case .stopwatch:
            stopwatchStart = Date()
        case .teleprompter, .note:
            break
        }
        lastTick = Date()
        isRunning = true
        pip?.invalidatePlaybackState()
        renderFrame()
    }

    func pause() {
        switch mode {
        case .timer:
            if let end = timerEnd { pausedRemaining = max(0, end.timeIntervalSinceNow) }
            timerEnd = nil
        case .stopwatch:
            if let start = stopwatchStart { stopwatchAccumulated += Date().timeIntervalSince(start) }
            stopwatchStart = nil
        case .teleprompter, .note:
            break
        }
        isRunning = false
        pip?.invalidatePlaybackState()
        renderFrame()
    }

    func reset() {
        isRunning = false
        timerEnd = nil
        pausedRemaining = nil
        stopwatchStart = nil
        stopwatchAccumulated = 0
        teleprompterOffset = 0
        pip?.invalidatePlaybackState()
        renderFrame()
    }

    // MARK: Values shown in the window

    var timerRemaining: TimeInterval {
        if let end = timerEnd { return max(0, end.timeIntervalSinceNow) }
        return pausedRemaining ?? TimeInterval(timerMinutes * 60)
    }

    var stopwatchElapsed: TimeInterval {
        stopwatchAccumulated + (stopwatchStart.map { Date().timeIntervalSince($0) } ?? 0)
    }

    // MARK: Rendering

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if isRunning, mode == .teleprompter {
            teleprompterOffset += CGFloat(dt * teleprompterSpeed)
        }
        if isRunning, mode == .timer, timerRemaining <= 0 {
            isRunning = false
            timerEnd = nil
            pausedRemaining = 0
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            pip?.invalidatePlaybackState()
        }
        // Static content doesn't need 15 fps.
        if isRunning || mode == .teleprompter || Int(now.timeIntervalSince1970 * 15) % 15 == 0 {
            renderFrame()
        }
    }

    private func renderFrame() {
        let content = FloatingContentView(
            mode: mode,
            timerRemaining: timerRemaining,
            stopwatchElapsed: stopwatchElapsed,
            note: noteText,
            script: teleprompterText,
            scrollOffset: teleprompterOffset,
            isRunning: isRunning,
            accent: accent
        )
        .frame(width: renderSize.width, height: renderSize.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let buffer = Self.sampleBuffer(from: image) else { return }
        if displayLayer.sampleBufferRenderer.status == .failed {
            displayLayer.sampleBufferRenderer.flush()
        }
        displayLayer.sampleBufferRenderer.enqueue(buffer)
    }

    nonisolated static func sampleBuffer(from image: CGImage) -> CMSampleBuffer? {
        let width = image.width, height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - PiP delegates

extension FloatingController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isFloating = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isFloating = false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        print("PiP failed: \(error)")
    }
}

extension FloatingController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in playing ? self.play() : self.pause() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Live content: no scrubber.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        playbackPaused.read { $0 }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime) async {
        await MainActor.run {
            switch mode {
            case .timer:
                // Skip buttons add or remove time.
                let delta = skipInterval.seconds
                if let end = timerEnd {
                    timerEnd = end.addingTimeInterval(delta)
                } else {
                    pausedRemaining = max(0, timerRemaining + delta)
                }
            case .teleprompter:
                teleprompterOffset = max(0, teleprompterOffset + CGFloat(skipInterval.seconds * 4))
            default:
                break
            }
            renderFrame()
        }
    }
}

/// UIKit host for the display layer (PiP needs it on screen before popping out).
struct FloatingLayerView: UIViewRepresentable {
    let controller: FloatingController

    func makeUIView(context: Context) -> LayerHostView {
        let view = LayerHostView()
        view.hostedLayer = controller.displayLayer
        DispatchQueue.main.async { controller.prepare() }
        return view
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}

    final class LayerHostView: UIView {
        var hostedLayer: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hostedLayer { layer.addSublayer(hostedLayer) }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
