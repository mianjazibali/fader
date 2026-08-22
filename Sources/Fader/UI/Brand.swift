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

/// The fader mark: three vertical bars at different heights, the same
/// glyph as the website's `.mark` SVG (`M3 12V4M8 13V3M13 10V6`, 16x16
/// viewBox, 2pt stroke, round caps). Drawn as a real path rather than an
/// SF Symbol so the menu bar icon and in-app badge are pixel-consistent
/// with the site instead of three independently-authored marks.
struct FaderMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let bars: [(x: CGFloat, y1: CGFloat, y2: CGFloat)] = [
            (3, 12, 4), (8, 13, 3), (13, 10, 6)
        ]
        var path = Path()
        for bar in bars {
            path.move(to: CGPoint(x: bar.x * scale, y: bar.y1 * scale))
            path.addLine(to: CGPoint(x: bar.x * scale, y: bar.y2 * scale))
        }
        return path
    }
}
