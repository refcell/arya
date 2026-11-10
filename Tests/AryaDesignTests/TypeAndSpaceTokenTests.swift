import SwiftUI
import Testing

@testable import AryaDesign

@MainActor @Suite struct TypeAndSpaceTokenTests {
    @Test func typeScaleMatchesTheGuide() {
        let sizes = AryaFont.all.map { "\($0.name) \($0.size)/\(Int($0.lineHeight))" }
        #expect(
            sizes == [
                "title 15.0/20", "heading 12.0/16", "body 12.0/16", "prose 12.0/17",
                "bodyStrong 12.0/16", "caption 11.0/15", "label 9.5/12", "mono 11.0/15",
                "monoStrong 11.0/15", "monoSmall 10.5/14", "metric 16.0/20",
            ])
        #expect(AryaFont.label.uppercase && AryaFont.label.tracking == 0.6)
        // Lists sit at about 1.35 line height; prose breathes at about 1.45.
        #expect(abs(AryaFont.body.lineHeight / AryaFont.body.size - 1.35) < 0.02)
        #expect(abs(AryaFont.prose.lineHeight / AryaFont.prose.size - 1.46) < 0.02)
        #expect(
            AryaFont.all.filter { $0.face == .mono }.map(\.name) == [
                "mono", "monoStrong", "monoSmall", "metric",
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
        #expect(style.nsFont(scale: 1.5).pointSize == 18)
        #expect(style.naturalLineHeight(scale: 2) > style.naturalLineHeight())
    }

    @Test func spacingIsOnTheFourPointGrid() {
        #expect(AryaSpace.all == [4, 8, 12, 16, 20, 24, 32])
        let sizes: [CGFloat] = [
            AryaSize.sidebarWidth, AryaSize.inspectorWidth, AryaSize.rowHeight,
            AryaSize.tabBarHeight, AryaSize.titleBarInset, AryaSize.pagePadding,
            AryaSize.readingWidth, AryaSize.stepGutter, AryaRadius.small,
        ]
        #expect(sizes.allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
        #expect(AryaSize.rowHeight >= 22 && AryaSize.rowHeight <= 26)
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
