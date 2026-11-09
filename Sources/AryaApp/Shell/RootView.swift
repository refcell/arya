import AryaDesign
import SwiftUI

/// The window content: the rail, a hairline, and the main pane. Starts the live updates.
struct RootView: View {
    let model: AppModel
    /// The "now" for relative times; the app passes the clock, previews pass a fixed date.
    var now: () -> Date = Date.init
    @AryaState private var railWidth = AryaSize.railWidth
    @AryaState private var dragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            RailView(model: model, now: now()).frame(width: railWidth)
            AryaHairline(.vertical)
                .overlay { resizeHandle }
            MainPane(model: model)
        }
        .frame(minWidth: AryaSize.windowMinWidth, minHeight: AryaSize.windowMinHeight)
        .background(AryaColor.canvas)
        .task {
            await model.refresh()
            await model.watch()
        }
        .task { await model.featureStore?.observe() }
    }

    /// An invisible 8 pt grip over the hairline that resizes the rail within 200–320 pt.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: AryaSpace.s2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? railWidth
                        dragStart = start
                        railWidth = RailWidth.clamp(start + value.translation.width)
                    }
                    .onEnded { _ in dragStart = nil })
    }
}
