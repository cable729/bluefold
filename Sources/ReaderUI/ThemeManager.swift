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
///
/// The forced appearance is also ENFORCED, not just applied: SwiftUI's
/// scene machinery resets `window.appearance` to nil during its own
/// update passes (observed on macOS 26 — every window of a sepia-themed
/// running app had appearance nil after an overnight system dark flip,
/// leaving dark chrome over sepia pages). Nil is indistinguishable from
/// forced-aqua while the system is light, so the clobber only becomes
/// visible when the system appearance changes. Each registered window
/// gets a KVO observer that re-applies chrome whenever its appearance
/// drifts from what the theme demands.
@MainActor
@Observable
public final class ThemeManager {
    public static let shared = ThemeManager()

    private static let defaultsKey = "BluefoldTheme"
    private static let lastLightKey = "BluefoldLastLightTheme"
    private static let lastDarkKey = "BluefoldLastDarkTheme"

    public var current: AppTheme {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
            rememberFamilyChoice(current)
            applyResolvedTheme()
        }
    }

    /// The last concrete LIGHT- and DARK-family themes the user picked. `.auto`
    /// resolves to these (light one by day, dark one by night) instead of the
    /// plain `.light`/`.dark` defaults — so choosing Sepia then Nord then Auto
    /// gives Sepia days and Nord nights. Persisted; seeded from the two
    /// built-in defaults on first run.
    public private(set) var lastLightTheme: AppTheme {
        didSet { UserDefaults.standard.set(lastLightTheme.rawValue, forKey: Self.lastLightKey) }
    }
    public private(set) var lastDarkTheme: AppTheme {
        didSet { UserDefaults.standard.set(lastDarkTheme.rawValue, forKey: Self.lastDarkKey) }
    }

    /// Whether the SYSTEM appearance is dark — tracked independently of any
    /// forced window appearance so `.auto` can resolve against it live.
    public private(set) var systemIsDark: Bool {
        didSet { applyResolvedTheme() }
    }

    /// `current` with `.auto` resolved against the live system appearance and
    /// the remembered per-family choices. Everything that renders (page
    /// filter, PDF background, chrome tint, the `.id()` keying that rebuilds
    /// PDFViews) keys off this.
    public var resolvedTheme: AppTheme {
        current.resolved(
            systemIsDark: systemIsDark, lastLight: lastLightTheme, lastDark: lastDarkTheme
        )
    }

    /// Records a concrete pick as its family's remembered theme (so `.auto`
    /// tracks it). `.auto` itself is not a family choice.
    private func rememberFamilyChoice(_ theme: AppTheme) {
        guard theme != .auto else { return }
        if theme.isDark {
            if lastDarkTheme != theme { lastDarkTheme = theme }
        } else if lastLightTheme != theme {
            lastLightTheme = theme
        }
    }

    /// Windows whose chrome this manager tints (reader + library).
    @ObservationIgnored private let windows = NSHashTable<NSWindow>.weakObjects()
    /// Per-window KVO re-applying chrome when `window.appearance` is reset
    /// behind our back (weak keys: entries die with their windows, and the
    /// observation auto-invalidates when its window deallocates).
    @ObservationIgnored private let chromeEnforcers =
        NSMapTable<NSWindow, NSKeyValueObservation>.weakToStrongObjects()
    @ObservationIgnored private var systemAppearanceObservation: NSKeyValueObservation?

    public init() {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: Self.defaultsKey)
        let initial = stored.flatMap(AppTheme.init(rawValue:)) ?? .light
        current = initial
        // Remembered per-family choices; fall back to the built-in defaults,
        // and to the stored theme itself when it's concrete (so first-run
        // Auto after a fresh install still follows a real prior pick).
        let storedLight = defaults.string(forKey: Self.lastLightKey).flatMap(AppTheme.init(rawValue:))
        let storedDark = defaults.string(forKey: Self.lastDarkKey).flatMap(AppTheme.init(rawValue:))
        lastLightTheme = storedLight ?? (!initial.isDark && initial != .auto ? initial : .light)
        lastDarkTheme = storedDark ?? (initial.isDark ? initial : .dark)
        systemIsDark = Self.systemAppearanceIsDark()
        PageFilterStore.current = initial.resolved(
            systemIsDark: Self.systemAppearanceIsDark(),
            lastLight: lastLightTheme, lastDark: lastDarkTheme
        ).pageRenderFilter

        // System light/dark flip. We never force NSApp.appearance (only
        // per-window), so NSApp.effectiveAppearance keeps tracking the
        // system even while a window is forced to another appearance.
        // KVO, not AppleInterfaceThemeChangedNotification: the distributed
        // notification is delivered through a daemon, so it can be dropped
        // while the app naps through an overnight auto-switch, and even
        // when it arrives it races the NSApp.effectiveAppearance flip. KVO
        // is in-process and fires with the value already committed.
        systemAppearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isDark = Self.systemAppearanceIsDark()
                if self.systemIsDark != isDark { self.systemIsDark = isDark }
            }
        }
    }

    /// PDFView letterbox background per theme (the design system's content
    /// background, so the letterbox reads as the page's paper mat).
    public var pdfBackground: NSColor {
        DesignPalette.palette(for: resolvedTheme).contentBackground
    }

    /// Secondary color for the current theme — recolors the PDF's own link
    /// boxes (see `LinkBoxColorizer`).
    public var linkBox: NSColor {
        DesignPalette.palette(for: resolvedTheme).linkBox
    }

    /// Starts tinting `window`'s chrome with the theme (weakly held).
    public func register(_ window: NSWindow) {
        windows.add(window)
        if chromeEnforcers.object(forKey: window) == nil {
            chromeEnforcers.setObject(
                window.observe(\.appearance) { [weak self] window, _ in
                    nonisolated(unsafe) let window = window
                    MainActor.assumeIsolated { self?.enforceChrome(on: window) }
                },
                forKey: window
            )
        }
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

    /// The `window.appearance` the theme demands — nil for `.auto`, which
    /// inherits so the window follows system flips on its own.
    private var forcedAppearanceName: NSAppearance.Name? {
        // `.auto` inherits the system appearance; every concrete theme forces
        // its family's chrome (light-family → aqua, dark-family → darkAqua).
        current == .auto ? nil : (current.isDark ? .darkAqua : .aqua)
    }

    /// KVO target: restores chrome when something else (SwiftUI scene
    /// updates) rewrote `window.appearance`. The drift check is also the
    /// re-entrancy guard — applyChrome sets appearance, which fires the
    /// same observer, which then matches and returns.
    private func enforceChrome(on window: NSWindow) {
        guard window.appearance?.name != forcedAppearanceName else { return }
        applyChrome(to: window)
    }

    private func applyChrome(to window: NSWindow) {
        window.appearance = forcedAppearanceName.flatMap(NSAppearance.init(named:))
        // Cloth & Paper chrome: every theme paints the titlebar band with
        // its warm paper (or navy) chrome color; the window background is
        // what shows through the transparent titlebar.
        let palette = DesignPalette.palette(for: resolvedTheme)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = palette.chromeTop
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
