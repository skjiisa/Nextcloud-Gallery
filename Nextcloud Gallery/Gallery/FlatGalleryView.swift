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

    @State private var isLoading = false
    @State private var errorMessage: String?

    // Persisted, nav-bar-driven ordering + appearance.
    @AppStorage("flatGallerySort") private var sortRaw = GallerySortOrder.newestFirst.rawValue
    @AppStorage("flatGalleryZoom") private var zoomRaw = GalleryGridZoom.medium.rawValue
    @AppStorage("flatGalleryAspectFill") private var aspectFill = true

    private var sortOrder: GallerySortOrder { GallerySortOrder(rawValue: sortRaw) ?? .newestFirst }
    private var zoom: GalleryGridZoom { GalleryGridZoom(rawValue: zoomRaw) ?? .medium }
    private var contentMode: ContentMode { aspectFill ? .fill : .fit }

    var body: some View {
        // The grid lives in a child so changing the sort rebuilds its `@Query`
        // with new descriptors (a `@Query`'s sort is otherwise fixed at init).
        FlatGalleryGrid(
            folderPath: folderPath,
            account: account,
            sortDescriptors: sortOrder.sortDescriptors,
            zoom: zoom,
            contentMode: contentMode,
            isLoading: isLoading,
            errorMessage: errorMessage,
            refresh: { await load() }
        )
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                aspectButton
                zoomOutButton
                zoomInButton
            }
        }
        .task(id: folderPath) { await load() }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(GallerySortOrder.allCases) { order in
                    Label(order.label, systemImage: order.symbol).tag(order.rawValue)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
    }

    private var aspectButton: some View {
        Button {
            aspectFill.toggle()
        } label: {
            Label(aspectFill ? "Aspect Fit" : "Aspect Fill",
                  systemImage: aspectFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
    }

    private var zoomOutButton: some View {
        Button {
            zoomRaw = zoom.zoomedOut.rawValue
        } label: {
            Label("Zoom Out", systemImage: "minus.magnifyingglass")
        }
        .disabled(!zoom.canZoomOut)
    }

    private var zoomInButton: some View {
        Button {
            zoomRaw = zoom.zoomedIn.rawValue
        } label: {
            Label("Zoom In", systemImage: "plus.magnifyingglass")
        }
        .disabled(!zoom.canZoomIn)
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

    @Environment(\.layoutMetrics) private var metrics
    @Query private var items: [CachedItem]
    @State private var presentedPhoto: PhotoItem?

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
        refresh: @escaping () async -> Void
    ) {
        self.folderPath = folderPath
        self.account = account
        self.zoom = zoom
        self.contentMode = contentMode
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.refresh = refresh

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
                        presentedPhoto = PhotoItem(cachedItem: item)
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
        .fullScreenCover(item: $presentedPhoto) { photo in
            // Build the list from the live query so the viewer shows the photos in
            // the same order — and never captures a stale snapshot.
            PhotoViewerView(
                photos: items.map(PhotoItem.init(cachedItem:)),
                initialPhotoID: photo.id
            )
        }
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
