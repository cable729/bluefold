#if os(macOS)
import AppKit
import Observation
import os
import PDFKit
import ReaderCore
import SwiftUI

/// App-wide theme state, persisted in UserDefaults.
///
/// Window appearance is applied IMPERATIVELY here (`window.appearance` +
/// chrome tint on every registered NSWindow), not via SwiftUI's
/// `.preferredColorScheme`: AppKit only re-applies a scene's preferred
/// color scheme to its own window when that window is key, so a theme
/// change made in one window left every other window's appearance stale
/// until clicked. Iterating the registry updates all windows at once.
@MainActor
@Observable
public final class ThemeManager {
    public static let shared = ThemeManager()

    private static let defaultsKey = "PDFReaderTheme"

    public var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            applyResolvedTheme()
        }
    }

    /// Whether the SYSTEM appearance is dark — tracked independently of any
    /// forced window appearance so `.auto` can resolve against it live.
    public private(set) var systemIsDark: Bool {
        didSet { applyResolvedTheme() }
    }

    /// `current` with `.auto` resolved against the live system appearance.
    /// Everything that renders (page filter, PDF background, chrome tint,
    /// the `.id()` keying that rebuilds PDFViews) keys off this.
    public var resolvedTheme: AppTheme {
        current.resolved(systemIsDark: systemIsDark)
    }

    /// Windows whose chrome this manager tints (reader + library).
    @ObservationIgnored private let windows = NSHashTable<NSWindow>.weakObjects()
    @ObservationIgnored private nonisolated(unsafe) var appearanceObserver: NSObjectProtocol?

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        current = stored.flatMap(AppTheme.init(rawValue:)) ?? .light
        systemIsDark = Self.systemAppearanceIsDark()
        PageFilterStore.current = current.resolved(systemIsDark: systemIsDark).pageRenderFilter

        // System light/dark flip. We never force NSApp.appearance (only
        // per-window), so NSApp.effectiveAppearance keeps tracking the
        // system even while a window is forced to another appearance.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            // The notification can land before NSApp.effectiveAppearance
            // flips; read it after the current runloop turn settles.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.systemIsDark = Self.systemAppearanceIsDark()
                }
            }
        }
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    /// PDFView letterbox background per theme.
    public var pdfBackground: NSColor {
        switch resolvedTheme {
        case .light, .auto: .windowBackgroundColor
        case .dark: NSColor(calibratedWhite: 0.12, alpha: 1)
        case .sepia: NSColor(cgColor: Theme.sepiaPaper) ?? .white
        }
    }

    /// Starts tinting `window`'s chrome with the theme (weakly held).
    public func register(_ window: NSWindow) {
        windows.add(window)
        applyChrome(to: window)
    }

    /// Internal for tests: force the tracked system appearance.
    func overrideSystemAppearance(isDark: Bool) {
        systemIsDark = isDark
    }

    private static func systemAppearanceIsDark() -> Bool {
        NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func applyResolvedTheme() {
        PageFilterStore.current = resolvedTheme.pageRenderFilter
        for window in windows.allObjects {
            applyChrome(to: window)
        }
    }

    private func applyChrome(to window: NSWindow) {
        // `.auto` inherits (nil) so the window follows future system flips
        // even if our distributed-notification observer lags.
        window.appearance = switch current {
        case .auto: nil
        case .light, .sepia: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        switch resolvedTheme {
        case .sepia:
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(cgColor: Theme.sepiaPaper) ?? .windowBackgroundColor
        case .light, .dark, .auto:
            window.titlebarAppearsTransparent = false
            window.backgroundColor = .windowBackgroundColor
        }
    }
}

/// Registers the hosting NSWindow with `ThemeManager` so its chrome tints
/// with the theme. For windows (like the library) that don't need the full
/// reader-window policy of `WindowAccessor`.
struct ThemeChromeAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> RegisteringView {
        RegisteringView()
    }

    func updateNSView(_ view: RegisteringView, context: Context) {}

    @MainActor
    final class RegisteringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            ThemeManager.shared.register(window)
        }
    }
}

// Theme (sepia color), PageFilterStore, ThemedPDFPage, and PageClassProvider
// moved to PageTheming.swift — they are cross-platform and shared with iOS.
#endif
