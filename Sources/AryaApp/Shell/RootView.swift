import AryaDesign
import SwiftUI

/// The window content on one canvas: the sidebar, a hairline, the page, and the inspector
/// behind another hairline when open (STYLE.md Layout). Starts the live updates.
struct RootView: View {
    let model: AppModel
    /// The "now" for relative times; the app passes the clock, previews pass a fixed date.
    var now: () -> Date = Date.init
    @AryaState private var railWidth = AryaSize.railWidth
    @AryaState private var dragStart: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RailView(model: model, now: now())
                HStack {
                    Button {
                        model.navigation.inspector.toggle()
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 13))
                    }
                    .buttonStyle(.aryaTertiary)
                    .accessibilityLabel("Settings")
                    .help("Settings (Option-Command-I)")
                    Spacer()
                }
                .padding(AryaSpace.s2)
            }
            .frame(width: railWidth)
            AryaHairline(.vertical)
                .overlay { resizeHandle }
            MainPane(model: model)
            if model.navigation.inspector {
                AryaHairline(.vertical)
                InspectorView(model: model, now: now())
            }
        }
        .ignoresSafeArea(.container, edges: .top)
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
