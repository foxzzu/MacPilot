import CoreVideo
import Foundation

/// A single latest decoded surface. The VT callback may execute on a codec
/// thread even with synchronous decode, so ownership crosses through a lock.
final class VideoFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pixel: CVPixelBuffer?
    func replace(_ pixel: CVPixelBuffer) { lock.withLock { self.pixel = pixel } }
    func takeLatest() -> CVPixelBuffer? {
        lock.withLock { defer { pixel = nil }; return pixel }
    }
}
