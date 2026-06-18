import SwiftUI

extension Color {
    /// Parses a 6-digit RGB hex string (with or without a leading `#`).
    init?(hexRGB: String) {
        let raw = hexRGB.hasPrefix("#") ? String(hexRGB.dropFirst()) : hexRGB
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
