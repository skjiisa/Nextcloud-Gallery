//
//  TabBarView.swift
//  Nextcloud Gallery
//
//  One tab's bottom chrome: open a new tab, jump to the switcher, reach Settings.
//  Each tab owns its own bar (they ride along in the carousel), and dragging a bar
//  sideways drives the carousel between tabs — so you drag this tab's bar away and
//  the neighbour's bar slides in behind it.
//

import SwiftUI

struct TabBarView: View {
    @Environment(TabsModel.self) private var tabs
    @Environment(AppEnvironment.self) private var environment
    @Environment(CarouselDrag.self) private var drag
    /// The tab this bar belongs to — names the bar and is the page that slides.
    @Environment(BrowseTab.self) private var tab

    private var isWarming: Bool {
        environment.warmingCoordinator?.state == .warming
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                tabs.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("New Tab")

            Spacer(minLength: 0)

            Button {
                tabs.openSwitcher()
            } label: {
                HStack(spacing: 6) {
                    if isWarming {
                        ProgressView().controlSize(.small)
                    }
                    Text(tab.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    tabCountBadge
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show Tabs, \(tabs.tabs.count) open")

            Spacer(minLength: 0)

            Button {
                tabs.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        // Drag the bar to carousel between tabs. High-priority so a horizontal
        // drag beats the buttons' taps; a tap (no movement) still hits the buttons.
        //
        // Measured in GLOBAL space on purpose: the bar itself rides the carousel's
        // `offset`, so a local-space translation would be polluted by the bar's own
        // movement — feeding back into the offset and oscillating between two
        // positions every frame. Global space is the fixed screen, so translation
        // is pure finger movement.
        .highPriorityGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { drag.changed($0.translation.width) }
                .onEnded { drag.ended($0.translation.width) }
        )
    }

    private var tabCountBadge: some View {
        Text("\(tabs.tabs.count)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .frame(minWidth: 20, minHeight: 20)
            .background(.tertiary, in: .rect(cornerRadius: 6))
    }
}
