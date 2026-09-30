import AVFoundation
import SwiftUI

struct RemoteVideoView: UIViewRepresentable {
    let decoder: RemoteVideoDecoder
    func makeUIView(context: Context) -> VideoSurface {
        let view = VideoSurface()
        view.display = decoder.layer
        view.layer.addSublayer(decoder.layer)
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ view: VideoSurface, context: Context) {
        if view.display !== decoder.layer {
            view.display?.removeFromSuperlayer()
            view.display = decoder.layer
            view.layer.addSublayer(decoder.layer)
        }
        view.setNeedsLayout()
    }
}

final class VideoSurface: UIView {
    var display: AVSampleBufferDisplayLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        display?.frame = bounds
        CATransaction.commit()
    }
}

/// Local preview transform; it never changes the Mac pointer or video stream.
struct RemoteVideoZoom: Equatable {
    static let maximumScale: CGFloat = 4
    private(set) var scale: CGFloat = 1
    private(set) var offset = CGSize.zero

    mutating func update(from baseline: RemoteVideoZoom, factor: CGFloat,
                         start: CGPoint, location: CGPoint, viewport: CGSize) {
        guard factor.isFinite, factor > 0, location.x.isFinite, location.y.isFinite,
              viewport.width > 0, viewport.height > 0 else { return }
        scale = min(Self.maximumScale, max(1, baseline.scale * factor))
        let ratio = scale / baseline.scale
        offset = CGSize(
            width: location.x - viewport.width / 2 - (start.x - viewport.width / 2 - baseline.offset.width) * ratio,
            height: location.y - viewport.height / 2 - (start.y - viewport.height / 2 - baseline.offset.height) * ratio
        )
        constrain(to: viewport)
    }

    mutating func constrain(to viewport: CGSize) {
        let x = max(0, viewport.width * (scale - 1) / 2)
        let y = max(0, viewport.height * (scale - 1) / 2)
        offset.width = min(x, max(-x, offset.width))
        offset.height = min(y, max(-y, offset.height))
    }
}
