import SwiftUI
import Testing

@testable import AryaDesign

@MainActor @Suite struct TypeAndSpaceTokenTests {
    @Test func typeScaleMatchesTheGuide() {
        let sizes = AryaFont.all.map { "\($0.name) \(Int($0.size))/\(Int($0.lineHeight))" }
        #expect(
            sizes == [
                "display 30/36", "title 22/28", "heading 17/22", "body 13/19", "bodyStrong 13/19",
                "caption 11/15", "overline 10/14", "mono 12/18", "monoSmall 11/16",
            ])
        #expect(AryaFont.overline.uppercase && AryaFont.overline.tracking == 0.8)
        #expect(
            AryaFont.all.filter { $0.face == .serif }.map(\.name) == [
                "display", "title", "heading",
            ])
    }

    @Test(arguments: AryaFont.all)
    func lineSpacingFillsToTheLineHeight(style: AryaTextStyle) {
        let natural = style.naturalLineHeight()
        #expect(natural > 0)
        #expect(abs(natural + style.lineSpacing() - max(style.lineHeight, natural)) < 0.001)
        #expect(style.nsFont().pointSize == style.size)
    }

    @Test func tokensScaleTogether() {
        let style = AryaFont.body
        #expect(style.nsFont(scale: 1.5).pointSize == 19.5)
        #expect(style.naturalLineHeight(scale: 2) > style.naturalLineHeight())
    }

    @Test func spacingIsOnTheFourPointGrid() {
        #expect(AryaSpace.all == [4, 8, 12, 16, 24, 32, 48])
        let sizes: [CGFloat] = [
            AryaSize.railWidth, AryaSize.railRowHeight, AryaSize.tableRowHeight,
            AryaSize.controlHeight, AryaSize.tabBarHeight, AryaSize.stepGutter,
            AryaSize.readingWidth, AryaRadius.small,
        ]
        #expect(sizes.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
        #expect(AryaRadius.medium == 6)
    }

    @Test func hairlineIsOneDevicePixel() {
        #expect(AryaHairline.thickness(displayScale: 2) == 0.5)
        #expect(AryaHairline.thickness(displayScale: 1) == 1)
        #expect(AryaHairline.thickness(displayScale: 0) == 1)
    }

    @Test func reduceMotionDisablesAnimation() {
        #expect(AryaMotion.appear(reduceMotion: true) == nil)
        #expect(AryaMotion.expand(reduceMotion: true) == nil)
        #expect(AryaMotion.pulse(reduceMotion: true) == nil)
        #expect(AryaMotion.appear(reduceMotion: false) != nil)
    }
}
