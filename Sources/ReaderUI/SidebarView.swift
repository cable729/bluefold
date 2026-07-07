#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI

/// Left sidebar: table of contents or page thumbnails for the active tab.
struct SidebarView: View {
    enum Mode: String, CaseIterable {
        case outline = "Contents"
        case thumbnails = "Pages"
    }

    let outline: [OutlineNode]
    let document: PDFDocument
    let onJump: (NavEntry) -> Void

    @State private var mode: Mode = .outline

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            switch mode {
            case .outline:
                if outline.isEmpty {
                    ContentUnavailableView(
                        "No Table of Contents",
                        systemImage: "list.bullet.indent",
                        description: Text("This PDF has no outline.")
                    )
                } else {
                    List(outline, children: \.children) { node in
                        Button {
                            if let entry = node.entry {
                                onJump(entry)
                            }
                        } label: {
                            Text(node.label)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.sidebar)
                }
            case .thumbnails:
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(0..<document.pageCount, id: \.self) { pageIndex in
                            ThumbnailCell(document: document, pageIndex: pageIndex) {
                                onJump(NavEntry(pageIndex: pageIndex))
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

private struct ThumbnailCell: View {
    let document: PDFDocument
    let pageIndex: Int
    let onTap: () -> Void

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(0.77, contentMode: .fit)
                }
            }
            .frame(maxWidth: 130)
            .shadow(radius: 1)
            .onTapGesture(perform: onTap)

            Text("\(pageIndex + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .task {
            guard image == nil, let page = document.page(at: pageIndex) else { return }
            image = page.thumbnail(of: CGSize(width: 130, height: 180), for: .cropBox)
        }
    }
}
#endif
