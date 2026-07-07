#if os(macOS)
import AppKit
import ReaderCore
import SwiftUI

/// Browser-style File menu: ⌘N window, ⌘T tab, ⌘W closes the tab (falling
/// back to the window when none), ⇧⌘W closes the window.
public struct ReaderCommands: Commands {
    @FocusedValue(\.readerWindowModel) private var model
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(id: "reader", value: UUID())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("New Tab…") {
                model?.openTabViaPanel()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(model == nil)
        }

        CommandGroup(after: .toolbar) {
            Picker("Theme", selection: Bindable(ThemeManager.shared).current) {
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
                Text("Sepia").tag(AppTheme.sepia)
            }
            .pickerStyle(.inline)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if model?.closeActiveTab() != true {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Close Window") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}
#endif
