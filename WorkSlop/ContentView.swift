import SwiftUI

/// App root: one menu, one gear. Shared state lives here and is
/// passed down through the environment — rows never own storage.
struct ContentView: View {
    let demoScreen: String?
    @StateObject private var selection = SelectionStore()
    @StateObject private var status = StatusStore()
    @StateObject private var updater = UpdateChecker()

    init(demoScreen: String? = nil) {
        self.demoScreen = demoScreen
    }

    var body: some View {
        MainMenuView(demoScreen: demoScreen)
            .environmentObject(selection)
            .environmentObject(status)
            .task {
                await updater.check()
            }
            .alert(item: $updater.available) { update in
                Alert(
                    title: Text("New update available"),
                    message: Text("WorkSlop \(update.version) is out. You're on \(UpdateChecker.currentVersion).\n\n\(update.notes)"),
                    primaryButton: .default(Text("View release")) {
                        UIApplication.shared.open(update.url)
                    },
                    secondaryButton: .cancel(Text("Later"))
                )
            }
    }
}
