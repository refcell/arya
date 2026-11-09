import AppKit
import Testing

@testable import AryaDesign

@MainActor @Suite struct ColorTokenTests {
    @Test func darkAndLightValuesMatchTheGuide() {
        #expect(AryaColorToken.canvas.dark.description == "#0C0C0D")
        #expect(AryaColorToken.raised.dark.description == "#141416")
        #expect(AryaColorToken.ink.dark.description == "#F4F4F5")
        #expect(AryaColorToken.accent.dark.description == "#F97316")
        #expect(AryaColorToken.canvas.light.description == "#FAFAFA")
        #expect(AryaColorToken.accent.light.description == "#B4390A")
        #expect(AryaColorToken.allCases.count == 16)
    }

    @Test func theAppearanceDefaultsToDark() {
        #expect(AryaAppearance(stored: nil) == .dark)
        #expect(AryaAppearance(stored: "sepia") == .dark)
        #expect(AryaAppearance(stored: "light") == .light)
        #expect(AryaAppearance.dark.nsAppearanceName == .darkAqua)
    }

    @Test(arguments: AryaColorToken.allCases)
    func everyTokenResolvesInBothAppearances(token: AryaColorToken) throws {
        for (name, scheme) in [(NSAppearance.Name.aqua, AryaScheme.light), (.darkAqua, .dark)] {
            let appearance = try #require(NSAppearance(named: name))
            var resolved: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                resolved = token.nsColor.usingColorSpace(.sRGB)
            }
            let color = try #require(resolved)
            let (red, green, blue) = token.value(in: scheme).components
            #expect(abs(color.redComponent - red) < 0.002)
            #expect(abs(color.greenComponent - green) < 0.002)
            #expect(abs(color.blueComponent - blue) < 0.002)
        }
    }

    @Test func schemeFollowsAppearance() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(AryaScheme(dark) == .dark)
        let light = try #require(NSAppearance(named: .aqua))
        #expect(AryaScheme(light) == .light)
    }

    @Test func increaseContrastSubstitutesRulesAndFaintText() {
        let scheme = AryaScheme(isDark: false, isHighContrast: true)
        #expect(AryaColorToken.rule.value(in: scheme) == AryaColorToken.inkFaint.light)
        #expect(AryaColorToken.ruleStrong.value(in: scheme) == AryaColorToken.inkFaint.light)
        #expect(AryaColorToken.inkFaint.value(in: scheme) == AryaColorToken.inkMuted.light)
        #expect(AryaColorToken.ink.value(in: scheme) == AryaColorToken.ink.light)
    }

    /// Every text token on every surface it appears on meets WCAG AA (STYLE.md).
    @Test(arguments: [AryaScheme.dark, .light])
    func textTokensMeetAAOnSurfaces(scheme: AryaScheme) {
        let surfaces: [AryaColorToken] = [.canvas, .raised, .selection]
        let texts: [AryaColorToken] = [
            .ink, .inkMuted, .inkFaint, .accent, .positive, .negative, .warning,
        ]
        for text in texts {
            for surface in surfaces {
                let ratio = text.value(in: scheme).contrast(with: surface.value(in: scheme))
                #expect(ratio >= 4.5, "\(text) on \(surface): \(ratio)")
            }
        }
        let fills: [(AryaColorToken, AryaColorToken)] = [
            (.accentInk, .accentFill), (.ink, .positiveWash), (.ink, .negativeWash),
            (.positive, .positiveWash), (.negative, .negativeWash), (.canvas, .ink),
        ]
        for (text, fill) in fills {
            let ratio = text.value(in: scheme).contrast(with: fill.value(in: scheme))
            #expect(ratio >= 4.5, "\(text) on \(fill): \(ratio)")
        }
    }

    @Test func contrastMatchesThePublishedTable() {
        let ratio = AryaColorToken.ink.dark.contrast(with: AryaColorToken.canvas.dark)
        #expect(abs(ratio - 17.79) < 0.01)
        let accent = AryaColorToken.accent.light.contrast(with: AryaColorToken.canvas.light)
        #expect(abs(accent - 5.70) < 0.01)
    }
}
