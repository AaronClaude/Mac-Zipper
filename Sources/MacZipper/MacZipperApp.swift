import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        configureMainWindow()

        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs.removeAll()
            onOpenURLs?(urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let onOpenURLs {
            onOpenURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func configureMainWindow() {
        for window in NSApp.windows {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

@main
struct MacZipperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ExtractorViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        viewModel.handleIncomingURLs(urls)
                    }
                    appDelegate.configureMainWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Archive…") {
                    viewModel.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
