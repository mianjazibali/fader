import SwiftUI

/// The app's brand identity, kept in one place so every UI touchpoint
/// (header mark, empty state, sliders) matches Resources/Icon/AppIcon.svg
/// exactly instead of drifting — which is exactly how the old SonicFlow
/// cyan/blue/violet colors ended up still lingering in a few spots after
/// the rebrand.
enum Brand {
    static let amber   = Color(red: 1.00, green: 0.839, blue: 0.039)  // #FFD60A
    static let orange  = Color(red: 1.00, green: 0.541, blue: 0.0)    // #FF8A00
    static let red     = Color(red: 1.00, green: 0.231, blue: 0.188)  // #FF3B30
    static let crimson = Color(red: 0.816, green: 0.008, blue: 0.106) // #D0021B

    /// Diagonal gradient matching the app icon's background exactly.
    static var gradient: LinearGradient {
        LinearGradient(
            colors: [amber, orange, red, crimson],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Horizontal variant for fills that read left-to-right, like sliders.
    static var horizontalGradient: LinearGradient {
        LinearGradient(
            colors: [amber, orange, red, crimson],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// Softened (lower-opacity) horizontal variant for subtle strokes/rings.
    static func softGradient(opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: [amber, orange, red, crimson].map { $0.opacity(opacity) },
            startPoint: .leading, endPoint: .trailing
        )
    }
}
