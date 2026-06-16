//
//  PhotoViewerView.swift
//  Nextcloud Gallery
//
//  Full-screen, swipeable photo viewer with zoom and save-to-Photos.
//

import SwiftUI

struct PhotoViewerView: View {
    let photos: [PhotoItem]

    @Environment(AppEnvironment.self) private var environment
    @Environment(TabsModel.self) private var tabs
    @Environment(\.dismiss) private var dismiss

    @State private var currentID: String?
    @State private var isZoomed = false
    @State private var saver = PhotoSaver()

    init(photos: [PhotoItem], initialPhotoID: String) {
        self.photos = photos
        _currentID = State(initialValue: initialPhotoID)
    }

    var body: some View {
        @Bindable var tabs = tabs

        NavigationStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(photos) { photo in
                        PhotoPageView(photo: photo, isZoomed: $isZoomed)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollDisabled(isZoomed)
            .scrollIndicators(.hidden)
            .background(.black)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(currentPhoto?.fileName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    saveButton
                }
                // Reach the switcher without closing the photo — so this tab can
                // stay parked on a single image while you browse another tab. The
                // open photo is restored when you switch back (it lives on the tab).
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        tabs.openSwitcher()
                    } label: {
                        Label("Show Tabs", systemImage: "square.on.square")
                    }
                }
            }
            .alert("Couldn't Save Photo", isPresented: showErrorBinding) {
                Button("OK", role: .cancel) { saver.reset() }
            } message: {
                Text(saver.errorMessage ?? "")
            }
        }
        .preferredColorScheme(.dark)
        // The viewer is the top-most cover while a photo is open, so it hosts the
        // switcher. Picking another tab changes the active tab, which rebuilds the
        // tab container and tears this viewer down — leaving this tab's open photo
        // in the model, ready to restore when you come back.
        .fullScreenCover(isPresented: $tabs.isShowingSwitcher) {
            TabSwitcherView()
                .environment(tabs)
        }
    }

    private var currentPhoto: PhotoItem? {
        photos.first { $0.id == currentID }
    }

    @ViewBuilder
    private var saveButton: some View {
        switch saver.status {
        case .saving:
            ProgressView()
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        default:
            Button("Save", systemImage: "square.and.arrow.down") {
                Task { await save() }
            }
        }
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { saver.errorMessage != nil },
            set: { if !$0 { saver.reset() } }
        )
    }

    private func save() async {
        guard let photo = currentPhoto else { return }
        await saver.save(photo: photo, client: environment.client, store: environment.fullImageStore)
    }
}
