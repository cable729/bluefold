#if os(macOS)
import ReaderCore
import SwiftUI

/// Browser-style tab strip. Rendering and drag tracking live in the
/// AppKit-backed `TabStripNSView` (SwiftUI's .draggable/.onTapGesture pairing
/// could not express reorder, tear-off, or reliable cross-window drops); this
/// wrapper feeds it display state and wires its actions to the window model
/// and session coordinator.
struct TabBarView: View {
    @Bindable var model: ReaderWindowModel
    let onNewTab: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            TabStripRepresentable(
                model: model,
                items: displayItems,
                openWindow: openWindow
            )
            Button(action: onNewTab) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("Open a PDF in a new tab (⌘T)")
        }
        .frame(height: 48)
        .background(.bar)
    }

    /// Reading `model.tabs` here keeps the strip inside SwiftUI's observation
    /// tracking: any tab mutation re-evaluates this body and pushes fresh
    /// items into the NSView.
    private var displayItems: [TabDisplayItem] {
        model.tabs.map { tab in
            TabDisplayItem(
                id: tab.id,
                title: URL(fileURLWithPath: tab.pathHint)
                    .deletingPathExtension()
                    .lastPathComponent,
                breadcrumb: model.tabBreadcrumbs[tab.id].flatMap {
                    $0.isEmpty ? nil : $0
                } ?? "p.\(tab.pageIndex + 1)",
                isActive: tab.id == model.activeTabID,
                groupKey: tab.pathHint
            )
        }
    }
}

private struct TabStripRepresentable: NSViewRepresentable {
    let model: ReaderWindowModel
    let items: [TabDisplayItem]
    let openWindow: OpenWindowAction

    func makeNSView(context: Context) -> TabStripNSView {
        let view = TabStripNSView(
            windowID: model.windowID,
            actions: TabStripActions(
                select: { _ in }, close: { _ in }, duplicate: { _ in },
                closeOthers: { _ in }, reorder: { _, _ in },
                moveToWindow: { _, _, _ in }, detachToNewWindow: { _, _ in }
            )
        )
        view.actions = actions(for: view)
        view.update(items: items)
        return view
    }

    func updateNSView(_ view: TabStripNSView, context: Context) {
        view.actions = actions(for: view)
        view.update(items: items)
    }

    private func actions(for view: TabStripNSView) -> TabStripActions {
        let model = self.model
        let openWindow = self.openWindow
        return TabStripActions(
            select: { model.selectTab(id: $0) },
            close: { model.closeTab(id: $0) },
            duplicate: { model.duplicateTab(id: $0) },
            closeOthers: { model.closeOtherTabs(keeping: $0) },
            reorder: { model.moveTab(id: $0, toIndex: $1) },
            moveToWindow: { [weak view] tabID, targetWindowID, index in
                SessionCoordinator.shared.moveTab(
                    tabID, from: model.windowID, to: targetWindowID, at: index
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
