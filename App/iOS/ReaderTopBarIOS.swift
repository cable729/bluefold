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

            if model.activeTabID != nil {
                Button {
                    chrome.showFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Find in document")
                .hoverEffect(.highlight)

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Button {
                        model.toggleSplit()
                    } label: {
                        Image(systemName: model.splitTabID == nil
                            ? "rectangle.split.2x1" : "rectangle")
                    }
                    .accessibilityLabel(
                        model.splitTabID == nil ? "Split right" : "Close split")
                    .hoverEffect(.highlight)
                }
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
