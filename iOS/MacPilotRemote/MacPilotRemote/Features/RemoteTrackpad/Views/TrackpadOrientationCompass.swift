import SwiftUI

/// The four edge arrows that show and switch the trackpad's hold.
///
/// Each edge midpoint carries a small chevron pointing outward, dimmed to 30%
/// opacity; the edge that currently serves as the trackpad's "up" is tinted.
/// Tapping an arrow makes that edge the top — only the finger→cursor mapping
/// rotates, the page itself never does.
struct TrackpadOrientationCompass: View {
    let orientation: TrackpadOrientation
    let onSelect: (TrackpadOrientation) -> Void
    let text: (String) -> String

    /// How far an arrow's center sits in from the surface edge: enough that
    /// the 44×40 tap target stays fully on the surface.
    private let inset: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let middleX = proxy.size.width / 2
            let middleY = proxy.size.height / 2
            arrow(.top, rotation: .zero)
                .position(x: middleX, y: inset)
            arrow(.bottom, rotation: .degrees(180))
                .position(x: middleX, y: proxy.size.height - inset)
            arrow(.left, rotation: .degrees(-90))
                .position(x: inset, y: middleY)
            arrow(.right, rotation: .degrees(90))
                .position(x: proxy.size.width - inset, y: middleY)
        }
        .animation(.easeInOut(duration: 0.15), value: orientation)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text("trackpadOrientation"))
    }

    private func arrow(_ hold: TrackpadOrientation, rotation: Angle) -> some View {
        let isActive = hold == orientation
        return Button {
            Haptics.impact()
            onSelect(hold)
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 15, weight: isActive ? .bold : .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(0.3))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
                .rotationEffect(rotation)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text(labelKey(hold)))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func labelKey(_ hold: TrackpadOrientation) -> String {
        switch hold {
        case .top: return "trackpadOrientationTop"
        case .bottom: return "trackpadOrientationBottom"
        case .left: return "trackpadOrientationLeft"
        case .right: return "trackpadOrientationRight"
        }
    }
}
