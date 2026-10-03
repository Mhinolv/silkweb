import AppKit
import SwiftUI
import SilkwebCore

/// Redesign tokens (silkweb-1.62). R2–R4 consume these and add no new colour values.
/// Each colour is dynamic per appearance; Increase Contrast has its own value.
enum SilkwebTokens {
    struct Palette: Equatable {
        let light: Int, dark: Int, highContrastLight: Int?, highContrastDark: Int?
    }

    static let pane = Palette(light: 0xFBFBFA, dark: 0x1E1F21, highContrastLight: nil, highContrastDark: nil)
    static let accent = Palette(light: 0x3F7D64, dark: 0x7FC0A4, highContrastLight: 0x2F6550, highContrastDark: 0x8FD0B3)
    static let selection = Palette(light: 0xE4ECE8, dark: 0x2F3C39, highContrastLight: 0xD5E2DC, highContrastDark: 0x33423E)
    static let selectionInactive = Palette(light: 0xEFEFEE, dark: 0x2B2D30, highContrastLight: nil, highContrastDark: nil)
    static let coral = Palette(light: 0xCC6544, dark: 0xF29A7A, highContrastLight: 0xB8563A, highContrastDark: 0xFFB295)
    static let thread = Palette(light: 0xC2C9C0, dark: 0x3D4640, highContrastLight: 0x9AA39C, highContrastDark: 0x6A746D)

    static func srgb(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func hex(_ rgb: Int) -> String { String(format: "#%06X", rgb) }

    /// `fallback` is the system colour used under Increase Contrast when the palette has none.
    static func resolve(_ palette: Palette, dark: Bool, highContrast: Bool, fallback: NSColor? = nil) -> NSColor {
        switch (dark, highContrast) {
        case (false, false): return srgb(palette.light)
        case (true, false): return srgb(palette.dark)
        case (false, true): return palette.highContrastLight.map(srgb) ?? fallback ?? srgb(palette.light)
        case (true, true): return palette.highContrastDark.map(srgb) ?? fallback ?? srgb(palette.dark)
        }
    }

    /// A user colour from Settings (1.24) for this appearance, or nil to keep the token.
    typealias Override = @Sendable (_ colors: ColorSet, _ dark: Bool) -> HexColor?

    static func color(_ name: String, _ palette: Palette, fallback: NSColor? = nil, override: Override? = nil) -> NSColor {
        NSColor(name: name) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if let override, let custom = override(LivePreferences.shared.colors(dark: dark), dark) { return srgb(custom.rgb) }
            let contrast = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                       .accessibilityHighContrastDarkAqua])
            let highContrast = contrast == .accessibilityHighContrastAqua || contrast == .accessibilityHighContrastDarkAqua
            return resolve(palette, dark: dark, highContrast: highContrast, fallback: fallback)
        }
    }

    /// A system colour unless the user's set overrides it.
    static func color(_ name: String, system: NSColor, override: @escaping Override) -> NSColor {
        NSColor(name: name) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if let custom = override(LivePreferences.shared.colors(dark: dark), dark) { return srgb(custom.rgb) }
            return system
        }
    }

    /// Derived colours follow the user's Surface/Text/Accent only once one of their inputs changed.
    static let surfaceOrText: Override = { set, dark in set.surface == nil && set.text == nil ? nil : set.hairline(dark: dark) }

    /// Live preview only: export and print keep their portable system colours.
    static let previewCSS = """
    :root { --sw-surface: \(hex(pane.light)); --sw-accent: \(hex(accent.light)); }
    @media (prefers-color-scheme: dark) { :root { --sw-surface: \(hex(pane.dark)); --sw-accent: \(hex(accent.dark)); } }
    @media (prefers-contrast: more) { :root { --sw-surface: -apple-system-text-background; --sw-accent: \(hex(accent.highContrastLight!)); } }
    @media (prefers-color-scheme: dark) and (prefers-contrast: more) { :root { --sw-accent: \(hex(accent.highContrastDark!)); } }
    body { background: var(--sw-surface); } a { color: var(--sw-accent); }
    """
}

/// The 8 pt spacing scale and the fixed redesign metrics.
enum Spacing {
    static let xxSmall: CGFloat = 4
    static let xSmall: CGFloat = 8
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let large: CGFloat = 20
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
    static let page: CGFloat = 48

    static let sidebarRowHeight: CGFloat = 28
    static let capsuleInset: CGFloat = 10
    static let editorHorizontalInset: CGFloat = page
    static let tabBarHeight: CGFloat = 32
    static let statusBarHeight: CGFloat = 26
}

extension NSColor {
    /// The one background every window pane paints (silkweb-1.56): sidebar, document list, tab bar,
    /// editor, preview, Inspector, strips and banners, toolbar and empty states.
    /// #FBFBFA / #1E1F21 (1.62); the system text background under Increase Contrast. The swap point for 1.24.
    /// Settings ▸ Appearance ▸ Surface replaces it per appearance (1.24).
    static let silkwebPaneBackground = SilkwebTokens.color("SilkwebPaneBackground", SilkwebTokens.pane, fallback: .textBackgroundColor,
                                                           override: { set, _ in set.surface })
    /// Sage: Silkweb-drawn selection accents, links and tag tints. Native focus rings keep the system accent.
    static let silkwebAccent = SilkwebTokens.color("SilkwebAccent", SilkwebTokens.accent, override: { set, _ in set.accent })
    /// Capsule fill for the focused selection in the key window: Accent tinted over Surface once either is custom.
    static let silkwebSelection = SilkwebTokens.color("SilkwebSelection", SilkwebTokens.selection, override: { set, dark in
        set.surface == nil && set.accent == nil ? nil : set.selection(dark: dark)
    })
    /// Inactive capsule and the current-line band: Surface stepped toward Text once either is custom.
    static let silkwebSelectionInactive = SilkwebTokens.color("SilkwebSelectionInactive", SilkwebTokens.selectionInactive,
                                                              fallback: .unemphasizedSelectedContentBackgroundColor, override: { set, dark in
        set.surface == nil && set.text == nil ? nil : set.selectionInactive(dark: dark)
    })
    /// Only the current-folder node and unsaved dots (R2/R4); the user may recolour but not repurpose it.
    static let silkwebCoral = SilkwebTokens.color("SilkwebCoral", SilkwebTokens.coral, override: { set, _ in set.coral })
    /// Sidebar thread lines (R2); they follow the derived hairline.
    static let silkwebThread = SilkwebTokens.color("SilkwebThread", SilkwebTokens.thread, override: SilkwebTokens.surfaceOrText)
    /// Body text in the editor (1.24 Text slot); `labelColor` by default.
    static let silkwebText = SilkwebTokens.color("SilkwebText", system: .labelColor, override: { set, _ in set.text })
    /// Pane dividers and strip hairlines; `separatorColor` until Surface or Text is custom.
    static let silkwebHairline = SilkwebTokens.color("SilkwebHairline", system: .separatorColor, override: SilkwebTokens.surfaceOrText)
}

/// Puts the window's titlebar/toolbar strip on the pane surface (silkweb-1.62): the titlebar stops drawing
/// its own material and the window background behind it is the pane token.
struct WindowSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .silkwebPaneBackground
            // A transparent titlebar draws no separator; `TitlebarHairline` is the one divider.
            window.titlebarSeparatorStyle = .none
            // The compact bar (1.65); the scene sets it at creation, other hosts get it here at the same frame.
            if window.toolbarStyle != .unifiedCompact {
                let frame = window.frame
                window.toolbarStyle = .unifiedCompact
                window.setFrame(frame, display: false)
            }
        }
    }
}

/// The single hairline under the titlebar strip, overlaid on the top edge of the window content.
struct TitlebarHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle().fill(Color.silkwebHairline).frame(height: 1 / max(1, displayScale))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Reading one of these in a SwiftUI body subscribes it to colour changes from Settings (1.24):
/// each revision wraps the token in a newly named colour, so SwiftUI sees a new value and redraws.
@MainActor extension Color {
    static var silkwebPaneBackground: Color { revised(.silkwebPaneBackground) }
    static var silkwebAccent: Color { revised(.silkwebAccent) }
    static var silkwebSelection: Color { revised(.silkwebSelection) }
    static var silkwebSelectionInactive: Color { revised(.silkwebSelectionInactive) }
    static var silkwebCoral: Color { revised(.silkwebCoral) }
    static var silkwebThread: Color { revised(.silkwebThread) }
    static var silkwebHairline: Color { revised(.silkwebHairline) }

    private static var revisions: [String: (revision: Int, color: Color)] = [:]

    private static func revised(_ token: NSColor) -> Color {
        let revision = ColorRevision.shared.value
        let name = token.colorNameComponent
        guard revision > 0 else { return Color(nsColor: token) }
        if let cached = revisions[name], cached.revision == revision { return cached.color }
        let color = Color(nsColor: NSColor(name: "\(name).\(revision)") { appearance in
            var resolved = token
            appearance.performAsCurrentDrawingAppearance { resolved = token.usingColorSpace(.sRGB) ?? token }
            return resolved
        })
        revisions[name] = (revision, color)
        return color
    }
}

/// Selection capsule colours. Text stays `labelColor`: no white-on-accent anywhere.
struct CapsuleStyle: Equatable {
    let fill: NSColor
    /// Increase Contrast adds a 1 pt accent outline to the focused capsule.
    let stroke: NSColor?
    /// Icons and count suffixes tint to the accent on a focused capsule.
    let tintsAccessories: Bool

    static func fill(isKey: Bool, isFocused: Bool, contrast: Bool) -> CapsuleStyle {
        guard isKey && isFocused else { return CapsuleStyle(fill: .silkwebSelectionInactive, stroke: nil, tintsAccessories: false) }
        return CapsuleStyle(fill: .silkwebSelection, stroke: contrast ? .silkwebAccent : nil, tintsAccessories: true)
    }
}

/// Cells that change accessory tints on a focused capsule.
@MainActor protocol CapsuleAccessories: AnyObject {
    var capsuleFocused: Bool { get set }
}

/// Draws the selection as a rounded capsule inset from the column edges.
class CapsuleRowView: NSTableRowView {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Cells keep `.normal` styling: dark ink on the light capsule.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    var style: CapsuleStyle {
        CapsuleStyle.fill(isKey: window?.isKeyWindow == true, isFocused: isEmphasized,
                          contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    /// The capsule in row coordinates: 10 pt from the table's edges, whatever the table style's row inset.
    var capsuleRect: NSRect {
        var rect = bounds
        if let table = superview as? NSTableView {
            let edges = convert(NSRect(x: Spacing.capsuleInset, y: 0, width: max(0, table.bounds.width - 2 * Spacing.capsuleInset), height: 1), from: table)
            rect.origin.x = max(bounds.minX, edges.minX)
            rect.size.width = max(0, min(bounds.maxX, edges.maxX) - rect.minX)
        }
        return rect.insetBy(dx: 0, dy: 1)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let style = style
        let path = NSBezierPath(roundedRect: capsuleRect, xRadius: cornerRadius, yRadius: cornerRadius)
        style.fill.setFill()
        path.fill()
        if let stroke = style.stroke {
            let outline = NSBezierPath(roundedRect: capsuleRect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            outline.lineWidth = 1
            stroke.setStroke()
            outline.stroke()
        }
    }

    override var isEmphasized: Bool { didSet { updateAccessories() } }
    override var isSelected: Bool { didSet { updateAccessories() } }
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        updateAccessories()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAccessories()
    }

    private func updateAccessories() {
        let focused = isSelected && style.tintsAccessories
        for case let cell as CapsuleAccessories in subviews where cell.capsuleFocused != focused {
            cell.capsuleFocused = focused
        }
        needsDisplay = true
    }
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
                Rectangle().fill(Color.silkwebHairline).frame(height: 1 / max(1, displayScale))
                    .accessibilityHidden(true)
            }
    }
}
