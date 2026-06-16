//
//  TabCarouselView.swift
//  Nextcloud Gallery
//
//  Lays the open tabs out as a horizontal carousel. Only the active tab is on
//  screen at rest; dragging a tab's bottom bar slides the pages — each with its
//  own navigation stack and toolbar — so the neighbouring tab peeks in from the
//  side, then snaps to the nearest tab on release.
//
//  Smoothness note: the live drag translation is applied as a SINGLE outer
//  `.offset`, and the bars talk to the shared `CarouselDrag` through the
//  environment rather than per-page closures. So the heavy pages keep stable
//  inputs and SwiftUI doesn't re-render them on every drag tick — only the cheap
//  outer transform updates.
//

import SwiftUI

/// Shared, observable drag state for the carousel. Each tab's bar feeds its drag
/// here (via the environment); the carousel reads `offset` to position the pages.
@Observable
@MainActor
final class CarouselDrag {
    /// Live horizontal displacement of the whole carousel (and the snap animation
    /// that follows a release). Zero when settled.
    var offset: CGFloat = 0
    /// True from the first drag movement until its snap completes — while true the
    /// neighbours are mounted so they can peek; at rest only the active tab is.
    var isActive = false
    /// Page width, set from the carousel's geometry; drives snap distance + math.
    var width: CGFloat = 0

    /// Gap between pages, so a sliver of background separates the peeking neighbour.
    private let peekGap: CGFloat = 16
    private weak var tabs: TabsModel?

    var slot: CGFloat { width + peekGap }

    func connect(_ tabs: TabsModel) {
        if self.tabs == nil { self.tabs = tabs }
    }

    func changed(_ translation: CGFloat) {
        guard let tabs else { return }
        if !isActive {
            isActive = true
            // Snapshot the active tab now, while it's still full-screen, so its
            // switcher card stays fresh once it slides away.
            tabs.snapshotActiveTab()
        }
        let active = tabs.activeIndex
        let atStart = active == 0
        let atEnd = active == tabs.tabs.count - 1
        // Rubber-band when dragging past the first/last tab — there's nothing there.
        if (atStart && translation > 0) || (atEnd && translation < 0) {
            offset = translation / 3
        } else {
            offset = translation
        }
    }

    func ended(_ translation: CGFloat) {
        guard let tabs else { return }
        let active = tabs.activeIndex
        let threshold = width * 0.22
        var target = active
        if translation <= -threshold, active < tabs.tabs.count - 1 {
            target = active + 1
        } else if translation >= threshold, active > 0 {
            target = active - 1
        }

        // Animate the chosen page to centre, then commit it as active and zero the
        // offset in one step (the positions coincide, so there's no visible jump).
        let settled = -CGFloat(target - active) * slot
        withAnimation(.snappy(duration: 0.28)) {
            offset = settled
        } completion: {
            if target != active {
                tabs.activeTabID = tabs.tabs[target].id
                tabs.save()
            }
            self.offset = 0
            self.isActive = false
        }
    }
}

struct TabCarouselView: View {
    let client: NextcloudClient

    @Environment(TabsModel.self) private var tabs
    @State private var drag = CarouselDrag()

    var body: some View {
        GeometryReader { geo in
            let active = tabs.activeIndex
            // Pages are positioned at FIXED slots (independent of the live offset);
            // only the outer `.offset` below follows the finger, so the pages don't
            // recompute mid-drag.
            ZStack {
                ForEach(visiblePages, id: \.tab.id) { page in
                    TabPageView(
                        tab: page.tab,
                        client: client,
                        isActive: page.tab.id == tabs.activeTabID
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .offset(x: CGFloat(page.index - active) * drag.slot)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color(.systemBackground))
            .offset(x: drag.offset)
            .onAppear {
                drag.connect(tabs)
                drag.width = geo.size.width
            }
            .onChange(of: geo.size.width) { _, newWidth in
                drag.width = newWidth
            }
        }
        .environment(drag)
    }

    private struct Page { let index: Int; let tab: BrowseTab }

    /// The active tab, plus its immediate neighbours while a drag is in flight.
    private var visiblePages: [Page] {
        let active = tabs.activeIndex
        let indices = drag.isActive ? [active - 1, active, active + 1] : [active]
        return indices.compactMap { i in
            tabs.tabs.indices.contains(i) ? Page(index: i, tab: tabs.tabs[i]) : nil
        }
    }
}

/// One tab's page: its navigation stack, its own bottom bar, and the full-screen
/// viewer it may have open. Holds only stable inputs (no closures), so the
/// carousel can re-evaluate its own body each drag tick without re-rendering this
/// heavy subtree. The viewer is gated to the active tab so an off-screen
/// neighbour with a photo open doesn't present it mid-carousel.
private struct TabPageView: View {
    @Bindable var tab: BrowseTab
    let client: NextcloudClient
    let isActive: Bool

    var body: some View {
        NavigationStack(path: $tab.path) {
            FolderGridView(
                folderPath: client.filesRootPath,
                title: "Photos",
                account: client.credentials.account
            )
            .navigationDestination(for: BrowseRoute.self) { route in
                switch route {
                case .folder(let route):
                    FolderGridView(folderPath: route.folderPath, title: route.title, account: route.account)
                case .flat(let route):
                    FlatGalleryView(folderPath: route.folderPath, title: route.title, account: route.account)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            TabBarView()
        }
        .fullScreenCover(item: isActive ? $tab.viewer : .constant(nil)) { presentation in
            PhotoViewerView(photos: presentation.photos, initialPhotoID: presentation.initialID)
        }
        // Applied outermost so the nav content, the inset bar, AND the viewer all
        // inherit this tab (the inset/cover are siblings, not nav descendants).
        .environment(tab)
    }
}
