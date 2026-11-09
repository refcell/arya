import SwiftUI
import Testing

@testable import AryaDesign

@MainActor @Suite struct TypeAndSpaceTokenTests {
    @Test func typeScaleMatchesTheGuide() {
        let sizes = AryaFont.all.map { "\($0.name) \($0.size)/\(Int($0.lineHeight))" }
        #expect(
            sizes == [
                "title 20.0/26", "heading 13.0/19", "body 13.0/19", "bodyStrong 13.0/19",
                "caption 11.0/16", "label 10.5/14", "mono 12.0/17", "monoStrong 12.0/17",
                "monoSmall 11.0/15", "metric 20.0/24",
            ])
        #expect(AryaFont.label.uppercase && AryaFont.label.tracking == 0.6)
        // Prose breathes at about 1.45 line height.
        #expect(abs(AryaFont.body.lineHeight / AryaFont.body.size - 1.46) < 0.02)
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
        #expect(style.nsFont(scale: 1.5).pointSize == 19.5)
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
