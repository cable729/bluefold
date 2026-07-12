#if os(macOS)
import AppKit
import ReaderCore
import SwiftUI

/// The app's menu bar, rendered from `CommandRegistry` — the same table that
/// drives the command palette and the help overlay, so the three can never
/// drift. Menu *placement* (which menu, dividers) is decided here; everything
/// else (titles, shortcuts, availability, behavior) comes from the table.
public struct ReaderCommands: Commands {
    @FocusedValue(\.readerWindowModel) private var model
    @FocusedValue(\.readerWindowUI) private var ui
    @Environment(\.openWindow) private var openWindow

    public init() {}

    private var context: CommandContext {
        CommandContext(
            model: model,
            ui: ui,
            session: SessionCoordinator.shared,
            openReaderWindow: { openWindow(id: "reader", value: UUID()) },
            openLibraryWindow: { openWindow(id: "library") },
            presentReaderWindow: { openWindow(id: "reader", value: $0) }
        )
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            items(["file.newWindow", "file.newTab", "file.openFile", "file.openLibrary"])
        }

        CommandGroup(replacing: .saveItem) {
            items(["file.closeTab", "file.closeWindow", "tabs.reopenClosed"])
        }

        // Frees ⌘P for the navigate palette (VS Code quick-open convention).
        // The app has no print UI; see docs/KEYBINDINGS.md.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(after: .pasteboard) {
            items(["search.find", "search.allBooks", "bookmarks.add"])
            Divider()
            items(["links.copyToHere", "links.copyToSelection"])
        }

        CommandMenu("Go") {
            items(["nav.back", "nav.forward"])
            Divider()
            items(["nav.previousPage", "nav.nextPage",
                   "nav.previousSection", "nav.nextSection", "nav.goToPage"])
            Divider()
            items(["nav.openAnything", "nav.goToSection"])
        }

        CommandGroup(after: .toolbar) {
            items(["view.toggleSidebar"])
            Divider()
            items([
                "view.layout.singlePage", "view.layout.continuous",
                "view.layout.twoUp", "view.layout.twoUpContinuous",
            ])
            Divider()
            items(["view.fitWidth", "view.fitHeight"])
            Divider()
            items(["view.splitRight", "view.splitLeft", "view.splitDown",
                   "view.splitOrientationToggle", "view.closeSplit"])
            Divider()
            prefixedItems("view.theme.")
        }

        CommandGroup(before: .windowList) {
            items(["tabs.next", "tabs.previous", "tabs.duplicate", "tabs.closeOthers"])
            Divider()
        }

        CommandGroup(replacing: .help) {
            items(["help.commandPalette", "help.shortcuts"])
            Divider()
            items(["prefs.openKeybindings"])
        }
    }

    private func items(_ ids: [String]) -> some View {
        render(CommandRegistry.commands(ids: ids))
    }

    private func prefixedItems(_ prefix: String) -> some View {
        render(CommandRegistry.commands(idPrefix: prefix))
    }

    private func render(_ commands: [ReaderCommand]) -> some View {
        let context = self.context
        return ForEach(commands) { command in
            CommandMenuItem(command: command, context: context)
        }
    }
}

/// One menu item projected from a `ReaderCommand`: a checkmark toggle for
/// stateful commands, a plain button otherwise.
private struct CommandMenuItem: View {
    let command: ReaderCommand
    let context: CommandContext

    var body: some View {
        Group {
            if let isOn = command.isOn {
                Toggle(
                    command.title,
                    isOn: Binding(
                        get: { isOn(context) },
                        set: { _ in command.run(context) }
                    )
                )
            } else {
                Button(command.title) {
                    command.run(context)
                }
            }
        }
        .keyboardShortcut(command.menuShortcut)
        .disabled(!command.isAvailable(context))
    }
}
#endif
