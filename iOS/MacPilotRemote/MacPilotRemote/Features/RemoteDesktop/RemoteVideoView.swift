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
