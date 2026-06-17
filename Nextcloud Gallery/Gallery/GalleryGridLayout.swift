//
//  GalleryGridLayout.swift
//  Nextcloud Gallery
//
//  Adaptive square-tile compositional layout shared by the folder and flattened
//  grids. The column count is derived from the live container width, so the grid
//  reflows across iPhone/iPad/visionOS and window resizes for free — the UIKit
//  equivalent of the SwiftUI `GridItem(.adaptive(minimum:))`.
//

import UIKit

enum GalleryGridLayout {
    /// A compositional layout of square tiles that fit as many `minItemWidth`-wide
    /// columns as the width allows, with `spacing` between tiles and `sectionInset`
    /// around the content.
    static func make(minItemWidth: CGFloat, spacing: CGFloat, sectionInset: CGFloat) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let available = environment.container.effectiveContentSize.width
            let usable = max(0, available - sectionInset * 2)
            let columns = max(1, Int((usable + spacing) / (minItemWidth + spacing)))

            // Each tile is 1/columns of the row width; a square group is that same
            // fraction tall, so tiles come out (near-)square. Small inter-tile
            // spacing makes the slight spacing-vs-square discrepancy invisible.
            let tileFraction = 1.0 / CGFloat(columns)
            let item = NSCollectionLayoutItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(tileFraction),
                    heightDimension: .fractionalHeight(1)
                )
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .fractionalWidth(tileFraction)
                ),
                subitems: [item]
            )
            group.interItemSpacing = .fixed(spacing)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: sectionInset, leading: sectionInset, bottom: sectionInset, trailing: sectionInset
            )
            return section
        }
    }
}
