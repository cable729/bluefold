#if os(macOS)
import AppKit
import SwiftUI

/// A fast hover hint: a small bubble above the control after a short delay.
///
/// AppKit's `.help()` tooltips take too long to appear (even with
/// NSInitialToolTipDelay lowered they can lag). `.instantHint("…")` shows a
/// bubble after ~0.15s of hover and hides the moment the pointer leaves.
///
/// The bubble renders in its own borderless child WINDOW, not an overlay —
/// overlays get clipped by scroll views, sidebars, and window edges
/// (round 12: hints were cut off mid-word all over the app).
///
/// Keep `.help()` alongside it where the duplicate late tooltip is harmless —
/// `.help` also feeds VoiceOver, which this purely visual hint does not.
extension View {
    func instantHint(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(InstantHintModifier(text: text, edge: edge))
    }
}

struct InstantHintModifier: ViewModifier {
    let text: String
    var edge: VerticalEdge = .top
    /// Delay before the hint appears; long enough to not flicker while the
    /// pointer crosses the bar, short enough to feel immediate.
    var delay: Duration = .milliseconds(150)

    @State private var isShowing = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled else { return }
                        isShowing = true
                    }
                } else {
                    hoverTask = nil
                    isShowing = false
                }
            }
            .background(
                HintWindowPresenter(text: text, edge: edge, isShowing: isShowing)
            )
    }
}

/// The bubble content (unchanged look from the old overlay version).
private struct HintBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .fixedSize()
    }
}

/// Zero-size anchor that positions a floating panel next to the hovered
/// control, in screen coordinates — immune to any clipping.
private struct HintWindowPresenter: NSViewRepresentable {
    let text: String
    let edge: VerticalEdge
    let isShowing: Bool

    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.setHint(text: text, edge: edge, visible: isShowing)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.setHint(text: "", edge: .top, visible: false)
    }

    @MainActor
    final class AnchorView: NSView {
        // nonisolated(unsafe): touched on main only; read in deinit.
        private nonisolated(unsafe) var panel: NSPanel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                dismissPanel()
            }
        }

        func setHint(text: String, edge: VerticalEdge, visible: Bool) {
            guard visible, let window, !text.isEmpty else {
                dismissPanel()
                return
            }
            let hostingView = NSHostingView(rootView: HintBubble(text: text))
            let size = hostingView.fittingSize
            // The representable is a .background, so our bounds == the
            // hovered control's bounds.
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let origin = CGPoint(
                x: anchor.midX - size.width / 2,
                y: edge == .top ? anchor.maxY + 4 : anchor.minY - size.height - 4
            )

            let panel = self.panel ?? Self.makePanel()
            self.panel = panel
            panel.contentView = hostingView
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
            if panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }

        private func dismissPanel() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }

        private static func makePanel() -> NSPanel {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.animationBehavior = .none
            return panel
        }

        deinit {
            if let panel {
                DispatchQueue.main.async {
                    panel.parent?.removeChildWindow(panel)
                    panel.orderOut(nil)
                }
            }
        }
    }
}
#endif
