#if os(macOS)
import ReaderCore
import SwiftUI

/// Browser-style tab strip drawn by the app (native window tabbing is
/// disabled so tab behavior is identical across platforms). Tabs can be
/// dragged between windows; payload is "sourceWindowID|tabID".
struct TabBarView: View {
    @Bindable var model: ReaderWindowModel
    let onNewTab: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(model.tabs) { tab in
                        TabItemView(
                            title: title(for: tab),
                            isActive: tab.id == model.activeTabID,
                            groupColor: groupColor(for: tab),
                            select: { model.selectTab(id: tab.id) },
                            close: { model.closeTab(id: tab.id) }
                        )
                        .draggable("\(model.windowID.uuidString)|\(tab.id.uuidString)")
                        .contextMenu {
                            Button("Duplicate Tab") { model.duplicateTab(id: tab.id) }
                            Divider()
                            Button("Close Tab") { model.closeTab(id: tab.id) }
                            Button("Close Other Tabs") { model.closeOtherTabs(keeping: tab.id) }
                                .disabled(model.tabs.count < 2)
                        }
                    }
                }
            }
            Button(action: onNewTab) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .help("Open a PDF in a new tab (⌘T)")
        }
        .frame(height: 32)
        .background(.bar)
        .dropDestination(for: String.self) { payloads, _ in
            handleDrop(payloads)
        }
    }

    private func handleDrop(_ payloads: [String]) -> Bool {
        var accepted = false
        for payload in payloads {
            let parts = payload.split(separator: "|").map(String.init)
            guard
                parts.count == 2,
                let sourceWindowID = UUID(uuidString: parts[0]),
                let tabID = UUID(uuidString: parts[1])
            else { continue }
            guard sourceWindowID != model.windowID else { continue }
            SessionCoordinator.shared.moveTab(tabID, from: sourceWindowID, to: model.windowID)
            accepted = true
        }
        return accepted
    }

    private func title(for tab: TabState) -> String {
        URL(fileURLWithPath: tab.pathHint)
            .deletingPathExtension()
            .lastPathComponent
    }

    /// Tabs of the same book share a stable color marker (only shown when a
    /// book has more than one tab — Chrome-style implicit groups; ⌘-clicked
    /// links already insert next to their source tab).
    private func groupColor(for tab: TabState) -> Color? {
        guard (model.tabCountByPath[tab.pathHint] ?? 0) > 1 else { return nil }
        let hue = Double(abs(tab.pathHint.hashValue % 360)) / 360.0
        return Color(hue: hue, saturation: 0.65, brightness: 0.85)
    }
}

private struct TabItemView: View {
    let title: String
    let isActive: Bool
    let groupColor: Color?
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || isActive ? 1 : 0)

            if let groupColor {
                Circle()
                    .fill(groupColor)
                    .frame(width: 6, height: 6)
            }

            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .frame(minWidth: 80, maxWidth: 220)
        .background {
            if isActive {
                Rectangle().fill(Color(nsColor: .textBackgroundColor))
            } else if isHovered {
                Rectangle().fill(.quaternary.opacity(0.5))
            }
        }
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(.tint).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
    }
}
#endif
