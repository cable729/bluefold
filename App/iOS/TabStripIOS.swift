import ReaderCore
import ReaderUI
import SwiftUI
import UniformTypeIdentifiers

/// Drag payloads for the strip and split drop zone, encoded as prefixed
/// plain-text strings (a custom UTType would need an exported Info.plist
/// declaration; these never leave the app).
enum DragPayload {
    static let tabPrefix = "bluefold-tab:"
    static let sectionPrefix = "bluefold-section:"

    static func tab(_ id: UUID) -> String {
        tabPrefix + id.uuidString
    }

    static func section(_ entry: NavEntry) -> String {
        let x = entry.point.map { "\($0.x)" } ?? ""
        let y = entry.point.map { "\($0.y)" } ?? ""
        return "\(sectionPrefix)\(entry.pageIndex):\(x):\(y)"
    }

    static func decodeTab(_ string: String) -> UUID? {
        guard string.hasPrefix(tabPrefix) else { return nil }
        return UUID(uuidString: String(string.dropFirst(tabPrefix.count)))
    }

    static func decodeSection(_ string: String) -> NavEntry? {
        guard string.hasPrefix(sectionPrefix) else { return nil }
        let parts = String(string.dropFirst(sectionPrefix.count)).split(
            separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let page = Int(parts[0]) else { return nil }
        var point: CGPoint?
        if let x = Double(parts[1]), let y = Double(parts[2]) {
            point = CGPoint(x: x, y: y)
        }
        return NavEntry(pageIndex: page, point: point)
    }
}

/// The Cloth & Paper tab strip: book-tinted lozenge cells (title over
/// deepest-breadcrumb-component), on the chrome strip band. Touch
/// translations of the macOS strip: tap = activate, drag = reorder,
/// long-press = the tab context menu, drop of a sidebar section = new tab.
struct TabStripIOS: View {
    let model: ReaderSessionModel
    let palette: DesignPalette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in
                    TabCellIOS(model: model, tab: tab, palette: palette)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(Color(platformColor: palette.stripBackground))
        // A sidebar section dropped on strip whitespace opens a new tab.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first,
                  let entry = DragPayload.decodeSection(payload),
                  let url = model.activeURL
            else { return false }
            model.openTab(url: url, at: entry, activate: false)
            return true
        }
    }
}

private struct TabCellIOS: View {
    let model: ReaderSessionModel
    let tab: TabState
    let palette: DesignPalette

    var body: some View {
        let isActive = tab.id == model.activeTabID
        let isSplit = tab.id == model.splitTabID
        let tint = Color(platformColor: BookTint.color(forPath: tab.pathHint))

        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(isActive ? .semibold : .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .opacity(0.55)
                    .lineLimit(1)
                    .truncationMode(.tail)  // "3.1 Conv…", keep the number
            }
            .frame(maxWidth: 148, alignment: .leading)
            if isSplit {
                Image(systemName: "rectangle.split.2x1")
                    .font(.caption2)
                    .opacity(0.5)
            }
            if isActive {
                Button {
                    model.close(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.55)
                }
                .accessibilityLabel("Close \(title)")
                .hoverEffect(.highlight)
            }
        }
        .foregroundStyle(Color(platformColor: palette.ink))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.20))
                if isActive {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(platformColor: palette.activeCellFill))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(platformColor: palette.accent).opacity(0.55))
                }
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .hoverEffect(.highlight)
        .onTapGesture {
            model.activate(tab.id)
        }
        .contextMenu {
            Button {
                model.duplicate(tab.id)
            } label: {
                Label("Duplicate Tab", systemImage: "plus.square.on.square")
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                Button {
                    model.openInSplit(tabID: tab.id)
                } label: {
                    Label("Open in Split", systemImage: "rectangle.split.2x1")
                }
            }
            Divider()
            Button(role: .destructive) {
                model.close(tab.id)
            } label: {
                Label("Close Tab", systemImage: "xmark")
            }
            Button(role: .destructive) {
                model.closeOthers(keeping: tab.id)
            } label: {
                Label("Close Other Tabs", systemImage: "xmark.square")
            }
        }
        .draggable(DragPayload.tab(tab.id))
        // Dropping another tab on this cell reorders it to this position;
        // dropping a sidebar section opens an adjacent tab.
        .dropDestination(for: String.self) { items, _ in
            guard let payload = items.first else { return false }
            if let draggedID = DragPayload.decodeTab(payload) {
                model.move(tabID: draggedID, before: tab.id)
                return true
            }
            if let entry = DragPayload.decodeSection(payload),
               let url = model.activeURL {
                let index = model.tabs.firstIndex { $0.id == tab.id }
                model.openTab(
                    url: url, at: entry,
                    insertAt: index.map { $0 + 1 }, activate: false)
                return true
            }
            return false
        }
    }

    private var title: String {
        ((tab.pathHint as NSString).lastPathComponent as NSString)
            .deletingPathExtension
    }

    /// Deepest breadcrumb component (round 21), falling back to the page.
    private var subtitle: String {
        if let crumb = tab.breadcrumb,
           let deepest = crumb.components(separatedBy: " › ").last,
           !deepest.isEmpty {
            return deepest
        }
        return "p.\(tab.pageIndex + 1)"
    }
}
