import Foundation
import Testing

@testable import ReaderCore

@Suite struct ThemeResolutionTests {
    @Test func autoResolvesPerSystemAppearance() {
        #expect(AppTheme.auto.resolved(systemIsDark: false) == .light)
        #expect(AppTheme.auto.resolved(systemIsDark: true) == .dark)
    }

    @Test func concreteThemesIgnoreSystemAppearance() {
        for isDark in [false, true] {
            #expect(AppTheme.light.resolved(systemIsDark: isDark) == .light)
            #expect(AppTheme.dark.resolved(systemIsDark: isDark) == .dark)
            #expect(AppTheme.sepia.resolved(systemIsDark: isDark) == .sepia)
        }
    }

    @Test func resolvedThemeIsNeverAuto() {
        for theme in AppTheme.allCases {
            for isDark in [false, true] {
                #expect(theme.resolved(systemIsDark: isDark) != .auto)
            }
        }
    }

    @Test func resolvedAutoPageFilterFollowsAppearance() {
        #expect(AppTheme.auto.resolved(systemIsDark: false).pageRenderFilter == .none)
        #expect(AppTheme.auto.resolved(systemIsDark: true).pageRenderFilter == .invert)
    }

    /// Raw values are persisted in UserDefaults and session.json —
    /// this pins them so a rename can't silently break restores.
    @Test func rawValuesAreStable() {
        #expect(AppTheme.light.rawValue == "light")
        #expect(AppTheme.dark.rawValue == "dark")
        #expect(AppTheme.sepia.rawValue == "sepia")
        #expect(AppTheme.auto.rawValue == "auto")
        for raw in ["light", "dark", "sepia", "auto"] {
            #expect(AppTheme(rawValue: raw) != nil)
        }
    }
}
