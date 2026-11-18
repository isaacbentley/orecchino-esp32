import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Palette lifted from the bigear-rs console, with dispatch's status hues.
enum Theme {
    static let bg      = Color(hex: 0x07090E)
    static let inset   = Color.black.opacity(0.25)
    static let accent  = Color(hex: 0x35D0BA)
    static let muted   = Color(hex: 0x8A99AD)
    /// Ink for absent/unknown values — dimmed but still legible.
    static let unknown = Color(hex: 0x7F8EA3)
    static let warn    = Color(hex: 0xE0A83A)
    static let danger  = Color(hex: 0xE05A5A)
    static let ok      = Color(hex: 0x5ECB7A)
    /// Freshness override: an aged-out entity is this color no matter
    /// which identity color it carries. The trail keeps identity color.
    static let staleInk = Color(hex: 0x9AA0A6)

    /// Per-entity identity colors (bigear's map palette, extended).
    static let tracks: [Color] = [
        Color(hex: 0x00B4D8), Color(hex: 0xFF9D6F), Color(hex: 0xB78BFF),
        Color(hex: 0x6FB6FF), Color(hex: 0xE0A83A), Color(hex: 0x7FD6A0),
        Color(hex: 0xFF7FB6), Color(hex: 0xD6D67F),
    ]
}
