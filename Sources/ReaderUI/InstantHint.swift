#if os(macOS)
import SwiftUI

/// A fast hover hint: a small bubble above the control after a short delay.
///
/// AppKit's `.help()` tooltips take well over a second to appear, which makes
/// discovering icon-only controls feel sluggish. `.instantHint("…")` shows a
/// subtle material bubble after ~0.15s of hover instead. It renders as an
/// overlay (no extra window), never intercepts clicks, and hides the moment
/// the pointer leaves.
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
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if isShowing {
                    bubble
                }
            }
    }

    private var bubble: some View {
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
            // Float just outside the hovered control, on the requested edge.
            .alignmentGuide(edge == .top ? .top : .bottom) { d in
                edge == .top ? d[.bottom] + 4 : d[.top] - 4
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .zIndex(1)
    }
}
#endif
