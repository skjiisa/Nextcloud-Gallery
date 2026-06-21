//
//  UIColor+Hex.swift
//  Nextcloud Gallery
//
//  Parsing the RGB hex colours Nextcloud uses for system tags.
//

import UIKit

extension UIColor {
    /// Parses an RGB hex string like `"FF0000"` or `"#FF0000"`; nil if malformed.
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
