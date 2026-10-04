import SwiftUI

struct MediaMigrationBanner: View {
    let workspace: LibraryWorkspace
    @State private var showingDetails = false

    var body: some View {
        if workspace.mediaBannerVisible {
            HStack(spacing: 8) {
                Image(systemName: workspace.mediaFailures.isEmpty ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(workspace.mediaFailures.isEmpty ? Color.secondary : Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.mediaFailures.isEmpty
                         ? "Moving images to the “\(workspace.mediaDirectoryName)” folder…"
                         : "Some images couldn’t be moved to the “\(workspace.mediaDirectoryName)” folder.")
                    if !workspace.mediaFailures.isEmpty {
                        Text("Their links still work. Silkweb will try again next time this library opens.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if workspace.mediaFailures.isEmpty {
                    if let progress = workspace.mediaProgress {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                            .frame(width: 120).accessibilityLabel("Moving images")
                    }
                } else {
                    Button("Details") { showingDetails = true }
                        .popover(isPresented: $showingDetails) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(workspace.mediaFailures.enumerated()), id: \.offset) { _, failure in
                                        Text("\(failure.name) — \(failure.reason)").textSelection(.enabled)
                                    }
                                }.padding()
                            }.frame(width: 360, height: 200)
                        }
                    Button("Try Again") { workspace.retryMediaMigration() }
                    Button { workspace.mediaBannerVisible = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss message").help("Dismiss message")
                }
            }
            .font(.callout).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 36).paneStrip(hairline: .bottom)
        }
    }
}

/// Shares the media strip's slot: a recovery file couldn't be read and was set aside (1.70).
struct UnreadableRecoveryBanner: View {
    static let message = "A recovery file couldn’t be read and was set aside."
    let workspace: LibraryWorkspace

    var body: some View {
        if let file = workspace.unreadableRecoveryFile {
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(Self.message)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Button { workspace.unreadableRecoveryFile = nil } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss message").help("Dismiss message")
            }
            .font(.callout).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 36).paneStrip(hairline: .bottom)
        }
    }
}
