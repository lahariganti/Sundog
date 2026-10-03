import AVFoundation

/// Sends decoded-ready video samples to the window's display layer from the network queue.
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
