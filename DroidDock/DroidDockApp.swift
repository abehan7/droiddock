import SwiftUI
import AppKit

@main
struct DroidDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BrowserModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    appDelegate.model = model
                    model.startWatchingUSB()
                    await model.connect()
                }
        }
        .defaultSize(width: 1120, height: 700)
        .commands { DroidDockCommands(model: model) }
    }
}

/// Finder's shortcuts: ⌘1–4 views, ⌘[ ⌘] history, ⌘↑ enclosing folder, ⇧⌘N, ⌘I, ⌘⌫.
struct DroidDockCommands: Commands {
    let model: BrowserModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { model.requestNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canModifyHere)
        }
        CommandGroup(after: .newItem) {
            if BrowserModel.wifiEnabled {
                Button("Connect over Wi-Fi…") { model.isShowingWiFi = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
            Button("Connect with USB") { Task { await model.connect() } }
            Divider()
            Button("Get Info") { model.showInfo(model.selection) }
                .keyboardShortcut("i")
                .disabled(model.selection.isEmpty)
            Button("Delete…") { model.requestDelete(model.selection) }
                .keyboardShortcut(.delete)
                .disabled(model.selection.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            ForEach(ViewMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(
                    get: { model.viewMode == mode },
                    set: { if $0 { model.viewMode = mode } }))
                    .keyboardShortcut(KeyEquivalent(mode.shortcut))
            }
            Divider()
            Button("Refresh") { Task { await model.reload() } }
                .keyboardShortcut("r")
                .disabled(!model.isConnected)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { Task { await model.goBack() } }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { Task { await model.goForward() } }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Button("Enclosing Folder") { Task { await model.goUp() } }
                .keyboardShortcut(.upArrow)
                .disabled(model.path.isEmpty)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: BrowserModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.engine.shutdown() }   // release the phone so the next app can claim it
    }
}
