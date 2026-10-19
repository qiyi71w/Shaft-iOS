// Generated from Android vector paths by scripts/sync-image-filter.py.
import SwiftUI

/// Material glyphs of the Android filter page, in their own viewport units.
enum FilterGlyph {
    case photoFilter, refresh, share, download, check

    /// Android `viewportWidth` × `viewportHeight` (the refresh glyph is 54 × 48dp, not square).
    var viewport: CGSize {
        switch self {
        case .photoFilter: return CGSize(width: 24, height: 24)
        case .refresh: return CGSize(width: 1152, height: 1024)
        case .share: return CGSize(width: 24, height: 24)
        case .download: return CGSize(width: 24, height: 24)
        case .check: return CGSize(width: 24, height: 24)
        }
    }

    var path: Path {
        var p = Path()
        switch self {
        case .photoFilter:
            p.move(to: CGPoint(x: 19.02, y: 10))
            p.addLine(to: CGPoint(x: 19.02, y: 19))
            p.addLine(to: CGPoint(x: 5, y: 19))
            p.addLine(to: CGPoint(x: 5, y: 5))
            p.addLine(to: CGPoint(x: 14, y: 5))
            p.addLine(to: CGPoint(x: 14, y: 3))
            p.addLine(to: CGPoint(x: 5.02, y: 3))
            p.addCurve(to: CGPoint(x: 3.02, y: 5), control1: CGPoint(x: 3.92, y: 3), control2: CGPoint(x: 3.02, y: 3.9))
            p.addLine(to: CGPoint(x: 3.02, y: 19))
            p.addCurve(to: CGPoint(x: 5.02, y: 21), control1: CGPoint(x: 3.02, y: 20.1), control2: CGPoint(x: 3.92, y: 21))
            p.addLine(to: CGPoint(x: 19.02, y: 21))
            p.addCurve(to: CGPoint(x: 21.02, y: 19), control1: CGPoint(x: 20.12, y: 21), control2: CGPoint(x: 21.02, y: 20.1))
            p.addLine(to: CGPoint(x: 21.02, y: 10))
            p.addLine(to: CGPoint(x: 19.02, y: 10))
            p.closeSubpath()
            p.move(to: CGPoint(x: 17, y: 10))
            p.addLine(to: CGPoint(x: 17.94, y: 7.94))
            p.addLine(to: CGPoint(x: 20, y: 7))
            p.addLine(to: CGPoint(x: 17.94, y: 6.06))
            p.addLine(to: CGPoint(x: 17, y: 4))
            p.addLine(to: CGPoint(x: 16.06, y: 6.06))
            p.addLine(to: CGPoint(x: 14, y: 7))
            p.addLine(to: CGPoint(x: 16.06, y: 7.94))
            p.addLine(to: CGPoint(x: 17, y: 10))
            p.closeSubpath()
            p.move(to: CGPoint(x: 13.25, y: 10.75))
            p.addLine(to: CGPoint(x: 12, y: 8))
            p.addLine(to: CGPoint(x: 10.75, y: 10.75))
            p.addLine(to: CGPoint(x: 8, y: 12))
            p.addLine(to: CGPoint(x: 10.75, y: 13.25))
            p.addLine(to: CGPoint(x: 12, y: 16))
            p.addLine(to: CGPoint(x: 13.25, y: 13.25))
            p.addLine(to: CGPoint(x: 16, y: 12))
            p.addLine(to: CGPoint(x: 13.25, y: 10.75))
            p.closeSubpath()
        case .refresh:
            p.move(to: CGPoint(x: 1034.11, y: 515.07))
            p.addLine(to: CGPoint(x: 1034.17, y: 509.37))
            p.addCurve(to: CGPoint(x: 576, y: 51.2), control1: CGPoint(x: 1034.24, y: 256.77), control2: CGPoint(x: 828.67, y: 51.2))
            p.addCurve(to: CGPoint(x: 336, y: 119.04), control1: CGPoint(x: 491.257177, y: 51.1219726), control2: CGPoint(x: 408.161951, y: 74.6102232))
            p.addCurve(to: CGPoint(x: 314.015, y: 211.615), control1: CGPoint(x: 304.36513, y: 138.53289), control2: CGPoint(x: 294.52211, y: 179.98013))
            p.addCurve(to: CGPoint(x: 406.59, y: 233.6), control1: CGPoint(x: 333.50789, y: 243.24987), control2: CGPoint(x: 374.95513, y: 253.09289))
            p.addCurve(to: CGPoint(x: 576, y: 185.66), control1: CGPoint(x: 457.525921, y: 202.228765), control2: CGPoint(x: 516.178418, y: 185.631157))
            p.addCurve(to: CGPoint(x: 806.729641, y: 282.596081), control1: CGPoint(x: 662.788025, y: 185.768873), control2: CGPoint(x: 745.904945, y: 220.688653))
            p.addCurve(to: CGPoint(x: 899.58, y: 515), control1: CGPoint(x: 867.554337, y: 344.503508), control2: CGPoint(x: 901.002297, y: 428.223562))
            p.addLine(to: CGPoint(x: 785.08, y: 515))
            p.addLine(to: CGPoint(x: 968.57, y: 777.72))
            p.addLine(to: CGPoint(x: 1152, y: 515.07))
            p.addLine(to: CGPoint(x: 1034.11, y: 515.07))
            p.closeSubpath()
            p.move(to: CGPoint(x: 783.68, y: 774.14))
            p.addCurve(to: CGPoint(x: 745.41, y: 786.04), control1: CGPoint(x: 769.98, y: 774.14), control2: CGPoint(x: 756.67, y: 778.3))
            p.addCurve(to: CGPoint(x: 576, y: 833.92), control1: CGPoint(x: 694.46788, y: 817.390168), control2: CGPoint(x: 635.815804, y: 833.966884))
            p.addCurve(to: CGPoint(x: 345.224919, y: 737.008832), control1: CGPoint(x: 489.19983, y: 833.829863), control2: CGPoint(x: 406.064806, y: 798.918329))
            p.addCurve(to: CGPoint(x: 252.35, y: 504.58), control1: CGPoint(x: 284.385031, y: 675.099336), control2: CGPoint(x: 250.927526, y: 591.36856))
            p.addLine(to: CGPoint(x: 366.91, y: 504.58))
            p.addLine(to: CGPoint(x: 183.42, y: 241.86))
            p.addLine(to: CGPoint(x: 0, y: 504.58))
            p.addLine(to: CGPoint(x: 117.89, y: 504.58))
            p.addLine(to: CGPoint(x: 117.89, y: 510.28))
            p.addCurve(to: CGPoint(x: 576, y: 968.46), control1: CGPoint(x: 117.89, y: 762.89), control2: CGPoint(x: 323.33, y: 968.46))
            p.addCurve(to: CGPoint(x: 816, y: 900.62), control1: CGPoint(x: 660.742823, y: 968.538027), control2: CGPoint(x: 743.838049, y: 945.049777))
            p.addCurve(to: CGPoint(x: 849.241602, y: 824.764191), control1: CGPoint(x: 843.179857, y: 885.963456), control2: CGPoint(x: 856.887917, y: 854.682293))
            p.addCurve(to: CGPoint(x: 783.68, y: 774.16), control1: CGPoint(x: 841.595287, y: 794.84609), control2: CGPoint(x: 814.559214, y: 773.978104))
            p.addLine(to: CGPoint(x: 783.68, y: 774.14))
            p.closeSubpath()
        case .share:
            p.move(to: CGPoint(x: 18, y: 16.08))
            p.addCurve(to: CGPoint(x: 16.04, y: 16.85), control1: CGPoint(x: 17.24, y: 16.08), control2: CGPoint(x: 16.56, y: 16.38))
            p.addLine(to: CGPoint(x: 8.91, y: 12.7))
            p.addCurve(to: CGPoint(x: 9, y: 12), control1: CGPoint(x: 8.96, y: 12.47), control2: CGPoint(x: 9, y: 12.24))
            p.addCurve(to: CGPoint(x: 8.91, y: 11.3), control1: CGPoint(x: 9, y: 11.76), control2: CGPoint(x: 8.96, y: 11.53))
            p.addLine(to: CGPoint(x: 15.96, y: 7.19))
            p.addCurve(to: CGPoint(x: 18, y: 8), control1: CGPoint(x: 16.5, y: 7.69), control2: CGPoint(x: 17.21, y: 8))
            p.addCurve(to: CGPoint(x: 21, y: 5), control1: CGPoint(x: 19.66, y: 8), control2: CGPoint(x: 21, y: 6.66))
            p.addCurve(to: CGPoint(x: 18, y: 2), control1: CGPoint(x: 21, y: 3.34), control2: CGPoint(x: 19.66, y: 2))
            p.addCurve(to: CGPoint(x: 15, y: 5), control1: CGPoint(x: 16.34, y: 2), control2: CGPoint(x: 15, y: 3.34))
            p.addCurve(to: CGPoint(x: 15.09, y: 5.7), control1: CGPoint(x: 15, y: 5.24), control2: CGPoint(x: 15.04, y: 5.47))
            p.addLine(to: CGPoint(x: 8.04, y: 9.81))
            p.addCurve(to: CGPoint(x: 6, y: 9), control1: CGPoint(x: 7.5, y: 9.31), control2: CGPoint(x: 6.79, y: 9))
            p.addCurve(to: CGPoint(x: 3, y: 12), control1: CGPoint(x: 4.34, y: 9), control2: CGPoint(x: 3, y: 10.34))
            p.addCurve(to: CGPoint(x: 6, y: 15), control1: CGPoint(x: 3, y: 13.66), control2: CGPoint(x: 4.34, y: 15))
            p.addCurve(to: CGPoint(x: 8.04, y: 14.19), control1: CGPoint(x: 6.79, y: 15), control2: CGPoint(x: 7.5, y: 14.69))
            p.addLine(to: CGPoint(x: 15.16, y: 18.35))
            p.addCurve(to: CGPoint(x: 15.08, y: 19), control1: CGPoint(x: 15.11, y: 18.56), control2: CGPoint(x: 15.08, y: 18.78))
            p.addCurve(to: CGPoint(x: 18, y: 21.92), control1: CGPoint(x: 15.08, y: 20.61), control2: CGPoint(x: 16.39, y: 21.92))
            p.addCurve(to: CGPoint(x: 20.92, y: 19), control1: CGPoint(x: 19.61, y: 21.92), control2: CGPoint(x: 20.92, y: 20.61))
            p.addCurve(to: CGPoint(x: 18, y: 16.08), control1: CGPoint(x: 20.92, y: 17.39), control2: CGPoint(x: 19.61, y: 16.08))
            p.closeSubpath()
        case .download:
            p.move(to: CGPoint(x: 19, y: 9))
            p.addLine(to: CGPoint(x: 15, y: 9))
            p.addLine(to: CGPoint(x: 15, y: 3))
            p.addLine(to: CGPoint(x: 9, y: 3))
            p.addLine(to: CGPoint(x: 9, y: 9))
            p.addLine(to: CGPoint(x: 5, y: 9))
            p.addLine(to: CGPoint(x: 12, y: 16))
            p.addLine(to: CGPoint(x: 19, y: 9))
            p.closeSubpath()
            p.move(to: CGPoint(x: 5, y: 18))
            p.addLine(to: CGPoint(x: 5, y: 20))
            p.addLine(to: CGPoint(x: 19, y: 20))
            p.addLine(to: CGPoint(x: 19, y: 18))
            p.addLine(to: CGPoint(x: 5, y: 18))
            p.closeSubpath()
        case .check:
            p.move(to: CGPoint(x: 9, y: 16.17))
            p.addLine(to: CGPoint(x: 4.83, y: 12))
            p.addLine(to: CGPoint(x: 3.41, y: 13.41))
            p.addLine(to: CGPoint(x: 9, y: 19))
            p.addLine(to: CGPoint(x: 21, y: 7))
            p.addLine(to: CGPoint(x: 19.59, y: 5.59))
            p.addLine(to: CGPoint(x: 9, y: 16.17))
            p.closeSubpath()
        }
        return p
    }
}

/// Draws a glyph the way an Android `ImageView` (FIT_CENTER) draws its vector: scaled to fit the
/// frame, centred, filled with the foreground style.
struct FilterIcon: View {
    var glyph: FilterGlyph
    var body: some View {
        Canvas { context, bounds in
            let vp = glyph.viewport
            let s = min(bounds.width / vp.width, bounds.height / vp.height)
            context.translateBy(x: (bounds.width - vp.width * s) / 2, y: (bounds.height - vp.height * s) / 2)
            context.scaleBy(x: s, y: s)
            context.fill(glyph.path, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
