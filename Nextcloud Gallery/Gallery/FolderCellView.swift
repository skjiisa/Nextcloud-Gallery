//
//  FolderCellView.swift
//  Nextcloud Gallery
//
//  A square folder cell whose artwork is a 2x2 composite of photos drawn from
//  within the folder (and its subfolders). The composite upgrades live as the
//  warming crawler discovers more of the subtree.
//

import SwiftUI
import SwiftData

struct FolderCellView: View {
    let item: CachedItem

    @Query private var states: [FolderState]

    init(item: CachedItem) {
        self.item = item
        let path = item.fullPath
        let account = item.account
        _states = Query(filter: #Predicate<FolderState> { $0.folderPath == path && $0.account == account })
    }

    private var tiles: [CoverTile] { states.first?.coverTiles ?? [] }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { artwork }
            .overlay(alignment: .bottom) { nameLabel }
            .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var artwork: some View {
        switch tiles.count {
        case 0:
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "folder.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        case 1:
            tileView(tiles[0])
        default:
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    cell(0)
                    cell(1)
                }
                GridRow {
                    cell(2)
                    cell(3)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ index: Int) -> some View {
        if index < tiles.count {
            tileView(tiles[index])
        } else {
            Rectangle().fill(.quaternary)
        }
    }

    private func tileView(_ tile: CoverTile) -> some View {
        Color.clear
            .overlay {
                ThumbnailImageView(
                    ocId: tile.ocId,
                    fileId: tile.fileId,
                    etag: tile.etag,
                    pixels: NextcloudConfig.coverTilePixels
                )
            }
            .clipped()
    }

    private var nameLabel: some View {
        Text(item.fileName)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.35))
    }
}
