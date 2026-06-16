//
//  TabSwitcherView.swift
//  Nextcloud Gallery
//
//  The Safari-style overview: every open tab as a card showing a thumbnail of
//  where it's parked. Tap to switch, ✕ to close, + for a new tab.
//

import SwiftUI

struct TabSwitcherView: View {
    @Environment(TabsModel.self) private var tabs

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(tabs.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isActive: tab.id == tabs.activeTabID,
                            onSelect: {
                                tabs.select(tab.id)
                                tabs.isShowingSwitcher = false
                            },
                            onClose: { tabs.closeTab(tab.id) }
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("\(tabs.tabs.count) \(tabs.tabs.count == 1 ? "Tab" : "Tabs")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        tabs.newTab()
                        tabs.isShowingSwitcher = false
                    } label: {
                        Label("New Tab", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { tabs.isShowingSwitcher = false }
                }
            }
        }
    }
}

/// One tab's card: its last-seen thumbnail, title, and a close affordance.
private struct TabCard: View {
    let tab: BrowseTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    private let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onSelect) {
                thumbnail
                    .aspectRatio(0.72, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: cornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .topTrailing) { closeButton }
            }
            .buttonStyle(.plain)

            Text(tab.title)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.primary : .secondary)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let snapshot = tab.snapshot {
            Image(uiImage: snapshot)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.55), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(6)
        .accessibilityLabel("Close Tab")
    }
}
