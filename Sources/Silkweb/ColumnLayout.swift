import SwiftUI

/// Chrome keeps its intrinsic height; every body fills the remaining column.
struct PinnedColumn<Chrome: View, Content: View>: View {
    @ViewBuilder var chrome: () -> Chrome
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome().fixedSize(horizontal: false, vertical: true)
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Optical centering applies only to the space below the pinned chrome.
/// Geometry stays in layout: no per-resize state publications.
struct ColumnEmptyState<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            content()
                .fixedSize(horizontal: false, vertical: true)
                .columnLayoutAnchor("column-empty-body")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: -min(24, geometry.size.height / 10))
        }
        .columnLayoutAnchor("column-empty-region")
    }
}

#if DEBUG
/// Offscreen XCTest reads anchors from the real SwiftUI hierarchy. These have
/// no observers in the app and are omitted entirely from release builds.
struct ColumnLayoutAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
#endif

extension View {
    func columnLayoutAnchor(_ name: String) -> some View {
        #if DEBUG
        transformAnchorPreference(key: ColumnLayoutAnchors.self, value: .bounds) { values, anchor in
            values[name] = anchor
        }
        #else
        self
        #endif
    }
}
