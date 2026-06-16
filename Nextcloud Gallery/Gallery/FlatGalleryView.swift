//
//  FlatGalleryView.swift
//  Nextcloud Gallery
//
//  All photos under a folder's subtree shown as one continuous, folder-agnostic
//  collection. Renders reactively from the local cache while a recursive server
//  media-SEARCH fills in anything warming hasn't reached yet.
//

import SwiftUI
import SwiftData

struct FlatGalleryView: View {
    let folderPath: String
    let title: String
    let account: String

    @Environment(AppEnvironment.self) private var environment
    // The browse tab owns the ordering + appearance, so each tab remembers its
    // own (one sorted by date, another by folder, at different zooms).
    @Environment(BrowseTab.self) private var tab

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var contentMode: ContentMode { tab.aspectFill ? .fill : .fit }

    var body: some View {
        @Bindable var tab = tab

        // The grid lives in a child so changing the sort rebuilds its `@Query`
        // with new descriptors (a `@Query`'s sort is otherwise fixed at init).
        FlatGalleryGrid(
            folderPath: folderPath,
            account: account,
            sortDescriptors: tab.sort.sortDescriptors,
            zoom: tab.zoom,
            contentMode: contentMode,
            isLoading: isLoading,
            errorMessage: errorMessage,
            refresh: { await load() },
            openPhoto: { photos, id in tab.openViewer(photos: photos, initialID: id) }
        )
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu(tab: tab)
                aspectButton(tab: tab)
                zoomOutButton(tab: tab)
                zoomInButton(tab: tab)
            }
        }
        .task(id: folderPath) { await load() }
    }

    private func sortMenu(tab: BrowseTab) -> some View {
        Menu {
            Picker("Sort", selection: Bindable(tab).sort) {
                ForEach(GallerySortOrder.allCases) { order in
                    Label(order.label, systemImage: order.symbol).tag(order)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private func aspectButton(tab: BrowseTab) -> some View {
        Button {
            tab.aspectFill.toggle()
        } label: {
            Label(tab.aspectFill ? "Aspect Fit" : "Aspect Fill",
                  systemImage: tab.aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
    }

    private func zoomOutButton(tab: BrowseTab) -> some View {
        Button {
            tab.zoom = tab.zoom.zoomedOut
        } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
        }
        .disabled(!tab.zoom.canZoomOut)
    }

    private func zoomInButton(tab: BrowseTab) -> some View {
        Button {
            tab.zoom = tab.zoom.zoomedIn
        } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
        }
        .disabled(!tab.zoom.canZoomIn)
    }

    private func load() async {
        guard let client = environment.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let limit = NextcloudConfig.mediaSearchLimit
            let files = try await client.searchMedia(under: folderPath, limit: limit)
            // Upsert the results and prune any image the (complete) search no longer
            // returns — i.e. deleted on the server. Kept in CacheStore so the view
            // doesn't touch NKFile members.
            try await environment.cacheStore.reconcileSearchResults(
                under: folderPath,
                rootPath: client.filesRootPath,
                account: account,
                files: files,
                limit: limit
            )
            environment.warmingCoordinator?.prioritize(currentFolderPath: folderPath)
        } catch is CancellationError {
            // Navigated away; ignore.
        } catch {
            errorMessage = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        }
    }
}

/// The reactive grid itself. Lives apart from ``FlatGalleryView`` so that passing
/// new `sortDescriptors` into its initializer rebuilds the `@Query` — the way to
/// change a query's sort live.
private struct FlatGalleryGrid: View {
    let folderPath: String
    let account: String
    let zoom: GalleryGridZoom
    let contentMode: ContentMode
    let isLoading: Bool
    let errorMessage: String?
    let refresh: () async -> Void
    /// Opens the viewer on the tab. The grid supplies its live, in-order photo
    /// list so the viewer pages in the same order it's shown.
    let openPhoto: ([PhotoItem], String) -> Void

    @Environment(\.layoutMetrics) private var metrics
    @Query private var items: [CachedItem]

    /// Tight, Photos-style inter-tile gap and outer margin.
    private let tileSpacing: CGFloat = 2

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: metrics.minGridCellSize * zoom.cellSizeMultiplier), spacing: tileSpacing)]
    }

    init(
        folderPath: String,
        account: String,
        sortDescriptors: [SortDescriptor<CachedItem>],
        zoom: GalleryGridZoom,
        contentMode: ContentMode,
        isLoading: Bool,
        errorMessage: String?,
        refresh: @escaping () async -> Void,
        openPhoto: @escaping ([PhotoItem], String) -> Void
    ) {
        self.folderPath = folderPath
        self.account = account
        self.zoom = zoom
        self.contentMode = contentMode
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.refresh = refresh
        self.openPhoto = openPhoto

        // Every image whose containing folder is this folder or anything beneath it.
        // `parentPath` is a photo's immediate folder, so a prefix match on
        // `base + "/"` captures the whole subtree in one indexed query.
        let base = WebDAVPath.normalized(folderPath)
        let prefix = base + "/"
        _items = Query(
            filter: #Predicate<CachedItem> {
                $0.account == account && $0.classFile == "image"
                    && ($0.parentPath == base || $0.parentPath.starts(with: prefix))
            },
            sort: sortDescriptors
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: tileSpacing) {
                ForEach(items, id: \.ocId) { item in
                    Button {
                        // Build the list from the live query so the viewer shows the
                        // photos in the same order — and never captures an empty/stale
                        // snapshot. The tab holds the presentation (see TabPageView).
                        openPhoto(items.map(PhotoItem.init(cachedItem:)), item.ocId)
                    } label: {
                        PhotoCellView(item: item, contentMode: contentMode, cornerRadius: zoom.cornerRadius)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(tileSpacing)
            .animation(.snappy, value: zoom)
            .animation(.snappy, value: contentMode)
        }
        .scrollIndicators(.hidden)
        .overlay { statusOverlay }
        .refreshable { await refresh() }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if isLoading && items.isEmpty {
            ProgressView()
        } else if let errorMessage, items.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { Task { await refresh() } }
            }
        } else if items.isEmpty && !isLoading {
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle", description: Text("This folder has no photos."))
        }
    }
}
