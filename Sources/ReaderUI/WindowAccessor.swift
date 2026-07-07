#if os(macOS)
import AppKit
import SwiftUI

/// Grabs the hosting NSWindow to apply reader-window policy:
///
/// - `.moveToActiveSpace`: new windows open in the user's CURRENT Space
///   instead of yanking them to wherever another app window lives.
/// - Native window tabbing off (the app draws its own tab strip).
/// - System state restoration off (session restore is ours).
/// - Restores the persisted frame once, then persists frame changes.
/// - Reports window close to the session coordinator.
struct WindowAccessor: NSViewRepresentable {
    unowned let model: ReaderWindowModel

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.model = model
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {}

    @MainActor
    final class TrackingView: NSView {
        weak var model: ReaderWindowModel?
        private var configuredWindow: NSWindow?
        // nonisolated(unsafe): mutated only on main; read in deinit.
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configuredWindow else { return }
            configuredWindow = window
            configure(window)
        }

        private func configure(_ window: NSWindow) {
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.tabbingMode = .disallowed
            window.isRestorable = false

            if let frame = model?.consumePendingFrame() {
                window.setFrame(frame, display: true)
            } else if let model, model.windowFrame == nil {
                model.setWindowFrame(window.frame)
            }

            removeObservers()
            let center = NotificationCenter.default
            let record: (Notification) -> Void = { [weak self] notification in
                nonisolated(unsafe) let notification = notification
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow else { return }
                    self?.model?.setWindowFrame(window.frame)
                }
            }
            observers.append(center.addObserver(
                forName: NSWindow.didMoveNotification, object: window, queue: .main, using: record
            ))
            observers.append(center.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main, using: record
            ))
            observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self?.model else { return }
                    SessionCoordinator.shared.windowClosed(model.windowID)
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let model = self?.model else { return }
                    SessionCoordinator.shared.noteWindowFocused(model.windowID)
                }
            })
        }

        private func removeObservers() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
#endif
