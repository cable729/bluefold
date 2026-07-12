import ReaderCore
import ReaderUI
import SwiftUI

/// Top chrome band: sidebar toggle + history arrows on the left (macOS
/// toolbar order), find / split / library / open on the right. The
/// back/forward buttons are tap-to-go, long-press for the jump-history
/// menu — the touch translation of macOS right-click history menus.
struct ReaderTopBarIOS: View {
    let model: ReaderSessionModel
    @Bindable var chrome: ReaderChromeModel
    let palette: DesignPalette

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 16) {
            Button {
                chrome.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .disabled(model.activeTabID == nil)
            .accessibilityLabel("Sidebar")
            .hoverEffect(.highlight)

            historyButton(
                icon: "chevron.left", label: "Back",
                entries: model.activeTab?.history.back ?? [],
                enabled: model.canGoBack,
                step: { model.goBack() },
                jump: { steps in model.goBack(steps: steps) }
            )
            historyButton(
                icon: "chevron.right", label: "Forward",
                entries: model.activeTab?.history.forward ?? [],
                enabled: model.canGoForward,
                step: { model.goForward() },
                jump: { steps in model.goForward(steps: steps) }
            )

            Spacer()

            // iPhone reading mode: lock the chrome visible (auto-hide off).
            if sizeClass == .compact {
                Button {
                    chrome.chromeLocked.toggle()
                } label: {
                    Image(systemName: chrome.chromeLocked ? "lock.fill" : "lock.open")
                }
                .accessibilityLabel(chrome.chromeLocked ? "Unlock toolbars" : "Lock toolbars visible")
                .hoverEffect(.highlight)
            }

            if model.activeTabID != nil {
                Button {
                    chrome.showFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Find in document")
                .hoverEffect(.highlight)

                splitControl
            }

            Button {
                chrome.showingLibrary = true
            } label: {
                Image(systemName: "books.vertical")
            }
            .accessibilityLabel("Library")
            .hoverEffect(.highlight)

            Button {
                chrome.showingImporter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Open PDF")
            .hoverEffect(.highlight)
        }
        .font(.system(size: 15))
        .foregroundStyle(Color(platformColor: palette.ink))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.chromeGradient)
        .overlay(alignment: .bottom) {
            Color(platformColor: palette.chromeBorder).frame(height: 1)
        }
    }

    /// Split control: iPhone toggles a top/bottom split; iPad offers a
    /// menu to split right or bottom and to re-orient / close an open one.
    @ViewBuilder
    private var splitControl: some View {
        if sizeClass == .compact {
            Button {
                model.toggleSplit(axis: .vertical)
            } label: {
                Image(systemName: model.splitTabID == nil
                    ? "rectangle.split.1x2" : "rectangle")
            }
            .accessibilityLabel(
                model.splitTabID == nil ? "Split top and bottom" : "Close split")
            .hoverEffect(.highlight)
        } else {
            Menu {
                if model.splitTabID == nil {
                    Button {
                        model.toggleSplit(axis: .horizontal)
                    } label: {
                        Label("Split Right", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        model.toggleSplit(axis: .vertical)
                    } label: {
                        Label("Split Bottom", systemImage: "rectangle.split.1x2")
                    }
                } else {
                    Button {
                        model.setSplitAxis(.horizontal)
                    } label: {
                        Label("Side by Side", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        model.setSplitAxis(.vertical)
                    } label: {
                        Label("Top and Bottom", systemImage: "rectangle.split.1x2")
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.closeSplit()
                    } label: {
                        Label("Close Split", systemImage: "xmark")
                    }
                }
            } label: {
                Image(systemName: model.splitTabID == nil
                    ? "rectangle.split.2x1" : "rectangle.split.2x1.fill")
            }
            .accessibilityLabel("Split")
            .hoverEffect(.highlight)
        }
    }

    /// Tap = one step; the menu (long-press / pointer press) lists the
    /// whole stack, nearest first, labeled by section.
    private func historyButton(
        icon: String, label: String, entries: [NavEntry], enabled: Bool,
        step: @escaping () -> Void, jump: @escaping (Int) -> Void
    ) -> some View {
        Menu {
            ForEach(Array(entries.reversed().enumerated()), id: \.offset) { offset, entry in
                Button(model.label(for: entry)) {
                    jump(offset + 1)
                }
            }
        } label: {
            Image(systemName: icon)
                .opacity(enabled ? 1 : 0.35)
        } primaryAction: {
            step()
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
        .hoverEffect(.highlight)
    }
}
