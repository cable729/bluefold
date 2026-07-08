import SwiftUI

@main
struct PDFReaderApp: App {
    @State private var model = ReaderSessionModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ReaderView(model: model)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // iOS has no clean "will terminate" hook; background is the
            // reliable moment to flush the session (same session.json format
            // as macOS, single window).
            if newPhase == .background {
                model.save()
            }
        }
    }
}
