#if os(macOS)
import AppKit
import SwiftUI

/// Window-scoped NSEvent keyDown monitor for the chords SwiftUI menu items
/// can't (or shouldn't) own:
///
/// - ⌃Tab / ⌃⇧Tab — tab cycling (SwiftUI `keyboardShortcut` cannot bind ⌃Tab
///   reliably; the system routes it before the menu sees it).
/// - ⌘O — navigate palette. A menu item already owns ⌘P; a second visible
///   item just for the alias would be clutter.
/// - "/" and "?" — help overlay, ONLY when no text field is being edited so
///   both characters still type normally in search fields and the palette.
/// - Esc — closes the palette/help overlay and returns focus to the PDF.
///
/// The monitor only touches events belonging to its own window and returns
/// everything else untouched, so multiple reader windows never fight.
struct WindowKeyEventBridge: NSViewRepresentable {
    unowned let model: ReaderWindowModel
    let ui: ReaderWindowUIState

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.model = model
        view.ui = ui
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.model = model
        view.ui = ui
    }

    @MainActor
    final class MonitorView: NSView {
        weak var model: ReaderWindowModel?
        var ui: ReaderWindowUIState?
        // nonisolated(unsafe): written on main; read in deinit.
        private nonisolated(unsafe) var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Registers the host window for cross-window tab focus (palette).
            model?.hostWindow = window
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    let self,
                    let window = self.window,
                    event.window === window
                else { return event }
                return self.handle(event, in: window)
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        /// Returns nil to consume the event, or the event to let it continue
        /// to menus and the responder chain. Chord lookup is table-driven
        /// (`CommandRegistry.monitorCommand`) so keybindings.json overrides
        /// of monitor-owned chords (⌘1–9, ⌃Tab, aliases, "/") apply here
        /// exactly like they do in the menus.
        private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard let model, let ui else { return event }

            // Esc — dismiss overlays (backstop; runs before SwiftUI focus
            // handling, so the PDF regains key focus deterministically).
            if event.keyCode == 53 {
                if ui.showHelp {
                    ui.showHelp = false
                    model.focusActivePDFView()
                    return nil
                }
                if ui.palette != nil {
                    ui.dismissPalette()
                    model.focusActivePDFView()
                    return nil
                }
                return event
            }

            let candidates = KeyChord.candidates(for: event)
            guard !candidates.isEmpty else { return event }
            let editingText = isEditingText(in: window)

            // Help overlay — toggles, and never fires while typing (search
            // fields, palette query, page-number field) so its keys ("/"
            // and "?" by default) still insert.
            if let help = CommandRegistry.command(id: "help.shortcuts"),
               help.chords.contains(where: candidates.contains) {
                if ui.showHelp {
                    ui.showHelp = false
                    model.focusActivePDFView()
                    return nil
                }
                if ui.palette == nil, !editingText {
                    ui.showHelp = true
                    return nil
                }
                return event
            }

            // Every other chord the menus don't install: ⌘1…⌘9 tab
            // selection, ⌃Tab/⌃⇧Tab cycling, the ⌘⇧O palette alias, and
            // whatever keybindings.json rebinds onto monitor-owned commands.
            let context = CommandContext(model: model, ui: ui, session: .shared)
            if let command = CommandRegistry.monitorCommand(
                matching: candidates, isEditingText: editingText
            ), command.isAvailable(context) {
                // Release the first responder before running: palette
                // presentations need it or the AppKit PDFView won't yield
                // key focus to the query field.
                window.makeFirstResponder(nil)
                command.run(context)
                return nil
            }

            return event
        }

        /// True while a text field is being edited (the field editor — an
        /// NSTextView — or any NSText is first responder).
        private func isEditingText(in window: NSWindow) -> Bool {
            window.firstResponder is NSText
        }
    }
}

extension ReaderWindowModel {
    /// Returns key focus to the live PDF view (after a palette or the help
    /// overlay closes) so arrow-key paging works without an extra click.
    func focusActivePDFView() {
        guard
            let hostWindow,
            let coordinator = activeController as? ActivePDFView.Coordinator,
            let view = coordinator.view
        else { return }
        hostWindow.makeFirstResponder(view)
    }
}
#endif
