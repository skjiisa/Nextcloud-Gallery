//
//  TabBarView.swift
//  Nextcloud Gallery
//
//  The persistent bottom chrome for the tabbed gallery: open a new tab, jump to
//  the switcher, reach Settings — and swipe sideways to flip between tabs. Hosted
//  as a bottom safe-area inset so it stays put across a tab's drill-downs.
//

import SwiftUI

struct TabBarView: View {
    @Environment(TabsModel.self) private var tabs
    @Environment(AppEnvironment.self) private var environment

    /// Opens the Settings sheet, owned by the container.
    let onShowSettings: () -> Void

    /// Horizontal travel before a bar swipe commits to the previous/next tab.
    private let swipeThreshold: CGFloat = 60

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
                    Text(tabs.activeTab.title)
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

            Button(action: onShowSettings) {
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
        // Swipe the bar left/right to move between adjacent tabs (Safari-style),
        // which never fights the back-swipe or the grids' vertical scrolling.
        // High-priority so a horizontal drag beats the center button's tap; a
        // plain tap (no movement) still falls through to the buttons.
        .highPriorityGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > swipeThreshold else { return }
                    tabs.selectRelative(value.translation.width < 0 ? 1 : -1)
                }
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
