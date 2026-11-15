import SwiftUI

/// A bar a quarter of the tile wide, labeled in miles.
///
/// `tileSide` is the on-screen length, in points, of the full square tile. A square shown
/// with `.aspectRatio(contentMode: .fill)` spans its view's longer side, so pass
/// `max(width, height)` of that view; this stays right when a widget crops the square.
public struct ScaleBar: View {
    public let zoom: ZoomLevel
    public let tileSide: CGFloat

    public init(zoom: ZoomLevel, tileSide: CGFloat) {
        self.zoom = zoom
        self.tileSide = tileSide
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(zoom.rawValue / 4) mi")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
            BarShape()
                .stroke(.black.opacity(0.6), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .overlay(BarShape().stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)))
                .frame(width: tileSide / 4, height: 4)
        }
        .accessibilityHidden(true)
    }

    private struct BarShape: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
        }
    }
}
