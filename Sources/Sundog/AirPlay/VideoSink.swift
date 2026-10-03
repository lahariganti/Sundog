import AVFoundation

/// Sends compressed video samples from the network queue to the display layer of the window.
/// The display layer decodes the samples.
final class VideoSink: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer

    @MainActor
    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sample)
    }

    func clear() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}
