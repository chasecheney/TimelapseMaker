import SwiftUI

@main
struct TimelapseMakerApp: App {
    @StateObject private var model = ProjectModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
