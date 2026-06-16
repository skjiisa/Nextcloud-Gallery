//
//  FolderGridView.swift
//  Nextcloud Gallery
//
//  A grid of the photos and folders in one folder, backed by the on-disk cache.
//

import SwiftUI
import SwiftData

struct FolderGridView: View {
    let folderPath: String
    let title: String
    let account: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.layoutMetrics) private var metrics
    @Environment(BrowseTab.self) private var tab
    @Environment(TabsModel.self) private var tabs
    @Query private var items: [CachedItem]

    @State private var isLoading = false
    @State private var errorMessage: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: metrics.minGridCellSize), spacing: metrics.gridSpacing)]
    }

    init(folderPath: String, title: String, account: String) {
        self.folderPath = folderPath
        self.title = title
        self.account = account

        let parent = WebDAVPath.normalized(folderPath)
        // Show subfolders and images only. Non-image files (PDFs, videos, …) have
        // no image preview, so they'd render as permanently-blank photo cells — and
        // the image-only viewer can't display them. `classFile == "image"` mirrors
        // `CachedItem.isPhoto` (which a #Predicate can't call: it isn't stored).
        _items = Query(
            filter: #Predicate<CachedItem> {
                $0.parentPath == parent && $0.account == account
                    && ($0.isDirectory || $0.classFile == "image")
            },
            sort: [SortDescriptor(\.kindRank), SortDescriptor(\.nameKey)]
        )
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns) {
                ForEach(items, id: \.ocId) { item in
                    if item.isDirectory {
                        let route = FolderRoute(folderPath: item.fullPath, title: item.fileName, account: account)
                        NavigationLink(value: BrowseRoute.folder(route)) {
                            FolderCellView(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                tabs.open(.folder(route), inNewTab: true)
                            } label: {
                                Label("Open in New Tab", systemImage: "plus.square.on.square")
                            }
                        }
                    } else {
                        Button {
                            openViewer(at: item)
                        } label: {
                            PhotoCellView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(metrics.contentPadding)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: BrowseRoute.flat(FlatGalleryRoute(folderPath: folderPath, title: title, account: account))) {
                    Label("Gallery", systemImage: "square.grid.3x3")
                }
            }
        }
        .overlay { statusOverlay }
        .task(id: folderPath) { await load() }
        .refreshable { await load() }
    }

    private func openViewer(at item: CachedItem) {
        // Hand the viewer the live photo list (built here, never empty) so it can
        // page across the folder. The presentation itself lives on the tab — set
        // in `TabContentView` — so the open photo survives switching tabs.
        tab.openViewer(
            photos: items.filter { !$0.isDirectory }.map(PhotoItem.init(cachedItem:)),
            initialID: item.ocId
        )
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
            ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle", description: Text("This folder is empty."))
        }
    }

    private func load() async {
        guard let client = environment.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let files = try await client.listFolder(at: folderPath)
            try await environment.cacheStore.ingest(parentPath: folderPath, account: account, files: files)
            try? await environment.cacheStore.recomputeCoverChain(
                folderPath: folderPath, rootPath: client.filesRootPath, account: account
            )
            environment.warmingCoordinator?.prioritize(currentFolderPath: folderPath)
        } catch is CancellationError {
            // Navigated away; ignore.
        } catch {
            errorMessage = (error as? GalleryError)?.userMessage ?? error.localizedDescription
        }
    }
}
