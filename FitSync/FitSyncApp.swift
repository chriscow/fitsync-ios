import SwiftUI

@main
struct FitSyncApp: App {
    @State private var model = ImportModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // Called when another app shares / "Opens in" a .fit file with FitSync.
                .onOpenURL { url in model.load(url: url) }
        }
    }
}
