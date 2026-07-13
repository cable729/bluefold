#if os(macOS)
import ReaderCore
import SwiftUI

/// The Settings window (⌘,). Everything here binds to shared app state —
/// `ThemeManager`, `AppSettings`, `LibraryModel.shared` — so changes are
/// live in every open window; nothing needs a relaunch except keybindings
/// (which are a file, not a control, by design).
public struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var theme = ThemeManager.shared
    private let library = LibraryModel.shared
    /// NSWorkspace state, not observable — captured on section appear and
    /// after the Set as Default button runs.
    @State private var isDefaultViewer = false

    public init() {}

    public var body: some View {
        Form {
            appearanceSection
            readingSection
            memorySection
            indexingSection
            calibreSection
            watchedFoldersSection
            syncSection
            defaultViewerSection
            keybindingsSection
            deepLinksSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(ThemeChromeAccessor())  // titlebar tints with the theme
        .onChange(of: settings.backgroundIndexingEnabled) { _, _ in
            library.indexingSettingsChanged()
        }
        .onChange(of: settings.ocrIndexingEnabled) { _, _ in
            library.indexingSettingsChanged()
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $theme.current) {
                ForEach(Self.themeChoices, id: \.self) { choice in
                    Text(Self.themeLabel(choice)).tag(choice)
                }
            }
            .pickerStyle(.menu)
            Text(
                "Applies to every window immediately, page content included. "
                    + "Auto follows the system appearance."
            )
            .settingsCaption()
        }
    }

    /// Auto first (the recommended default), then the concrete themes in
    /// their View-menu order.
    static let themeChoices: [AppTheme] = [.auto, .light, .dark, .sepia]

    static func themeLabel(_ theme: AppTheme) -> String {
        theme == .auto ? "Auto (match system)" : theme.rawValue.capitalized
    }

    // MARK: - Reading

    private var readingSection: some View {
        Section("Reading") {
            Toggle("Link hover preview", isOn: $settings.linkHoverPreviewEnabled)
            Text(
                "Hovering an internal cross-reference peeks its destination in "
                    + "a small floating panel you can scroll and open from. "
                    + "Turn this off to just show a plain \u{201C}Go to page N\u{201D} "
                    + "tooltip instead. Applies immediately."
            )
            .settingsCaption()
            Toggle("Reload books changed on disk", isOn: $settings.autoReloadDocumentsEnabled)
            Text(
                "When an open PDF's file changes — a notes app regenerated "
                    + "its export, or iCloud synced a newer version — the "
                    + "book reloads in place and keeps your reading position."
            )
            .settingsCaption()
            Toggle("Margin heading anchors", isOn: $settings.marginAnchorsEnabled)
            Text(
                "Shows a small link glyph in the page margin next to "
                    + "chapters, sections, theorems, and definitions. "
                    + "Clicking it copies a deep link to that spot "
                    + "(⌥-click for a markdown link) and marks it in Back "
                    + "history. Heading detection is heuristic — turn this "
                    + "off if a book's margins get noisy. Applies "
                    + "immediately."
            )
            .settingsCaption()
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section("Memory") {
            Stepper(
                value: $settings.documentCapacity,
                in: AppSettings.documentCapacityRange
            ) {
                LabeledContent(
                    "Open books kept in memory",
                    value: "\(settings.documentCapacity)"
                )
            }
            Text(
                "How many open books stay loaded at once (tabs beyond this "
                    + "reload from disk when you return to them). Books on "
                    + "screen are always kept, whatever the limit. Higher "
                    + "values make switching among many books snappier but "
                    + "hold more memory; lower values keep the app leanest. "
                    + "Shrinking the limit frees memory immediately."
            )
            .settingsCaption()
        }
    }

    // MARK: - Search indexing

    private var indexingSection: some View {
        Section("Library search index") {
            Toggle(
                "Index book text in the background",
                isOn: $settings.backgroundIndexingEnabled
            )
            Toggle("Read scanned books with OCR", isOn: $settings.ocrIndexingEnabled)
                .disabled(!settings.backgroundIndexingEnabled)
            Text(
                "Indexing makes “Search All Books” find text inside your "
                    + "PDFs. It runs quietly after the library loads, only "
                    + "touches files already on this Mac (it never downloads "
                    + "from iCloud), and skips books it has seen before. OCR "
                    + "additionally reads pages that have no text layer — "
                    + "scanned books — at some extra CPU cost during indexing."
            )
            .settingsCaption()
        }
    }

    // MARK: - Calibre

    private var calibreSection: some View {
        Section("Calibre library") {
            LabeledContent("Folder") {
                Text(calibreFolderDescription)
                    .foregroundStyle(library.calibreRoot == nil ? .secondary : .primary)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }
            HStack {
                Button("Change…") { library.chooseCalibreFolder() }
                if library.calibreRoot != nil {
                    Button("Detach", role: .destructive) {
                        library.detachCalibreFolder()
                    }
                }
            }
            Text(
                "The app reads your Calibre library and never writes to it. "
                    + "Detaching removes Calibre books from the app's library "
                    + "view; your Calibre folder and imported PDFs are untouched."
            )
            .settingsCaption()
        }
    }

    // MARK: - Watched folders

    private var watchedFoldersSection: some View {
        Section("Watched folders") {
            ForEach(library.watchedFolders, id: \.path) { folder in
                HStack {
                    Text(abbreviateHome(folder.path))
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Spacer()
                    Button("Remove") { library.removeWatchedFolder(folder) }
                }
            }
            Button("Add Folder…") { library.chooseWatchedFolder() }
            Text(
                "Every PDF in a watched folder (subfolders included) is "
                    + "imported and kept in sync: new files appear in the "
                    + "library, regenerated files keep their tags and "
                    + "reading position, and deleted files drop out. Built "
                    + "for auto-exported note folders — e.g. a reMarkable "
                    + "or GoodNotes iCloud folder. Removing a watched folder "
                    + "removes its books from the library; the files are "
                    + "never touched."
            )
            .settingsCaption()
        }
    }

    private var calibreFolderDescription: String {
        guard let root = library.calibreRoot else { return "No Calibre library attached" }
        return abbreviateHome(root.path)
    }

    /// `/Users/me/…` → `~/…` for display.
    private func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - iCloud sync

    @ViewBuilder
    private var syncSection: some View {
        let sync = SyncCoordinator.shared
        Section("iCloud sync") {
            Toggle("Sync library between devices", isOn: $settings.syncEnabled)
            LabeledContent("Status") {
                Text(syncStatusDescription)
                    .foregroundStyle(.secondary)
            }
            if sync.status.isSyncable {
                Button("Sync Now") { sync.syncNow() }
                    .disabled(sync.status == .syncing)
            }
            Text(
                "Syncs tags, collections, bookmarks, and reading positions "
                    + "across your Macs and devices through your private "
                    + "iCloud — never the files themselves, and never "
                    + "Calibre's own data. Newest change wins when two "
                    + "devices disagree."
            )
            .settingsCaption()
        }
    }

    private var syncStatusDescription: String {
        switch SyncCoordinator.shared.status {
        case .disabled:
            return "Off"
        case .unavailable(let reason):
            return reason
        case .syncing:
            return "Syncing…"
        case .error(let detail):
            return "Error: \(detail)"
        case .idle(let lastSync):
            guard let lastSync else { return "Ready" }
            return "Last synced \(lastSync.formatted(date: .omitted, time: .shortened))"
        }
    }

    // MARK: - Default PDF viewer

    private var defaultViewerSection: some View {
        Section("Default PDF viewer") {
            if isDefaultViewer {
                LabeledContent("Status") {
                    Text("Bluefold opens PDFs by default")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Set Bluefold as Default…") {
                    Task {
                        await DefaultPDFViewer.makeDefault()
                        isDefaultViewer = DefaultPDFViewer.isDefault
                    }
                }
            }
            Text(
                "When Bluefold is the default, PDFs opened from Finder and "
                    + "other apps open here. Undo it anytime from Finder: "
                    + "Get Info on any PDF, pick an app under “Open with”, "
                    + "and click Change All."
            )
            .settingsCaption()
        }
        .onAppear { isDefaultViewer = DefaultPDFViewer.isDefault }
    }

    // MARK: - Keybindings

    private var keybindingsSection: some View {
        Section("Keybindings") {
            Button("Open Keybindings File") {
                // Same command the palette / Help menu run
                // ("prefs.openKeybindings"): creates the documented template
                // on first use, then opens it in your editor.
                Keybindings.openFile()
            }
            Text(
                "Shortcuts are customized in keybindings.json (it opens with "
                    + "a template documenting every command). Changes apply "
                    + "at the next launch. Press / in a reader window for the "
                    + "current shortcut list; the format reference is "
                    + "docs/KEYBINDINGS.md."
            )
            .settingsCaption()
        }
    }

    // MARK: - Deep links

    private var deepLinksSection: some View {
        Section("Deep links") {
            LabeledContent("URL scheme", value: "\(DeepLink.primaryScheme)://")
            Text(
                "Edit > Copy Link to Here (or to Selection) puts a "
                    + "\(DeepLink.primaryScheme)://open?… link on the "
                    + "clipboard. Paste it into notes or anywhere else; "
                    + "opening it jumps to that exact spot, even if the PDF "
                    + "has moved, because links identify books by content."
            )
            .settingsCaption()
        }
    }
}

extension Text {
    /// The explanatory footnote style used under each settings control.
    fileprivate func settingsCaption() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
