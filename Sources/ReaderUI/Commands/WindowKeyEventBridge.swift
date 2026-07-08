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
        /// to menus and the responder chain.
        private func handle(_ event: NSEvent, in window: NSWindow) -> NSEvent? {
            guard let model, let ui else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // ⌃Tab / ⌃⇧Tab — tab cycling. keyCode 48 = Tab.
            if event.keyCode == 48 {
                if modifiers == .control {
                    model.selectNextTab()
                    return nil
                }
                if modifiers == [.control, .shift] {
                    model.selectPreviousTab()
                    return nil
                }
            }

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

            // ⌘1…⌘9 — direct tab selection (browser-style; 9 = last).
            // A menu binding would be nine items of clutter.
            if modifiers == .command,
               let characters = event.charactersIgnoringModifiers,
               characters.count == 1, let digit = Int(characters), (1...9).contains(digit) {
                model.selectTab(number: digit)
                return nil
            }

            // ⌘⇧O — in-book palette alias (VS Code go-to-symbol); ⌘O and
            // ⌘P are menu-owned. Releasing first responder first is what
            // lets the palette's query field take focus (the AppKit
            // PDFView won't yield it for monitor-dispatched presentations).
            if modifiers == [.command, .shift],
               event.charactersIgnoringModifiers?.lowercased() == "o" {
                window.makeFirstResponder(nil)
                ui.presentPalette(.outline)
                return nil
            }

            // "/" or "?" — help overlay. Never while typing (search fields,
            // palette query, page-number field) so the keys still insert.
            if modifiers.subtracting(.shift).isEmpty,
               let characters = event.charactersIgnoringModifiers,
               characters == "/" || characters == "?" {
                if ui.showHelp {
                    ui.showHelp = false
                    model.focusActivePDFView()
                    return nil
                }
                if ui.palette == nil, !isEditingText(in: window) {
                    ui.showHelp = true
                    return nil
                }
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
