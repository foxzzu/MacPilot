@preconcurrency import AVFoundation
import Foundation
import MacPilotRemoteProtocol
import VideoToolbox

struct RemoteVideoMetrics: Sendable {
    var fps = 0.0
    var decodeMs = 0.0
    var kbps = 0.0
    var dropped = 0
}

/// Used only on the video socket queue. Synchronous decode keeps at most one
/// compressed frame pending. The display layer is bounded to two ready frames.
final class RemoteVideoDecoder: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private var waitingForKeyFrame = true
    private var frames = 0
    private var decodeTotal = 0.0
    private var bytes = 0
    private var dropped = 0
    private var lastReport = ProcessInfo.processInfo.systemUptime
    var onMetrics: (@Sendable (RemoteVideoMetrics) -> Void)?
    var onNeedsKeyFrame: (@Sendable () -> Void)?
    var onFirstFrame: (@Sendable () -> Void)?
    private var displayed = false

    init() { layer.videoGravity = .resizeAspect }

    func receive(_ packet: RemoteVideoPacket) {
        guard packet.frameType == .keyFrame || packet.frameType == .deltaFrame else { return }
        let key = packet.frameType == .keyFrame
        if waitingForKeyFrame, !key { dropped += 1; return }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let frame = try RemoteH264Frame.decode(packet.payload, keyFrame: key)
            if key, frame.sps != sps || frame.pps != pps || session == nil {
                try configure(frame)
            }
            guard let session, let format else { throw RemoteProtocolError.invalidMessage }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: frame.avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: frame.avcc.count, flags: 0, blockBufferOut: &block) == noErr,
                let block else { throw RemoteProtocolError.invalidMessage }
            let copyStatus = frame.avcc.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
            }
            guard copyStatus == noErr else { throw RemoteProtocolError.invalidMessage }
            var sample: CMSampleBuffer?
            var size = frame.avcc.count
            guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                let sample else { throw RemoteProtocolError.invalidMessage }
            let output = VideoFrameBuffer()
            // Without asynchronous flags the callback completes before return.
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                if status == noErr, let image { output.replace(image) }
            }
            guard status == noErr, let pixel = output.takeLatest() else { throw RemoteProtocolError.invalidMessage }
            waitingForKeyFrame = false
            render(pixel)
            frames += 1; bytes += packet.payload.count
            decodeTotal += (ProcessInfo.processInfo.systemUptime - started) * 1000
            if !displayed { displayed = true; onFirstFrame?() }
        } catch {
            dropped += 1; waitingForKeyFrame = true
            onNeedsKeyFrame?()
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastReport
        if elapsed >= 1 {
            onMetrics?(RemoteVideoMetrics(fps: Double(frames) / elapsed,
                decodeMs: decodeTotal / Double(max(1, frames)), kbps: Double(bytes) * 8 / elapsed / 1000, dropped: dropped))
            lastReport = now; frames = 0; bytes = 0; decodeTotal = 0
        }
    }

    private func configure(_ frame: RemoteH264Frame) throws {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
        let status = frame.sps.withUnsafeBytes { spsBytes in
            frame.pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), ppsBytes.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [spsBytes.count, ppsBytes.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                    parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format,
              VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                outputCallback: nil, decompressionSessionOut: &session) == noErr else { throw RemoteProtocolError.invalidMessage }
        sps = frame.sps; pps = frame.pps
        layer.flushAndRemoveImage()
    }

    private func render(_ pixel: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
        let dictionary = attachments[0] as! NSMutableDictionary
        dictionary[kCMSampleAttachmentKey_DisplayImmediately] = true
        if layer.status == .failed || !layer.isReadyForMoreMediaData {
            layer.flush()
            dropped += 1
        }
        layer.enqueue(sample)
    }

    func stop() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil
        waitingForKeyFrame = true
        layer.flushAndRemoveImage()
    }
}
