import PDFKit
import ReaderCore
import ReaderUI
import SwiftUI

/// Bottom bar of the reader — the mockup status bar, matching macOS
/// `ReaderStatusBar`: layout + fit icons LEFT, page cluster CENTERED, theme
/// menu RIGHT. Compact width collapses the layout icons into one menu and
/// drops the fit buttons so the cluster fits an iPhone.
struct ReaderBottomBarIOS: View {
    let model: ReaderSessionModel
    let theme: ThemeStore
    let palette: DesignPalette

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pageField = ""
    @FocusState private var pageFieldFocused: Bool

    private var pageCount: Int? {
        model.activeDocument?.pageCount
    }

    var body: some View {
        ZStack {
            HStack(spacing: 12) {
                if pageCount != nil {
                    if sizeClass == .regular {
                        displayModeButtons
                        fitButtons
                    } else {
                        compactLayoutMenu
                    }
                }
                Spacer()
                themeMenu
            }
            if pageCount != nil {
                pageCluster
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(Color(platformColor: palette.ink))
        .background(palette.chromeGradient)
        .overlay(alignment: .top) {
            Color(platformColor: palette.chromeBorder).frame(height: 1)
        }
        .onAppear(perform: syncPageField)
        .onChange(of: model.activeTab?.pageIndex) { _, _ in syncPageField() }
        .onChange(of: model.activeTabID) { _, _ in syncPageField() }
    }

    /// Same glyph set as macOS, normalized to one visual height (portrait
    /// symbols are intrinsically taller — the "single page icon" bug).
    private func layoutIcon(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 14)
    }

    private var displayModeButtons: some View {
        HStack(spacing: 14) {
            modeButton(.singlePage, icon: "rectangle.portrait", hint: "Single page")
            modeButton(.singlePageContinuous, icon: "rectangle.grid.1x2", hint: "Continuous scroll")
            modeButton(.twoUp, icon: "rectangle.split.2x1", hint: "Two pages")
            modeButton(.twoUpContinuous, icon: "rectangle.grid.2x2", hint: "Two pages, continuous")
        }
    }

    private func modeButton(_ mode: PDFDisplayMode, icon: String, hint: String) -> some View {
        let isOn = model.activeDisplayMode == mode
        return Button {
            model.setDisplayMode(mode)
        } label: {
            layoutIcon(icon)
                .foregroundStyle(
                    isOn
                        ? Color(platformColor: palette.accent)
                        : Color(platformColor: palette.ink).opacity(0.5))
        }
        .accessibilityLabel(hint)
        .hoverEffect(.highlight)
    }

    private var fitButtons: some View {
        HStack(spacing: 10) {
            Button {
                model.fitWidth()
            } label: {
                layoutIcon("arrow.left.and.right.square")
                    .foregroundStyle(Color(platformColor: palette.ink).opacity(0.5))
            }
            .accessibilityLabel("Fit width")
            .hoverEffect(.highlight)
            Button {
                model.fitHeight()
            } label: {
                layoutIcon("arrow.up.and.down.square")
                    .foregroundStyle(Color(platformColor: palette.ink).opacity(0.5))
            }
            .accessibilityLabel("Fit height")
            .hoverEffect(.highlight)
        }
        .padding(.leading, 2)
    }

    /// iPhone: all layout + fit options behind one icon.
    private var compactLayoutMenu: some View {
        Menu {
            Picker("Page Layout", selection: Binding(
                get: { model.activeDisplayMode },
                set: { model.setDisplayMode($0) }
            )) {
                Label("Single Page", systemImage: "rectangle.portrait")
                    .tag(PDFDisplayMode.singlePage)
                Label("Continuous Scroll", systemImage: "rectangle.grid.1x2")
                    .tag(PDFDisplayMode.singlePageContinuous)
                Label("Two Pages", systemImage: "rectangle.split.2x1")
                    .tag(PDFDisplayMode.twoUp)
                Label("Two Pages Continuous", systemImage: "rectangle.grid.2x2")
                    .tag(PDFDisplayMode.twoUpContinuous)
            }
            Divider()
            Button("Fit Width") { model.fitWidth() }
            Button("Fit Height") { model.fitHeight() }
        } label: {
            layoutIcon("rectangle.grid.1x2")
                .foregroundStyle(Color(platformColor: palette.ink).opacity(0.6))
        }
        .accessibilityLabel("Page layout")
    }

    /// ⇤ ‹ [477] of 738 › ⇥ — centered, mono page chip (macOS mockup).
    private var pageCluster: some View {
        HStack(spacing: 9) {
            Button {
                model.goToPreviousSection()
            } label: {
                Image(systemName: "chevron.left.to.line")
                    .foregroundStyle(Color(platformColor: palette.ink).opacity(0.45))
            }
            .disabled(!model.canGoToPreviousSection)
            .accessibilityLabel("Previous section")
            .hoverEffect(.highlight)
            Button {
                model.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(Color(platformColor: palette.ink).opacity(0.6))
            }
            .disabled(!PageArrows.canGoBack(
                pageIndex: model.activeTab?.pageIndex, pageCount: pageCount ?? 0))
            .accessibilityLabel("Previous page")
            .hoverEffect(.highlight)
            TextField("", text: $pageField)
                .keyboardType(.numberPad)
                .focused($pageFieldFocused)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(platformColor: palette.ink).opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    Color(platformColor: palette.ink).opacity(0.14))
                        )
                )
                .onSubmit(jumpToTypedPage)
                .accessibilityLabel("Go to page")
            Text("of \(pageCount ?? 0)")
                .font(.system(size: 12))
                .foregroundStyle(Color(platformColor: palette.ink).opacity(0.55))
                .monospacedDigit()
            Button {
                model.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color(platformColor: palette.ink).opacity(0.6))
            }
            .disabled(!PageArrows.canGoForward(
                pageIndex: model.activeTab?.pageIndex, pageCount: pageCount ?? 0))
            .accessibilityLabel("Next page")
            .hoverEffect(.highlight)
            Button {
                model.goToNextSection()
            } label: {
                Image(systemName: "chevron.right.to.line")
                    .foregroundStyle(Color(platformColor: palette.ink).opacity(0.45))
            }
            .disabled(!model.canGoToNextSection)
            .accessibilityLabel("Next section")
            .hoverEffect(.highlight)
        }
        .font(.system(size: 13))
    }

    private var themeMenu: some View {
        Menu {
            Picker("Theme", selection: Bindable(theme).current) {
                Text("Auto").tag(AppTheme.auto)
                Text("Light").tag(AppTheme.light)
                Text("Dark").tag(AppTheme.dark)
                Text("Sepia").tag(AppTheme.sepia)
            }
        } label: {
            Label(ThemeStore.label(for: theme.current),
                  systemImage: "circle.lefthalf.filled")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(platformColor: palette.ink))
        }
        .fixedSize()
        .accessibilityLabel("Theme")
        .hoverEffect(.highlight)
    }

    private func syncPageField() {
        pageField = "\((model.activeTab?.pageIndex ?? 0) + 1)"
        pageFieldFocused = false
    }

    /// Page jumps push history (macOS ⌘G semantics).
    private func jumpToTypedPage() {
        guard let pageCount,
              let number = Int(pageField.trimmingCharacters(in: .whitespaces)),
              (1...pageCount).contains(number)
        else {
            syncPageField()
            return
        }
        model.jump(to: NavEntry(pageIndex: number - 1))
        pageFieldFocused = false
    }
}
