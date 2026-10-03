import AppKit
import SwiftUI

extension NSColor {
    /// The one background every window pane paints (silkweb-1.56): sidebar, document list, tab bar,
    /// editor, preview, Inspector, strips and banners, toolbar and empty states.
    /// Dynamic per appearance, including Increase Contrast; the single swap point for 1.24 settings.
    static let silkwebPaneBackground = NSColor(name: "SilkwebPaneBackground") { _ in .textBackgroundColor }
}

extension Color {
    static let silkwebPaneBackground = Color(nsColor: .silkwebPaneBackground)
}

extension View {
    /// A pane-colored strip with one separator hairline on the edge facing the content.
    func paneStrip(hairline edge: VerticalEdge) -> some View {
        modifier(PaneStrip(edge: edge))
    }
}

private struct PaneStrip: ViewModifier {
    let edge: VerticalEdge
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .background(Color.silkwebPaneBackground)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1 / max(1, displayScale))
                    .accessibilityHidden(true)
            }
    }
}
