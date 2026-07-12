#if os(macOS)
import ReaderCore
import SwiftUI

/// One PANE's tab bar (each pane of a split window carries its own).
/// Rendering and drag tracking live in the AppKit-backed `TabStripNSView`
/// (SwiftUI's .draggable/.onTapGesture pairing could not express reorder,
/// tear-off, or reliable cross-window drops); this wrapper feeds it display
/// state and wires its actions to the window model and session coordinator.
struct TabBarView: View {
    @Bindable var model: ReaderWindowModel
    let pane: ReaderPane
    let onNewTab: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let palette = DesignPalette.current
        HStack(spacing: 0) {
            TabStripRepresentable(
                model: model,
                pane: pane,
                items: displayItems,
                isWindowSplit: model.splitTabID != nil,
                openWindow: openWindow
            )
            // "+" merges both ways of opening a tab (round-5 owner request:
            // it previously only ran the file panel, hiding the library).
            Menu {
                Button("From Library…", systemImage: "books.vertical") {
                    openWindow(id: "library")
                }
                Button("Open File…", systemImage: "folder", action: onNewTab)
            } label: {
                Image(systemName: "plus")
                    .foregroundStyle(palette.inkColor.opacity(0.55))
            }
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 8)
            .help("New tab — from the library (⌘O) or a file (⌘T / ⌥⌘O)")
        }
        .frame(height: TabStripNSView.stripHeight)
        .background(palette.stripBackgroundColor)
        .overlay(alignment: .bottom) {
            palette.chromeBorderColor.frame(height: 1)
        }
    }

    /// Reading the model's tab state here keeps the strip inside SwiftUI's
    /// observation tracking: any tab mutation re-evaluates this body and
    /// pushes fresh items into the NSView.
    private var displayItems: [TabDisplayItem] {
        let activeID = pane == .split ? model.splitTabID : model.activeTabID
        return model.tabs(in: pane).map { tab in
            TabDisplayItem(
                id: tab.id,
                title: URL(fileURLWithPath: tab.pathHint)
                    .deletingPathExtension()
                    .lastPathComponent,
                breadcrumb: tab.breadcrumb.flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "p.\(tab.pageIndex + 1)",
                isActive: tab.id == activeID,
                groupKey: tab.pathHint,
                tint: BookTint.color(forPath: tab.pathHint)
            )
        }
    }
}

private struct TabStripRepresentable: NSViewRepresentable {
    let model: ReaderWindowModel
    let pane: ReaderPane
    let items: [TabDisplayItem]
    let isWindowSplit: Bool
    let openWindow: OpenWindowAction

    func makeNSView(context: Context) -> TabStripScrollView {
        let strip = TabStripNSView(
            stripID: TabStripID(windowID: model.windowID, pane: pane),
            actions: TabStripActions(
                select: { _ in }, close: { _ in }, duplicate: { _ in },
                closeOthers: { _ in }, reorder: { _, _ in },
                moveToStrip: { _, _, _ in }, detachToNewWindow: { _, _ in }
            )
        )
        strip.actions = actions(for: strip)
        strip.apply(items: items, palette: DesignPalette.current, isWindowSplit: isWindowSplit)
        return TabStripScrollView(strip: strip)
    }

    func updateNSView(_ view: TabStripScrollView, context: Context) {
        guard let strip = view.documentView as? TabStripNSView else { return }
        strip.actions = actions(for: strip)
        strip.apply(items: items, palette: DesignPalette.current, isWindowSplit: isWindowSplit)
    }

    private func actions(for view: TabStripNSView) -> TabStripActions {
        let model = self.model
        let openWindow = self.openWindow
        return TabStripActions(
            select: { model.selectTab(id: $0) },
            close: { model.closeTab(id: $0) },
            closeMany: { model.closeTabs(ids: $0) },
            duplicate: { model.duplicateTab(id: $0) },
            closeOthers: { model.closeOtherTabs(keeping: $0) },
            openInSplit: { model.openInSplit(tabID: $0, side: $1) },
            closeSplit: { model.closeSplit() },
            moveToOtherPane: { [pane] tabID in
                model.moveTab(id: tabID, toPane: pane == .split ? .primary : .split)
            },
            reorder: { model.moveTab(id: $0, toIndex: $1) },
            moveToStrip: { [weak view] tabID, target, index in
                if target.windowID == model.windowID {
                    // This window's other pane: a membership move.
                    model.moveTab(id: tabID, toPane: target.pane, at: index)
                    return
                }
                SessionCoordinator.shared.moveTab(
                    tabID, from: model.windowID, to: target.windowID,
                    at: index, pane: target.pane
                )
                closeWindowIfEmptied(model: model, view: view)
            },
            detachToNewWindow: { [weak view] tabID, screenPoint in
                // A single-tab window dragged to the desktop just moves —
                // detaching and closing would only add churn and flicker.
                if model.tabs.count == 1, let window = view?.window {
                    window.setFrameOrigin(CGPoint(
                        x: screenPoint.x - window.frame.width / 2,
                        y: screenPoint.y - window.frame.height + 24
                    ))
                    return
                }
                guard let newID = SessionCoordinator.shared.detachTabToNewWindow(
                    tabID, from: model.windowID, at: screenPoint
                ) else { return }
                openWindow(id: "reader", value: newID)
                closeWindowIfEmptied(model: model, view: view)
            },
            dropIntoSplit: { [weak view] tabID, targetWindowID, side in
                if targetWindowID == model.windowID {
                    model.openInSplit(tabID: tabID, side: side)
                    return
                }
                // Cross-window: move the tab first (same as a strip drop),
                // then open it as the target's split.
                SessionCoordinator.shared.moveTabIntoSplit(
                    tabID, from: model.windowID, to: targetWindowID, side: side
                )
                closeWindowIfEmptied(model: model, view: view)
            }
        )
    }

    private func closeWindowIfEmptied(model: ReaderWindowModel, view: TabStripNSView?) {
        if model.tabs.isEmpty {
            view?.window?.close()
        }
    }
}
#endif
