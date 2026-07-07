#if os(macOS)
import ReaderCore
import SwiftUI

/// Browser-style tab strip drawn by the app (native window tabbing is
/// disabled so tab behavior is identical across platforms).
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
                            select: { model.selectTab(id: tab.id) },
                            close: { model.closeTab(id: tab.id) }
                        )
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
        .frame(height: 30)
        .background(.bar)
    }

    private func title(for tab: TabState) -> String {
        URL(fileURLWithPath: tab.pathHint)
            .deletingPathExtension()
            .lastPathComponent
    }
}

private struct TabItemView: View {
    let title: String
    let isActive: Bool
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

            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .frame(minWidth: 80, maxWidth: 220)
        .background(isActive ? Color(nsColor: .controlBackgroundColor) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
    }
}
#endif
