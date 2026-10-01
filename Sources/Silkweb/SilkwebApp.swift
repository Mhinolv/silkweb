import SwiftUI
import SilkwebCore

@main
struct SilkwebApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Silkweb \(SilkwebCore.version)")
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
