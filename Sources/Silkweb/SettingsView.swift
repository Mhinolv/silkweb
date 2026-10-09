import AppKit
import SilkwebCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case editor, preview, appearance, library
}

/// Silkweb ▸ Settings… (silkweb-1.24). Every control applies live; there is no OK or Apply.
struct SettingsView: View {
    @Bindable var settings: WritingSettings
    let workspace: LibraryWorkspace
    @State var tab: SettingsTab = .editor
    /// Runs before Choose Library… so the chosen Library has a window to show in (#194).
    var showWindow: () -> Void = {}

    var body: some View {
        TabView(selection: $tab) {
            EditorSettingsTab(settings: settings)
                .tabItem { Label("Editor", systemImage: "textformat") }.tag(SettingsTab.editor)
            PreviewSettingsTab(settings: settings)
                .tabItem { Label("Preview", systemImage: "eye") }.tag(SettingsTab.preview)
            AppearanceSettingsTab(settings: settings)
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }.tag(SettingsTab.appearance)
            LibrarySettingsTab(workspace: workspace, showWindow: showWindow)
                .tabItem { Label("Library", systemImage: "books.vertical") }.tag(SettingsTab.library)
        }
        .frame(width: 520)
        .background(Color.silkwebPaneBackground.ignoresSafeArea())
    }
}

/// A grouped form sized to its content, on the pane surface.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Trailing `.bordered` Restore Defaults in a section footer.
private struct RestoreFooter: View {
    let title: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button(title, action: action).buttonStyle(.bordered).disabled(disabled)
        }
    }
}

// MARK: Slider + field

/// Label, slider (min 180 pt) and a 56 pt field with a unit suffix. Typed values clamp on Return or focus
/// loss; ↑/↓ in the field step by one increment.
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    var spokenUnit = "points"

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 180)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(Self.format(value)) \(spokenUnit)")
                HStack(spacing: 2) {
                    TextField(title, text: $text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focused)
                        .onSubmit(commit)
                        .onKeyPress(.upArrow) {
                            nudge(1); return .handled
                        }
                        .onKeyPress(.downArrow) {
                            nudge(-1); return .handled
                        }
                    Text(unit).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .frame(width: 56)
            }
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { text = Self.format(value) }
        .onChange(of: focused) { if !focused { commit() } }
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    /// Out-of-range input snaps to the bound, with no alert; unreadable input restores the value.
    func commit() {
        guard let typed = Double(text.trimmingCharacters(in: .whitespaces)), typed.isFinite else {
            text = Self.format(value); return
        }
        let snapped = (typed / step).rounded() * step
        value = min(max(snapped, range.lowerBound), range.upperBound)
        text = Self.format(value)
    }

    private func nudge(_ direction: Double) {
        value = min(max(value + direction * step, range.lowerBound), range.upperBound)
    }
}

// MARK: Editor

struct EditorSettingsTab: View {
    @Bindable var settings: WritingSettings
    private static let customTag = "\u{0}custom"

    private var fontBinding: Binding<String> {
        Binding(
            get: { settings.preferences.fontFamily },
            set: { family in
                if family == Self.customTag {
                    FontPanelBridge.shared.show(family: settings.preferences.fontFamily) {
                        settings.preferences.fontFamily = $0
                    }
                } else {
                    settings.preferences.fontFamily = family
                }
            })
    }

    private var lineSpacingIndex: Binding<Double> {
        Binding(
            get: { Double(WritingPreferences.lineHeights.firstIndex(of: settings.preferences.lineHeight) ?? 2) },
            set: { settings.preferences.lineHeight = WritingPreferences.lineHeights[min(4, max(0, Int($0.rounded())))] }
        )
    }

    var body: some View {
        SettingsForm {
            Section("Font") {
                Picker("Font", selection: fontBinding) {
                    Text("Menlo").tag("Menlo")
                    Text("Monospaced (SF Mono)").tag("Monospaced")
                    Text("System").tag("System")
                    Text("Serif (New York)").tag("Serif")
                    let family = settings.preferences.fontFamily
                    if !WritingPreferences.builtInFonts.contains(family) {
                        Text(family).tag(family)
                    }
                    Divider()
                    Text("Custom…").tag(Self.customTag)
                }
                SettingsSliderRow(
                    title: "Size", value: $settings.preferences.fontSize,
                    range: WritingPreferences.fontSizes, step: 1, unit: "pt")
                LabeledContent("Line spacing") {
                    HStack(spacing: 8) {
                        Slider(value: lineSpacingIndex, in: 0...4, step: 1)
                            .frame(minWidth: 180)
                            .accessibilityLabel("Line spacing")
                            .accessibilityValue("\(SettingsSliderRow.format(settings.preferences.lineHeight)) times")
                        Text(SettingsSliderRow.format(settings.preferences.lineHeight) + "×")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
            }
            Section {
                SettingsSliderRow(
                    title: "Text insets", value: $settings.preferences.horizontalInset,
                    range: WritingPreferences.horizontalInsets, step: 4, unit: "pt")
                SettingsSliderRow(
                    title: "Line width", value: $settings.preferences.maximumWidth,
                    range: WritingPreferences.maximumWidths, step: 20, unit: "pt")
            } header: {
                Text("Layout")
            } footer: {
                Text("Text stays centred and wraps at this width when the window is wider.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Sample") {
                EditorSample().frame(height: 84)
            }
            Section {
                Picker("Indent with", selection: $settings.preferences.indent) {
                    ForEach(WritingPreferences.Indent.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Check spelling while typing", isOn: $settings.preferences.checksSpelling)
                Toggle("Use smart quotes and dashes", isOn: $settings.preferences.smartPunctuation)
                Toggle("Show images inline in the editor", isOn: $settings.preferences.showsInlineImages)
                Toggle("Highlight the current line", isOn: $settings.preferences.highlightsCurrentLine)
                Toggle("Reopen windows and tabs from the last session", isOn: $settings.preferences.reopensSession)
            } header: {
                Text("Behaviour")
            } footer: {
                RestoreFooter(title: "Restore Defaults", disabled: settings.preferences.editorIsDefault) {
                    settings.preferences.restoreEditorDefaults()
                }
            }
        }
    }
}

/// A non-editable production editor showing the current font, size, spacing and colours.
struct EditorSample: NSViewRepresentable {
    static let text = "## A heading\nBody with **bold** and `code`."

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle(topInset: 8))
        scroll.hasVerticalScroller = false
        let editor = scroll.documentView as! PlainMarkdownTextView
        editor.string = Self.text
        editor.isEditable = false
        editor.isSelectable = false
        editor.styler.reload()
        editor.setAccessibilityLabel("Editor sample text")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}

/// Routes `NSFontPanel` choices to the Settings font popup.
@MainActor final class FontPanelBridge: NSObject {
    static let shared = FontPanelBridge()
    private var choose: ((String) -> Void)?

    func show(family: String, choose: @escaping (String) -> Void) {
        self.choose = choose
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(EditorStyle.font(family: family, size: 15), isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        let font = manager.convert(EditorStyle.font(family: LivePreferences.shared.current.fontFamily, size: 15))
        if let family = font.familyName { choose?(family) }
    }
}

// MARK: Preview

struct PreviewSettingsTab: View {
    @Bindable var settings: WritingSettings

    var body: some View {
        SettingsForm {
            Section("Text") {
                Picker("Font", selection: $settings.preferences.previewFont) {
                    ForEach(WritingPreferences.PreviewFont.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsSliderRow(
                    title: "Size", value: $settings.preferences.previewFontSize,
                    range: WritingPreferences.previewFontSizes, step: 1, unit: "pt")
            }
            Section {
                Picker("Line breaks", selection: $settings.preferences.keepsLineBreaks) {
                    Text("Join lines into paragraphs (standard Markdown)").tag(false)
                    Text("Keep every line break").tag(true)
                }
                .pickerStyle(.radioGroup)
                Toggle("Show a table of contents for [TOC]", isOn: $settings.preferences.showsTableOfContents)
            } header: {
                Text("Rendering")
            } footer: {
                RestoreFooter(title: "Restore Defaults", disabled: settings.preferences.previewIsDefault) {
                    settings.preferences.restorePreviewDefaults()
                }
            }
        }
    }
}

// MARK: Appearance

struct AppearanceSettingsTab: View {
    @Bindable var settings: WritingSettings

    static let rows: [(slot: ColorSlot, title: String, caption: String)] = [
        (.surface, "Surface", "Background of every pane"),
        (.text, "Text", "Body text in the editor and preview"),
        (.headings, "Headings", "Editor and preview headings"),
        (.accent, "Accent", "Links, selection and tags"),
        (.coral, "Unsaved dot", "Dot on tabs with unsaved changes"),
    ]

    private var setName: String { settings.editingDark ? "Dark" : "Light" }

    var body: some View {
        SettingsForm {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.preferences.appearance) {
                    ForEach(WritingPreferences.AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                ForEach(Self.rows, id: \.slot) { row in
                    ColorSlotRow(settings: settings, slot: row.slot, title: row.title, caption: row.caption)
                }
                ColorPreviewCard(colors: settings.editedColors, dark: settings.editingDark)
                if let warning = settings.editedColors.contrastWarning(dark: settings.editingDark) {
                    ContrastWarningView(warning: warning)
                }
            } header: {
                HStack {
                    Text("Colours")
                    Spacer()
                    Picker("Colour set", selection: $settings.editingDark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            } footer: {
                RestoreFooter(title: "Restore \(setName) Defaults", disabled: settings.editedColors.isDefault) {
                    settings.restoreEditedColors()
                }
            }
        }
    }
}

extension HexColor {
    var nsColor: NSColor { SilkwebTokens.srgb(rgb) }

    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        self.init(channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent))
    }
}

struct ColorSlotRow: View {
    @Bindable var settings: WritingSettings
    let slot: ColorSlot
    let title: String
    let caption: String

    private var color: Binding<Color> {
        Binding(
            get: { Color(nsColor: settings.editedColors.resolved(slot, dark: settings.editingDark).nsColor) },
            set: { value in
                guard let rgb = HexColor(NSColor(value)), rgb != settings.editedColors[slot] else { return }
                settings.editedColors[slot] = rgb
            })
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if settings.editedColors[slot] != nil {
                    Button {
                        settings.editedColors[slot] = nil
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset \(title)")
                    .accessibilityLabel("Reset \(title)")
                }
                ColorPicker(title, selection: color, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(title)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ContrastWarningView: View {
    let warning: ColorSet.ContrastWarning

    var body: some View {
        Label {
            Text(warning.message).font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
        }
        .onAppear { announce() }
        .onChange(of: warning) { announce() }
    }

    private func announce() {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: warning.message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

/// A miniature sidebar and editor drawn in the set being edited, whatever the app's appearance.
struct ColorPreviewCard: View {
    let colors: ColorSet
    let dark: Bool

    private func color(_ slot: ColorSlot) -> Color { Color(nsColor: colors.resolved(slot, dark: dark).nsColor) }
    private var hairline: Color { Color(nsColor: colors.hairline(dark: dark).nsColor) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Writing").padding(.horizontal, 8).padding(.vertical, 3)
                Text("Drafts")
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: colors.selection(dark: dark).nsColor)))
                Text("Archive").padding(.horizontal, 8).padding(.vertical, 3)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color(.text))
            .padding(8)
            .frame(width: 140)
            Rectangle().fill(hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                // The unsaved dot, as on an edited tab (1.65).
                HStack(spacing: 6) {
                    Text("Edited").foregroundStyle(color(.text))
                    Circle().fill(color(.coral)).frame(width: 6, height: 6)
                }
                Text("A heading").bold().foregroundStyle(color(.headings))
                Text("Body text on the surface.").foregroundStyle(color(.text))
                Text("A link in the accent").underline().foregroundStyle(color(.accent))
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .frame(height: 120)
        .background(color(.surface))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hairline, lineWidth: 1))
        .environment(\.colorScheme, dark ? .dark : .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour preview, \(dark ? "Dark" : "Light") set")
    }
}

// MARK: Library

struct LibrarySettingsTab: View {
    let workspace: LibraryWorkspace
    var showWindow: () -> Void = {}

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Location") {
                    LibraryPathControl(url: workspace.root)
                }
                HStack {
                    Spacer()
                    Button("Reveal in Finder") {
                        if let root = workspace.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    }
                    .disabled(workspace.root == nil)
                    Button("Choose Library…") {
                        showWindow(); workspace.chooseFolder(replacing: true)
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text(
                    "Your library is an ordinary folder of Markdown files. Back it up like any other folder, for example with Time Machine. To move it, quit Silkweb, move the folder in Finder, then choose it here. Silkweb's index files travel with the folder."
                )
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Standard path control, not editable; double-click reveals the folder in Finder.
struct LibraryPathControl: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.isEditable = false
        control.target = context.coordinator
        control.doubleAction = #selector(Coordinator.reveal(_:))
        control.setAccessibilityLabel("Library location")
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSPathControl, context: Context) {
        if control.url != url { control.url = url }
        control.placeholderString = url == nil ? "No library open" : nil
    }

    @MainActor final class Coordinator: NSObject {
        @objc func reveal(_ sender: NSPathControl) {
            if let url = sender.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
