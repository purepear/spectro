import SwiftUI

@main
struct SpectroApp: App {
    @StateObject private var viewModel = SpectroViewModel()

    var body: some Scene {
        WindowGroup("Spectro") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio File...") {
                    viewModel.isImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
