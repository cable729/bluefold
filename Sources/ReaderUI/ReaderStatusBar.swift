#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI

/// Bottom bar of a reader window: page layout controls, page position with
/// direct jump, and the theme switcher. Always visible — with no document
/// (`pageCount == nil`) the page controls disable so the theme switcher
/// stays reachable from an empty window.
struct ReaderStatusBar: View {
    @Bindable var model: ReaderWindowModel
    let pageCount: Int?

    @State private var pageField = ""

    var body: some View {
        HStack(spacing: 12) {
            Group {
                displayModePicker
                HStack(spacing: 2) {
                    Button {
                        model.fitWidth()
                    } label: {
                        Image(systemName: "arrow.left.and.right.square")
                    }
                    .help("Fit width")
                    Button {
                        model.fitHeight()
                    } label: {
                        Image(systemName: "arrow.up.and.down.square")
                    }
                    .help("Fit height")
                }
                .buttonStyle(.borderless)

                Spacer()

                HStack(spacing: 4) {
                    TextField("", text: $pageField)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                        .multilineTextAlignment(.center)
                        .onSubmit(jumpToTypedPage)
                    Text("of \(pageCount ?? 0)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .monospacedDigit()
                .opacity(pageCount == nil ? 0 : 1)
            }
            .disabled(pageCount == nil)

            Spacer()

            Menu {
                Picker("Theme", selection: Bindable(ThemeManager.shared).current) {
                    Text("Auto").tag(AppTheme.auto)
                    Text("Light").tag(AppTheme.light)
                    Text("Dark").tag(AppTheme.dark)
                    Text("Sepia").tag(AppTheme.sepia)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(themeName, systemImage: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Theme")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear(perform: syncPageField)
        .onChange(of: model.activeTab?.pageIndex) { _, _ in syncPageField() }
        .onChange(of: model.activeTabID) { _, _ in syncPageField() }
    }

    private var themeName: String {
        switch ThemeManager.shared.current {
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
        case .auto: "Auto"
        }
    }

    private var displayModePicker: some View {
        Picker("Layout", selection: displayModeBinding) {
            Image(systemName: "doc").tag(PDFDisplayMode.singlePage.rawValue)
                .help("Single page")
            Image(systemName: "doc.text").tag(PDFDisplayMode.singlePageContinuous.rawValue)
                .help("Continuous scroll")
            Image(systemName: "book.closed").tag(PDFDisplayMode.twoUp.rawValue)
                .help("Two pages")
            Image(systemName: "book").tag(PDFDisplayMode.twoUpContinuous.rawValue)
                .help("Two pages, continuous")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var displayModeBinding: Binding<Int> {
        Binding(
            get: { model.activeTab?.displayModeRaw ?? PDFDisplayMode.singlePageContinuous.rawValue },
            set: { model.setDisplayMode($0) }
        )
    }

    private func syncPageField() {
        pageField = "\((model.activeTab?.pageIndex ?? 0) + 1)"
    }

    private func jumpToTypedPage() {
        guard let pageCount,
              let number = Int(pageField.trimmingCharacters(in: .whitespaces)),
              (1...pageCount).contains(number)
        else {
            syncPageField()
            return
        }
        model.jump(to: NavEntry(pageIndex: number - 1))
    }
}
#endif
