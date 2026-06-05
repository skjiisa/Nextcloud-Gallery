//
//  Item.swift
//  Nextcloud Gallery
//
//  Created by Elaine Lyons on 6/4/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
