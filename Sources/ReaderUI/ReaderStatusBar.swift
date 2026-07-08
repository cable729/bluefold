#if os(macOS)
import PDFKit
import ReaderCore
import SwiftUI

/// Bottom bar of a reader window: page layout controls, page position with
/// direct jump, and the theme switcher.
struct ReaderStatusBar: View {
    @Bindable var model: ReaderWindowModel
    let pageCount: Int

    @State private var pageField = ""

    var body: some View {
        HStack(spacing: 12) {
            displayModePicker
            HStack(spacing: 2) {
                Button {
                    model.fitWidth()
                } label: {
                    Image(systemName: "arrow.left.and.right.square")
                }
                .instantHint("Fit width")
                .help("Fit width")
                Button {
                    model.fitHeight()
                } label: {
                    Image(systemName: "arrow.up.and.down.square")
                }
                .instantHint("Fit height")
                .help("Fit height")
            }
            .buttonStyle(.borderless)

            Spacer()

            HStack(spacing: 4) {
                Button {
                    model.goToPreviousPage()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!PageArrows.canGoBack(pageIndex: currentPageIndex, pageCount: pageCount))
                .instantHint("Previous page")
                .help("Previous page")
                TextField("", text: $pageField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.center)
                    .onSubmit(jumpToTypedPage)
                    .instantHint("Go to page")
                Text("of \(pageCount)")
                    .foregroundStyle(.secondary)
                Button {
                    model.goToNextPage()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(!PageArrows.canGoForward(pageIndex: currentPageIndex, pageCount: pageCount))
                .instantHint("Next page")
                .help("Next page")
            }
            .font(.callout)
            .monospacedDigit()

            Spacer()

            Menu {
                Picker("Theme", selection: Bindable(ThemeManager.shared).current) {
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
            .instantHint("Theme")
            .help("Theme")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
        .onAppear(perform: syncPageField)
        .onChange(of: model.activeTab?.pageIndex) { _, _ in syncPageField() }
        .onChange(of: model.activeTabID) { _, _ in syncPageField() }
    }

    private var currentPageIndex: Int? {
        model.activeTab?.pageIndex
    }

    private var themeName: String {
        switch ThemeManager.shared.current {
        case .light: "Light"
        case .dark: "Dark"
        case .sepia: "Sepia"
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
        guard let number = Int(pageField.trimmingCharacters(in: .whitespaces)),
              (1...pageCount).contains(number)
        else {
            syncPageField()
            return
        }
        model.jump(to: NavEntry(pageIndex: number - 1))
    }
}

/// Enablement math for the status-bar page arrows, extracted for tests.
/// `pageIndex` is nil when no tab is active; a `pageCount` of 0 means no
/// document (both disable the arrows).
enum PageArrows {
    static func canGoBack(pageIndex: Int?, pageCount: Int) -> Bool {
        guard let pageIndex, pageCount > 0 else { return false }
        return pageIndex > 0
    }

    static func canGoForward(pageIndex: Int?, pageCount: Int) -> Bool {
        guard let pageIndex, pageCount > 0 else { return false }
        return pageIndex < pageCount - 1
    }
}
#endif

