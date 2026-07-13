import Foundation
import Testing

@testable import ReaderCore

@Suite struct ThemeResolutionTests {
    @Test func autoResolvesPerSystemAppearance() {
        #expect(AppTheme.auto.resolved(systemIsDark: false) == .light)
        #expect(AppTheme.auto.resolved(systemIsDark: true) == .dark)
    }

    /// `.auto` follows the remembered per-family picks: the last light theme
    /// by day, the last dark theme by night. Concrete themes ignore both.
    @Test func autoResolvesToRememberedFamilyThemes() {
        #expect(
            AppTheme.auto.resolved(systemIsDark: false, lastLight: .sepia, lastDark: .nord)
                == .sepia
        )
        #expect(
            AppTheme.auto.resolved(systemIsDark: true, lastLight: .sepia, lastDark: .nord)
                == .nord
        )
        // A concrete theme is itself regardless of the remembered pair.
        #expect(
            AppTheme.dracula.resolved(systemIsDark: false, lastLight: .sepia, lastDark: .nord)
                == .dracula
        )
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
        #expect(AppTheme.solarizedLight.rawValue == "solarizedLight")
        #expect(AppTheme.solarizedDark.rawValue == "solarizedDark")
        #expect(AppTheme.nord.rawValue == "nord")
        #expect(AppTheme.gruvbox.rawValue == "gruvbox")
        #expect(AppTheme.dracula.rawValue == "dracula")
        #expect(AppTheme.bluefold.rawValue == "bluefold")
        #expect(AppTheme.foldblue.rawValue == "foldblue")
        #expect(AppTheme.gruvboxLight.rawValue == "gruvboxLight")
        for raw in [
            "light", "dark", "sepia", "auto", "solarizedLight",
            "solarizedDark", "nord", "gruvbox", "dracula", "bluefold", "foldblue",
            "gruvboxLight",
        ] {
            #expect(AppTheme(rawValue: raw) != nil)
        }
    }

    /// Chrome family drives the forced window appearance — light-family
    /// themes must never claim to be dark, and vice-versa.
    @Test func darkFamilyThemesReportDark() {
        for theme in [AppTheme.dark, .solarizedDark, .nord, .gruvbox, .dracula, .bluefold] {
            #expect(theme.isDark)
        }
        for theme in [AppTheme.light, .sepia, .foldblue, .solarizedLight, .gruvboxLight] {
            #expect(!theme.isDark)
        }
    }

    /// Every concrete theme appears in exactly one family list, and `.auto`
    /// in neither (it's offered separately as the recommended default).
    @Test func familyListsPartitionConcreteThemes() {
        let light = Set(AppTheme.lightFamily)
        let dark = Set(AppTheme.darkFamily)
        #expect(light.isDisjoint(with: dark))
        #expect(!light.contains(.auto) && !dark.contains(.auto))
        for theme in AppTheme.allCases where theme != .auto {
            #expect(light.contains(theme) != dark.contains(theme))
            #expect(dark.contains(theme) == theme.isDark)
        }
    }

    /// Every concrete theme resolves to a filter matching its family: light
    /// pages multiply a tint (or none), dark pages invert (tinted or not).
    @Test func pageFilterMatchesThemeFamily() {
        for theme in AppTheme.allCases where theme != .auto {
            switch theme.pageRenderFilter {
            case .none, .multiply:
                #expect(!theme.isDark, "\(theme) has a light-family filter")
            case .invert, .invertTinted:
                #expect(theme.isDark, "\(theme) has a dark-family filter")
            }
        }
    }
}
