import AppKit
import SwiftUI
import SilkwebCore

@MainActor @Observable
final class TableInsertForm {
    var columns: String
    var rows: String
    var alignment: TableAlignment
    init(options: TableOptions = .load()) {
        columns = String(options.columns); rows = String(options.rows); alignment = options.alignment
    }
    var options: TableOptions? {
        guard let columns = TableOptions.dimension(columns, within: 1...20),
              let rows = TableOptions.dimension(rows, within: 1...100) else { return nil }
        return TableOptions(columns: columns, rows: rows, alignment: alignment)
    }
    @discardableResult func commit(columns field: Bool) -> Bool {
        let input = field ? columns : rows
        guard let value = TableOptions.dimension(input, within: field ? 1...20 : 1...100) else { return false }
        if field { columns = String(value) } else { rows = String(value) }
        return Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) == value
    }
}

struct TableInsertSheet: View {
    @State private var form: TableInsertForm
    @FocusState private var focusedDimension: Bool?
    let cancel: () -> Void
    let insert: (TableOptions) -> Void
    init(form: TableInsertForm? = nil, cancel: @escaping () -> Void, insert: @escaping (TableOptions) -> Void) {
        _form = State(initialValue: form ?? TableInsertForm()); self.cancel = cancel; self.insert = insert
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Insert Table").font(.headline)
            Form {
                dimension("Columns", field: true, bounds: 1...20)
                dimension("Body rows", field: false, bounds: 1...100)
                Picker("Alignment", selection: $form.alignment) {
                    ForEach(TableAlignment.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityLabel("Alignment")
            }.formStyle(.grouped).frame(height: 180)
            // A source smaller than the box sits top-left: the ScrollView would otherwise center it,
            // so the content is at least as large as the visible box.
            GeometryReader { box in
                ScrollView([.horizontal, .vertical]) {
                    Text(MarkdownTable.source(options: form.options ?? TableOptions()))
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize()
                        .accessibilityIdentifier("tableSourcePreviewText")
                        .frame(minWidth: box.size.width, minHeight: box.size.height, alignment: .topLeading)
                }.defaultScrollAnchor(.topLeading)
            }.frame(height: 80).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Table source preview")
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Insert") {
                    if !form.commit(columns: true) { NSSound.beep() }
                    if !form.commit(columns: false) { NSSound.beep() }
                    if let options = form.options { insert(options) }
                }.keyboardShortcut(.defaultAction).disabled(form.options == nil)
            }
        }.padding(20).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .onChange(of: focusedDimension) { old, _ in
                if let old, !form.commit(columns: old) { NSSound.beep() }
            }
    }
    private func dimension(_ title: String, field: Bool, bounds: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, text: Binding(get: { field ? form.columns : form.rows }, set: { if field { form.columns = $0 } else { form.rows = $0 } }))
                .labelsHidden().frame(width: 48).focused($focusedDimension, equals: field)
                .onSubmit { if !form.commit(columns: field) { NSSound.beep() } }
            Stepper(title, value: Binding(get: {
                TableOptions.dimension(field ? form.columns : form.rows, within: bounds) ?? bounds.lowerBound
            }, set: { if field { form.columns = String($0) } else { form.rows = String($0) } }), in: bounds)
                .labelsHidden().accessibilityLabel(title)
        }
    }
}

extension PlainMarkdownTextView {
    @objc func showTableInsertSheet(_ sender: Any? = nil) {
        guard let window, window.firstResponder === self, isEditable, !hasMarkedText(), window.attachedSheet == nil else { return }
        let selection = selectedRange()
        let original = string
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: TableInsertSheet(cancel: { [weak self, weak window] in
            window?.endSheet(sheet)
            if let self { window?.makeFirstResponder(self) }
        }, insert: { [weak self, weak window] options in
            window?.endSheet(sheet)
            guard let self, self.string == original, self.isEditable else { return }
            options.save()
            self.insertTable(options, selection: selection)
            window?.makeFirstResponder(self)
        }))
        if let view = sheet.contentView { sheet.setContentSize(view.fittingSize) }
        window.beginSheet(sheet) { _ in sheet.contentViewController = nil }
    }
    func insertTable(_ options: TableOptions, selection: NSRange? = nil) {
        apply(MarkdownTable.insertion(text: string, selection: selection ?? selectedRange(), options: options), name: "Insert Table")
    }
}
