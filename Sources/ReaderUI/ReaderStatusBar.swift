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

    private var palette: DesignPalette { DesignPalette.current }

    var body: some View {
        // Mockup layout: layout icons LEFT, page cluster CENTERED in the
        // window (not flowed), theme menu RIGHT.
        ZStack {
            HStack(spacing: 12) {
                // With no document, only the theme switcher remains (owner
                // feedback: disabled PDF controls in an empty window are
                // noise).
                if pageCount != nil {
                    displayModeButtons
                    fitButtons
                }
                Spacer()
                Menu {
                    Picker("Theme", selection: Bindable(ThemeManager.shared).current) {
                        Text("Auto").tag(AppTheme.auto)
                        Section("Light") {
                            ForEach(AppTheme.lightFamily, id: \.self) { choice in
                                Text(choice.displayName).tag(choice)
                            }
                        }
                        Section("Dark") {
                            ForEach(AppTheme.darkFamily, id: \.self) { choice in
                                Text(choice.displayName).tag(choice)
                            }
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(themeName, systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .instantHint("Theme")
            }
            if pageCount != nil {
                pageCluster
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .foregroundStyle(palette.inkColor)
        .background(palette.chromeGradient)
        .overlay(alignment: .top) {
            palette.chromeBorderColor.frame(height: 1)
        }
        .onAppear(perform: syncPageField)
        .onChange(of: model.activeTab?.pageIndex) { _, _ in syncPageField() }
        .onChange(of: model.activeTabID) { _, _ in syncPageField() }
    }

    /// Page-layout modes as quiet icons (the mockup's rects), accent on
    /// the active one — replaces the boxy segmented picker.
    private var displayModeButtons: some View {
        HStack(spacing: 11) {
            modeButton(.singlePage, icon: "rectangle.portrait", hint: "Single page")
            modeButton(.singlePageContinuous, icon: "rectangle.grid.1x2", hint: "Continuous scroll")
            modeButton(.twoUp, icon: "rectangle.split.2x1", hint: "Two pages")
            modeButton(.twoUpContinuous, icon: "rectangle.grid.2x2", hint: "Two pages, continuous")
        }
        .buttonStyle(.borderless)
    }

    private func modeButton(_ mode: PDFDisplayMode, icon: String, hint: String) -> some View {
        let isOn = (model.activeTab?.displayModeRaw
            ?? PDFDisplayMode.singlePageContinuous.rawValue) == mode.rawValue
        return Button {
            model.setDisplayMode(mode.rawValue)
        } label: {
            layoutIcon(icon)
                .foregroundStyle(isOn ? palette.accentColor : palette.inkColor.opacity(0.5))
        }
        .instantHint(hint)
    }

    /// Uniform glyph box for the layout + fit icons. SF Symbols in this
    /// row have unequal natural sizes — portrait-orientation glyphs are
    /// taller: at 13 pt "rectangle.portrait" measures 14×16 while its
    /// landscape neighbors are all 14 tall — so "Single page" read
    /// visibly bigger than the rest (owner round 22). Fitting every
    /// glyph into one fixed frame equalizes their visual height.
    private func layoutIcon(_ name: String) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 14)
    }

    private var fitButtons: some View {
        HStack(spacing: 8) {
            Button {
                model.fitWidth()
            } label: {
                layoutIcon("arrow.left.and.right.square")
                    .foregroundStyle(palette.inkColor.opacity(0.5))
            }
            .instantHint("Fit width")
            Button {
                model.fitHeight()
            } label: {
                layoutIcon("arrow.up.and.down.square")
                    .foregroundStyle(palette.inkColor.opacity(0.5))
            }
            .instantHint("Fit height")
        }
        .buttonStyle(.borderless)
        .padding(.leading, 2)
    }

    /// ⇤ ‹ [477] of 738 › ⇥ — centered, mono page chip.
    private var pageCluster: some View {
        HStack(spacing: 9) {
            Button {
                model.goToPreviousSection()
            } label: {
                Image(systemName: "chevron.left.to.line")
                    .foregroundStyle(palette.inkColor.opacity(0.45))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoToPreviousSection)
            .instantHint("Previous section")
            Button {
                model.goToPreviousPage()
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(palette.inkColor.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .disabled(!PageArrows.canGoBack(
                pageIndex: currentPageIndex, pageCount: pageCount ?? 0
            ))
            .instantHint("Previous page")
            TextField("", text: $pageField)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 44)
                .multilineTextAlignment(.center)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(palette.inkColor.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(palette.inkColor.opacity(0.14))
                        )
                )
                .onSubmit(jumpToTypedPage)
                .instantHint("Go to page")
            Text("of \(pageCount ?? 0)")
                .font(.system(size: 12))
                .foregroundStyle(palette.inkColor.opacity(0.55))
                .monospacedDigit()
            Button {
                model.goToNextPage()
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(palette.inkColor.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .disabled(!PageArrows.canGoForward(
                pageIndex: currentPageIndex, pageCount: pageCount ?? 0
            ))
            .instantHint("Next page")
            Button {
                model.goToNextSection()
            } label: {
                Image(systemName: "chevron.right.to.line")
                    .foregroundStyle(palette.inkColor.opacity(0.45))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canGoToNextSection)
            .instantHint("Next section")
        }
    }

    private var currentPageIndex: Int? {
        model.activeTab?.pageIndex
    }

    private var themeName: String {
        ThemeManager.shared.current.displayName
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

/// Enablement math for the status-bar page arrows, extracted for tests.
/// `pageIndex` is nil when no tab is active; a `pageCount` of 0 means no
/// document (both disable the arrows). Cross-platform: the iOS bottom bar
/// uses the same math.
public enum PageArrows {
    public static func canGoBack(pageIndex: Int?, pageCount: Int) -> Bool {
        guard let pageIndex, pageCount > 0 else { return false }
        return pageIndex > 0
    }

    public static func canGoForward(pageIndex: Int?, pageCount: Int) -> Bool {
        guard let pageIndex, pageCount > 0 else { return false }
        return pageIndex < pageCount - 1
    }
}
