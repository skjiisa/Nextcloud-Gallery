//
//  FlatGalleryView.swift
//  Nextcloud Gallery
//
//  All photos under a folder's subtree shown as one continuous, folder-agnostic
//  collection, newest first. Renders reactively from the local cache while a
//  recursive server media-SEARCH fills in anything warming hasn't reached yet.
//

import SwiftUI
import SwiftData

struct FlatGalleryView: View {
    let folderPath: String
    let title: String
    let account: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.layoutMetrics) private var metrics
    @Query private var items: [CachedItem]

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var presentedPhoto: PhotoItem?

    // Fixed for now; routed through GallerySortOrder so other orders drop in later.
    private let sortOrder: GallerySortOrder = .newestFirst

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: metrics.minGridCellSize), spacing: metrics.gridSpacing)]
    }

    init(folderPath: String, title: String, account: String) {
        self.folderPath = folderPath
        self.title = title
        self.account = account

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
            sort: GallerySortOrder.newestFirst.sortDescriptors
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(items, id: \.ocId) { item in
                    Button {
                        presentedPhoto = PhotoItem(cachedItem: item)
                    } label: {
                        PhotoCellView(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(metrics.contentPadding)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(title)
        .overlay { statusOverlay }
        .task(id: folderPath) { await load() }
        .refreshable { await load() }
        .fullScreenCover(item: $presentedPhoto) { photo in
            // Build the list from the live query so the viewer never captures a
            // stale snapshot (mirrors FolderGridView).
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
                Button("Retry") { Task { await load() } }
            }
        } else if items.isEmpty && !isLoading {
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle", description: Text("This folder has no photos."))
        }
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
