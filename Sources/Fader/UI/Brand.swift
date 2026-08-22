import SwiftUI

/// The app's brand identity, kept in one place so every UI touchpoint
/// (currently just the header mark) stays in sync. A single flat accent
/// now, matching the website's --accent (docs/index.html) exactly — the
/// old amber→orange→red→crimson gradient was the site's original look
/// before it moved to a one-color system, and this brings the app back
/// in step with it.
enum Brand {
    static let accent = Color(red: 1.00, green: 0.353, blue: 0.122) // #FF5A1F
}
