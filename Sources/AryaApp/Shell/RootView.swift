import AryaDesign
import SwiftUI

/// The window content on one canvas: the sidebar, a hairline, the page, and the inspector
/// behind another hairline when open (STYLE.md Layout). Starts the live updates.
struct RootView: View {
    let model: AppModel
    /// The "now" for relative times; the app passes the clock, previews pass a fixed date.
    var now: () -> Date = Date.init
    @AryaState private var railWidth = AryaSize.railWidth
    /// The features' clock when a store is wired, so the status bar, inspector, and NOW
    /// read one time.
    private var clock: Date { model.featureStore?.now ?? now() }
    @AryaState private var dragStart: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            zones
            StatusBar(model: model, now: clock)
        }
        .overlay(alignment: .top) {
            if model.paletteOpen {
                CommandPaletteView(model: model)
                    .padding(.top, AryaSize.trafficLightInset + AryaSpace.s7)
                    .transition(.opacity.combined(with: .offset(y: -AryaSpace.s2)))
            }
        }
        .animation(AryaMotion.panel, value: model.paletteOpen)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: AryaSize.windowMinWidth, minHeight: AryaSize.windowMinHeight)
        .background(AryaColor.canvas)
        .task {
            await model.refresh()
            await model.watch()
        }
        .task { await model.featureStore?.observe() }
    }

    /// Sidebar | stream | inspector, hairline-separated on one canvas.
    private var zones: some View {
        HStack(spacing: 0) {
            if model.navigation.sidebar {
                sidebar
                AryaHairline(.vertical)
                    .overlay { resizeHandle }
            }
            // With the sidebar hidden the traffic lights sit over the stream.
            MainPane(model: model)
                .padding(
                    .top,
                    model.navigation.sidebar
                        ? 0 : AryaSize.trafficLightInset - AryaSize.titleBarInset)
            if model.navigation.inspector {
                AryaHairline(.vertical)
                InspectorView(model: model, now: clock)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(AryaMotion.panel, value: model.navigation.inspector)
        .animation(AryaMotion.panel, value: model.navigation.sidebar)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            RailView(model: model, now: now())
            HStack {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(AryaIconButtonStyle())
                .accessibilityLabel("Settings")
                .help("Settings (Command-comma)")
                Spacer()
            }
            .padding(AryaSpace.s2)
        }
        .frame(width: railWidth)
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
