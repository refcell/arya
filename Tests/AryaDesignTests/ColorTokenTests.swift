import AppKit
import Testing

@testable import AryaDesign

@MainActor @Suite struct ColorTokenTests {
    @Test func paperAndInkValuesMatchTheGuide() {
        #expect(AryaColorToken.canvas.light.description == "#F6F1E7")
        #expect(AryaColorToken.canvas.dark.description == "#141311")
        #expect(AryaColorToken.accent.light.description == "#B13B0B")
        #expect(AryaColorToken.accent.dark.description == "#F08A4B")
        #expect(AryaColorToken.accentInk.light.description == "#FFFFFF")
        #expect(AryaColorToken.allCases.count == 14)
    }

    @Test(arguments: AryaColorToken.allCases)
    func everyTokenResolvesInBothAppearances(token: AryaColorToken) throws {
        for (name, scheme) in [(NSAppearance.Name.aqua, AryaScheme.paper), (.darkAqua, .ink)] {
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
        #expect(AryaScheme(dark) == .ink)
        let light = try #require(NSAppearance(named: .aqua))
        #expect(AryaScheme(light) == .paper)
    }

    @Test func increaseContrastSubstitutesRulesAndFaintText() {
        let scheme = AryaScheme(isDark: false, isHighContrast: true)
        #expect(AryaColorToken.rule.value(in: scheme) == AryaColorToken.inkFaint.light)
        #expect(AryaColorToken.ruleStrong.value(in: scheme) == AryaColorToken.inkFaint.light)
        #expect(AryaColorToken.inkFaint.value(in: scheme) == AryaColorToken.inkMuted.light)
        #expect(AryaColorToken.ink.value(in: scheme) == AryaColorToken.ink.light)
    }

    /// Every text token on every surface it appears on meets WCAG AA (STYLE.md).
    @Test(arguments: [AryaScheme.paper, .ink])
    func textTokensMeetAAOnSurfaces(scheme: AryaScheme) {
        let surfaces: [AryaColorToken] = [.canvas, .surface, .sunken, .selection, .accentWash]
        let texts: [AryaColorToken] = [.ink, .inkMuted, .inkFaint, .accent, .positive, .negative]
        for text in texts {
            for surface in surfaces where !(surface == .selection && text.isStatus) {
                let ratio = text.value(in: scheme).contrast(with: surface.value(in: scheme))
                #expect(ratio >= 4.5, "\(text) on \(surface): \(ratio)")
            }
        }
        let onAccent = AryaColorToken.accentInk.value(in: scheme)
            .contrast(with: AryaColorToken.accent.value(in: scheme))
        #expect(onAccent >= 4.5)
    }

    @Test func contrastMatchesThePublishedTable() {
        let ratio = AryaColorToken.ink.light.contrast(with: AryaColorToken.canvas.light)
        #expect(abs(ratio - 15.27) < 0.01)
        let accent = AryaColorToken.accent.dark.contrast(with: AryaColorToken.canvas.dark)
        #expect(abs(accent - 7.46) < 0.01)
    }
}

extension AryaColorToken {
    fileprivate var isStatus: Bool { self == .positive || self == .negative }
}
