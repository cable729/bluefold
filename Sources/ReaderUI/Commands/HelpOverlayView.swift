#if os(macOS)
import SwiftUI

/// "/" or "?" — HUD listing every command and its shortcuts, grouped by
/// category and rendered straight from the command table so it can never
/// drift from the menus or palettes. docs/KEYBINDINGS.md mirrors this.
struct HelpOverlayView: View {
    let ui: ReaderWindowUIState
    unowned let model: ReaderWindowModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            panel
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if !CommandRegistry.keybindingsIssues.isEmpty {
                        keybindingsIssuesBanner
                    }
                    ForEach(CommandCategory.allCases, id: \.self) { category in
                        let commands = CommandRegistry.all.filter { $0.category == category }
                        if !commands.isEmpty {
                            section(category, commands)
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 460)

            Divider()

            Text("Press / or ? to toggle this overlay — Esc closes it")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    /// Shown when keybindings.json had problems at launch — the shortcuts
    /// listed below are what actually applied.
    private var keybindingsIssuesBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("keybindings.json — some entries were not applied", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(CommandRegistry.keybindingsIssues, id: \.self) { issue in
                Text(issue)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text("Fix via “Preferences: Open Keybindings File” in the command palette, then relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ category: CommandCategory, _ commands: [ReaderCommand]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(commands) { command in
                HStack(alignment: .firstTextBaseline) {
                    Text(command.title)
                        .font(.system(size: 13))
                    Spacer(minLength: 16)
                    if command.chords.isEmpty {
                        Text("via Command Palette")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(command.chords.map(\.display).joined(separator: "  or  "))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func close() {
        ui.showHelp = false
        model.focusActivePDFView()
    }
}
#endif
