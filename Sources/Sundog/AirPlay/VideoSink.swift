import AVFoundation
import os

/// Sends compressed video samples from the network queue to the display layer of the window.
/// The display layer decodes the samples.
final class VideoSink: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lahariganti.Sundog", category: "VideoSink")
    private let renderer: AVSampleBufferVideoRenderer
    private var reportedFailure = false

    @MainActor
    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            if !reportedFailure {
                reportedFailure = true
                Self.logger.error("Video decoder failed: \(String(describing: self.renderer.error), privacy: .public)")
            }
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    func clear() {
        reportedFailure = false
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
