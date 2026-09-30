import CoreGraphics
import Testing
@testable import PilotNest

struct RemoteVideoZoomTests {
    @Test func zoomKeepsTheImagePointUnderThePinchStationary() {
        let size = CGSize(width: 400, height: 300)
        let anchor = CGPoint(x: 100, y: 100)
        var zoom = RemoteVideoZoom()
        zoom.update(from: RemoteVideoZoom(), factor: 2, start: anchor, location: anchor, viewport: size)
        #expect(zoom.scale == 2)
        #expect(200 + (anchor.x - 200) * zoom.scale + zoom.offset.width == anchor.x)
        #expect(150 + (anchor.y - 150) * zoom.scale + zoom.offset.height == anchor.y)
    }

    @Test func returningToOriginalSizeRemovesAllPan() {
        let size = CGSize(width: 400, height: 300)
        var zoom = RemoteVideoZoom()
        zoom.update(from: RemoteVideoZoom(), factor: 3, start: CGPoint(x: 50, y: 50),
                    location: CGPoint(x: 120, y: 150), viewport: size)
        let baseline = zoom
        zoom.update(from: baseline, factor: 0.1, start: .zero, location: CGPoint(x: 500, y: 500), viewport: size)
        #expect(zoom == RemoteVideoZoom())
    }

    @Test func zoomAndPanStayBoundedAfterKeyboardResizesPreview() {
        var zoom = RemoteVideoZoom()
        zoom.update(from: RemoteVideoZoom(), factor: 100, start: .zero,
                    location: CGPoint(x: 900, y: 900), viewport: CGSize(width: 400, height: 300))
        #expect(zoom.scale == 4)
        zoom.constrain(to: CGSize(width: 200, height: 100))
        #expect(abs(zoom.offset.width) <= 300)
        #expect(abs(zoom.offset.height) <= 150)
    }

    @Test func invalidGestureSamplesDoNotChangeThePreview() {
        for factor in [CGFloat.nan, .infinity, -1, 0] {
            var zoom = RemoteVideoZoom()
            zoom.update(from: zoom, factor: factor, start: .zero, location: .zero, viewport: CGSize(width: 400, height: 300))
            #expect(zoom == RemoteVideoZoom())
        }
    }
}
