import Foundation

/// The library path (silkweb-1.65; in the status bar since #91): library › folders › document, or the list scope
/// with no document open.
public struct Breadcrumb: Equatable, Sendable {
    public struct Crumb: Equatable, Sendable {
        public let title: String
        /// The folder scope the crumb selects; nil for a label that is not a folder (“Tags”).
        public let folderPath: String?

        public init(title: String, folderPath: String?) {
            self.title = title
            self.folderPath = folderPath
        }
    }

    /// Ancestors, root first.
    public let crumbs: [Crumb]
    /// The document, or the current scope when no document is open. Never a link.
    public let current: String

    public init(crumbs: [Crumb], current: String) {
        self.crumbs = crumbs
        self.current = current
    }

    public static let separator = " › "

    /// A document's real folder wins over the list scope. `folder` is nil for All Documents and "" for the root.
    public static func make(
        libraryName: String, documentPath: String?, documentTitle: String,
        folder: String?, tagName: String?
    ) -> Breadcrumb {
        func ancestors(of path: String) -> [Crumb] {
            var crumbs = [Crumb(title: libraryName, folderPath: "")]
            var prefix = ""
            for component in path.split(separator: "/") {
                prefix += (prefix.isEmpty ? "" : "/") + component
                crumbs.append(Crumb(title: String(component), folderPath: prefix))
            }
            return crumbs
        }
        if let documentPath {
            return Breadcrumb(
                crumbs: ancestors(of: (documentPath as NSString).deletingLastPathComponent), current: documentTitle)
        }
        if let tagName { return Breadcrumb(crumbs: [Crumb(title: "Tags", folderPath: nil)], current: tagName) }
        guard let folder else { return Breadcrumb(crumbs: [], current: "All Documents") }
        guard !folder.isEmpty else { return Breadcrumb(crumbs: [], current: libraryName) }
        var crumbs = ancestors(of: folder)
        let last = crumbs.removeLast()
        return Breadcrumb(crumbs: crumbs, current: last.title)
    }

    /// The full path for VoiceOver, so truncation hides nothing.
    public var accessibilityValue: String { (crumbs.map(\.title) + [current]).joined(separator: Self.separator) }

    /// Widths in points, measured by the caller; each crumb width includes its own padding.
    public struct Metrics: Equatable, Sendable {
        public var separator: Double
        public var ellipsis: Double
        public var crumbCap: Double = 140
        public var currentMinimum: Double = 80

        public init(separator: Double, ellipsis: Double, crumbCap: Double = 140, currentMinimum: Double = 80) {
            self.separator = separator
            self.ellipsis = ellipsis
            self.crumbCap = crumbCap
            self.currentMinimum = currentMinimum
        }
    }

    /// How the path is drawn in the available width.
    public struct Fit: Equatable, Sendable {
        /// Crumb indices folded into the `…` menu: empty, or a contiguous run ending before the nearest visible ancestor.
        public var collapsed: Range<Int>
        /// One width per crumb; collapsed entries are unused.
        public var crumbWidths: [Double]
        public var currentWidth: Double
        public var width: Double
    }

    /// The truncation ladder, applied in order until the path fits:
    /// 1. cap each folder crumb; 2. fold ancestors after the root into `…`, nearest the root first; 3. fold the root
    /// too; 4. middle-truncate the last crumb down to its minimum. The last crumb is never dropped.
    public static func fit(crumbs: [Double], current: Double, available: Double, metrics: Metrics) -> Fit {
        func width(_ fit: Fit) -> Double {
            let visible = crumbs.indices.filter { !fit.collapsed.contains($0) }
            let items = visible.count + (fit.collapsed.isEmpty ? 0 : 1)
            return visible.reduce(0) { $0 + fit.crumbWidths[$1] } + (fit.collapsed.isEmpty ? 0 : metrics.ellipsis)
                + Double(items) * metrics.separator + fit.currentWidth
        }
        func measured(_ fit: Fit) -> Fit { var fit = fit; fit.width = width(fit); return fit }
        var fit = measured(Fit(collapsed: 0..<0, crumbWidths: crumbs, currentWidth: current, width: 0))
        if fit.width <= available { return fit }
        fit.crumbWidths = crumbs.map { min($0, metrics.crumbCap) }
        fit = measured(fit)
        if fit.width <= available { return fit }
        if crumbs.count > 1 {
            for end in 2...crumbs.count {
                fit.collapsed = 1..<end
                fit = measured(fit)
                if fit.width <= available { return fit }
            }
        }
        if !crumbs.isEmpty {
            fit.collapsed = 0..<crumbs.count
            fit = measured(fit)
            if fit.width <= available { return fit }
        }
        fit.currentWidth = max(min(current, metrics.currentMinimum), current - (fit.width - available))
        return measured(fit)
    }
}
