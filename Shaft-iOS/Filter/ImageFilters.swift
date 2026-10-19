import Foundation

// 图片滤镜的颜色模型 —— Pixiv-Shaft `ceui/pixiv/ui/filter/ImageFilters.kt` 的逐行移植。
//
// 当下修图 App 的热门滤镜（VSCO 的 A6 / M5、醒图的奶油 / 氛围感、Dazz 的 CCD、电影青橙……）
// 靠的都是**分通道曲线 + 分离色调**，一只颜色矩阵表达不了。所以这里的每个滤镜都是一串 `ColorOp`，
// 再连同强度和手动调节一起采样成一只 33³ 的 **3D LUT**（VSCO / Lightroom 的同一种做法）：
// 无论叠了多少步，像素侧都只是一次查表 + 四面体插值，预览与导出走同一个内核（`ImageFilterKernel`）。
//
// 颜色一律在 0–1 浮点域里算，中途允许越界，采样进 LUT 时才夹回去。浮点运算顺序与 Kotlin 侧保持一致，
// 两端采出来的 LUT 逐位相同，同一组参数在 Android 和 iOS 上出的是同一张图。

/// 原地改写 `c`（r, g, b）的一步调色。
typealias ColorOp = @Sendable (inout FilterRGB) -> Void

struct FilterRGB {
    var r: Float
    var g: Float
    var b: Float

    subscript(i: Int) -> Float {
        get { i == 0 ? r : (i == 1 ? g : b) }
        set {
            switch i {
            case 0: r = newValue
            case 1: g = newValue
            default: b = newValue
            }
        }
    }
}

/// 由控制点（0–255）定义的单调三次曲线，预先采样成 256 级表。
struct FilterCurve: Sendable {
    private let table: [Float]

    func eval(_ v: Float) -> Float {
        let x = min(max(v, 0), 1) * 255
        let i = min(Int(x), 254)
        let f = x - Float(i)
        return table[i] + (table[i + 1] - table[i]) * f
    }

    /// `points` 是成对的 x, y（0–255），x 递增。Fritsch–Carlson 保单调，不会在控制点之间过冲。
    static func of(_ points: Int...) -> FilterCurve {
        precondition(points.count >= 4 && points.count % 2 == 0, "curve needs ≥ 2 points")
        let n = points.count / 2
        let xs = (0..<n).map { Float(points[$0 * 2]) / 255 }
        let ys = (0..<n).map { Float(points[$0 * 2 + 1]) / 255 }
        let d = (0..<(n - 1)).map { (ys[$0 + 1] - ys[$0]) / (xs[$0 + 1] - xs[$0]) }
        var m = (0..<n).map { i -> Float in
            switch i {
            case 0: return d[0]
            case n - 1: return d[n - 2]
            default: return d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2
            }
        }
        for i in 0..<(n - 1) {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i]
            let b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        let table = (0..<256).map { k -> Float in
            let x = Float(k) / 255
            if x <= xs[0] { return ys[0] }
            if x >= xs[n - 1] { return ys[n - 1] }
            var i = 0
            while x > xs[i + 1] { i += 1 }
            let h = xs[i + 1] - xs[i]
            let t = (x - xs[i]) / h
            let t2 = t * t
            let t3 = t2 * t
            let p0 = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i]
            return p0 + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1]
        }
        return FilterCurve(table: table)
    }
}

/// 调色步骤的工厂。参数含义尽量对齐修图 App 的滑条：0 = 不变，±1 = 满档。
enum FilterOps {

    static func luma(_ c: FilterRGB) -> Float { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    /// 曝光（档）：线性乘 2^ev。
    static func exposure(_ ev: Float) -> ColorOp {
        { c in
            let k = powf(2, ev)
            c.r *= k; c.g *= k; c.b *= k
        }
    }

    /// 亮度：伽马式提亮 / 压暗中间调，黑白两端不动 —— 修图 App 的「亮度」都是这个手感，
    /// 拉满也不会像曝光那样把高光整片冲白。`b` ∈ [-1, 1]。
    static func brightness(_ b: Float) -> ColorOp {
        { c in
            let g = powf(2, -0.75 * b)
            for i in 0...2 where c[i] > 0 { c[i] = powf(c[i], g) }
        }
    }

    /// 以中灰为支点的线性对比。
    static func contrast(_ k: Float) -> ColorOp {
        { c in for i in 0...2 { c[i] = (c[i] - 0.5) * k + 0.5 } }
    }

    /// 饱和度：绕亮度缩放色度，`s` = 0 为灰度。
    static func saturation(_ s: Float) -> ColorOp {
        { c in
            let l = luma(c)
            for i in 0...2 { c[i] = l + (c[i] - l) * s }
        }
    }

    /// 自然饱和度：越不饱和的颜色加得越多，肤色不容易过火。
    static func vibrance(_ v: Float) -> ColorOp {
        { c in
            let mx = max(c.r, max(c.g, c.b))
            let mn = min(c.r, min(c.g, c.b))
            let sat = min(max(mx - mn, 0), 1)
            let s = 1 + v * (1 - sat)
            let l = luma(c)
            for i in 0...2 { c[i] = l + (c[i] - l) * s }
        }
    }

    /// 色温：正值偏暖（加红减蓝）。
    static func warmth(_ w: Float) -> ColorOp {
        { c in c.r *= 1 + 0.10 * w; c.g *= 1 + 0.02 * w; c.b *= 1 - 0.14 * w }
    }

    /// 色调：正值偏洋红，负值偏绿。
    static func tint(_ t: Float) -> ColorOp {
        { c in c.r *= 1 + 0.04 * t; c.g *= 1 - 0.08 * t; c.b *= 1 + 0.04 * t }
    }

    /// 褪色：托起黑位、压低白位，哑光相纸感。
    static func fade(_ a: Float) -> ColorOp {
        let s = 1 - 0.26 * a
        let o = 0.15 * a
        return { c in for i in 0...2 { c[i] = c[i] * s + o } }
    }

    /// 高光 / 阴影：按亮度加权的提亮或压暗，只动对应的那一段。
    static func highlights(_ h: Float) -> ColorOp {
        { c in
            let l = min(max(luma(c), 0), 1)
            let d = 0.28 * h * l * l
            for i in 0...2 { c[i] += d }
        }
    }

    static func shadows(_ s: Float) -> ColorOp {
        { c in
            let l = 1 - min(max(luma(c), 0), 1)
            let d = 0.28 * s * l * l
            for i in 0...2 { c[i] += d }
        }
    }

    /// 曲线：先过总曲线，再过各通道曲线（与 Lightroom 的 RGB / 红 / 绿 / 蓝 曲线同序）。
    static func curves(master: FilterCurve? = nil, r: FilterCurve? = nil,
                       g: FilterCurve? = nil, b: FilterCurve? = nil) -> ColorOp {
        { c in
            if let master { for i in 0...2 { c[i] = master.eval(c[i]) } }
            if let r { c.r = r.eval(c.r) }
            if let g { c.g = g.eval(c.g) }
            if let b { c.b = b.eval(c.b) }
        }
    }

    /// 分离色调：暗部推向 `shadow`、亮部推向 `highlight`（0xRRGGBB）。只加色度，不加亮度：
    /// 色相减去它自己的亮度后再叠，所以「青橙」不会让整张图发灰或变亮。
    static func splitTone(_ shadow: Int, _ shadowAmount: Float, _ highlight: Int, _ highlightAmount: Float) -> ColorOp {
        let sh = chroma(shadow)
        let hi = chroma(highlight)
        return { c in
            let l = min(max(luma(c), 0), 1)
            let ws = (1 - l) * (1 - l) * shadowAmount
            let wh = l * l * highlightAmount
            for i in 0...2 { c[i] += sh[i] * ws + hi[i] * wh }
        }
    }

    /// 通道混合：3 × 3 矩阵，行是输出。
    static func mix(_ m: Float...) -> ColorOp {
        precondition(m.count == 9, "mix needs a 3×3 matrix")
        return { c in
            let r = c.r, g = c.g, b = c.b
            c.r = m[0] * r + m[1] * g + m[2] * b
            c.g = m[3] * r + m[4] * g + m[5] * b
            c.b = m[6] * r + m[7] * g + m[8] * b
        }
    }

    /// 灰度（Rec.601 加权，黑白片观感更厚）。
    static let grayscale: ColorOp = { c in
        let l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
        c.r = l; c.g = l; c.b = l
    }

    /// 经典 Sepia 系数。
    static let sepia = mix(0.393, 0.769, 0.189, 0.349, 0.686, 0.168, 0.272, 0.534, 0.131)

    private static func chroma(_ rgb: Int) -> FilterRGB {
        let c = FilterRGB(r: Float(rgb >> 16 & 0xFF) / 255, g: Float(rgb >> 8 & 0xFF) / 255, b: Float(rgb & 0xFF) / 255)
        let l = luma(c)
        return FilterRGB(r: c.r - l, g: c.g - l, b: c.b - l)
    }
}

/// 滤镜条里的分组，按「从哪类 App 学来的」分，方便找。
enum FilterGroup: CaseIterable, Sendable {
    case portrait, film, cinema, mono

    var label: LocalizedKey {
        switch self {
        case .portrait: return .imageFilterGroupPortrait
        case .film: return .imageFilterGroupFilm
        case .cinema: return .imageFilterGroupCinema
        case .mono: return .imageFilterGroupMono
        }
    }
}

/// 预设滤镜。注释里写了它对标的热门滤镜；界面上只用描述性的名字，不出现品牌与胶卷型号。
/// `vignette` / `grain` 是滤镜自带的暗角与颗粒，随强度一起缩放。
/// `key` 写进导出文件名，与 Android 同名，两端导出的成品可以互认。声明顺序就是滤镜条的顺序。
enum FilterPreset: String, CaseIterable, Sendable {
    case original
    // ── 人像清新：醒图 / 美图秀秀 / 黄油相机 ─────────────────────────
    case cream, clear, coolWhite = "cool_white", magazine, peach
    // ── 胶片：VSCO / Dazz / 经典胶卷 ─────────────────────────────
    case analogFade = "analog_fade", vividFilm = "vivid_film", mutedWarm = "muted_warm", coolFade = "cool_fade"
    case warmNegative = "warm_negative", golden, chrome, classicNeg = "classic_neg", ccd, instant
    case retro35 = "retro_35", tungsten
    // ── 电影氛围 ─────────────────────────────────────────────
    case tealOrange = "teal_orange", moody, hongKong = "hong_kong", neon, vivid
    // ── 黑白 ────────────────────────────────────────────────
    case mono, noir, silver, sepia

    var key: String { rawValue }

    var group: FilterGroup? {
        switch self {
        case .original: return nil
        case .cream, .clear, .coolWhite, .magazine, .peach: return .portrait
        case .analogFade, .vividFilm, .mutedWarm, .coolFade, .warmNegative, .golden, .chrome,
             .classicNeg, .ccd, .instant, .retro35, .tungsten: return .film
        case .tealOrange, .moody, .hongKong, .neon, .vivid: return .cinema
        case .mono, .noir, .silver, .sepia: return .mono
        }
    }

    var vignette: Float {
        switch self {
        case .golden: return 0.2
        case .ccd: return 0.15
        case .instant: return 0.35
        case .retro35: return 0.25
        case .tealOrange: return 0.15
        case .moody: return 0.3
        case .hongKong: return 0.2
        case .noir: return 0.35
        default: return 0
        }
    }

    var grain: Float {
        switch self {
        case .analogFade: return 0.15
        case .mutedWarm: return 0.12
        case .warmNegative: return 0.18
        case .golden: return 0.25
        case .classicNeg: return 0.15
        case .ccd: return 0.12
        case .instant: return 0.1
        case .retro35: return 0.45
        case .tungsten: return 0.3
        case .hongKong: return 0.2
        case .noir: return 0.2
        case .silver: return 0.35
        default: return 0
        }
    }

    var label: LocalizedKey {
        switch self {
        case .original: return .imageFilterPresetOriginal
        case .cream: return .imageFilterPresetCream
        case .clear: return .imageFilterPresetClear
        case .coolWhite: return .imageFilterPresetCoolWhite
        case .magazine: return .imageFilterPresetMagazine
        case .peach: return .imageFilterPresetPeach
        case .analogFade: return .imageFilterPresetAnalogFade
        case .vividFilm: return .imageFilterPresetVividFilm
        case .mutedWarm: return .imageFilterPresetMutedWarm
        case .coolFade: return .imageFilterPresetCoolFade
        case .warmNegative: return .imageFilterPresetWarmNegative
        case .golden: return .imageFilterPresetGolden
        case .chrome: return .imageFilterPresetChrome
        case .classicNeg: return .imageFilterPresetClassicNeg
        case .ccd: return .imageFilterPresetCcd
        case .instant: return .imageFilterPresetInstant
        case .retro35: return .imageFilterPresetRetro35
        case .tungsten: return .imageFilterPresetTungsten
        case .tealOrange: return .imageFilterPresetTealOrange
        case .moody: return .imageFilterPresetMoody
        case .hongKong: return .imageFilterPresetHongKong
        case .neon: return .imageFilterPresetNeon
        case .vivid: return .imageFilterPresetVivid
        case .mono: return .imageFilterPresetMono
        case .noir: return .imageFilterPresetNoir
        case .silver: return .imageFilterPresetSilver
        case .sepia: return .imageFilterPresetSepia
        }
    }

    var ordinal: Int { Self.allCases.firstIndex(of: self)! }

    static func fromKey(_ key: String?) -> FilterPreset { key.flatMap(FilterPreset.init(rawValue:)) ?? .original }

    // swiftlint:disable:next function_body_length
    func ops() -> [ColorOp] {
        typealias O = FilterOps
        typealias C = FilterCurve
        switch self {
        case .original:
            return []

        /// 奶油：托起的黑位 + 柔和高光 + 偏暖偏粉、低饱和（醒图「奶油」系）。
        case .cream:
            return [
                O.curves(master: C.of(0, 26, 64, 80, 128, 142, 192, 203, 255, 246)),
                O.warmth(0.22), O.tint(0.12), O.saturation(0.84),
                O.splitTone(0xC8A08C, 0.10, 0xFFD2B4, 0.12),
            ]

        /// 清透：提曝光、压高光留层次、补阴影，微冷，通透干净。
        case .clear:
            return [
                O.exposure(0.22), O.highlights(-0.35), O.shadows(0.3),
                O.warmth(-0.15), O.vibrance(0.25),
                O.curves(master: C.of(0, 4, 70, 66, 180, 190, 255, 255)),
            ]

        /// 冷白：提亮、去黄，微洋红防发绿，冷白皮。
        case .coolWhite:
            return [
                O.exposure(0.14), O.highlights(-0.2), O.warmth(-0.4), O.tint(0.06), O.saturation(0.86),
                O.curves(master: C.of(0, 6, 128, 136, 255, 255)),
            ]

        /// 日杂：褪色 + 青绿暗部 + 低饱和，日系杂志感。
        case .magazine:
            return [
                O.fade(0.4), O.exposure(0.12), O.saturation(0.78),
                O.mix(0.95, 0.05, 0, 0, 1.02, 0, 0, 0.04, 0.98),
                O.splitTone(0x5FA8A0, 0.16, 0xFFF0D8, 0.06),
            ]

        /// 蜜桃：暖粉高光、自然饱和度拉起，元气少女感。
        case .peach:
            return [
                O.exposure(0.1), O.vibrance(0.3), O.tint(0.18), O.warmth(0.12),
                O.splitTone(0xB07890, 0.08, 0xFFB8B0, 0.18),
                O.curves(master: C.of(0, 10, 128, 134, 255, 252)),
            ]

        /// 褪色胶片（VSCO A6）：大幅褪色、低对比、微暖、各通道黑位抬起。
        case .analogFade:
            return [
                O.curves(
                    master: C.of(0, 34, 60, 72, 128, 132, 200, 196, 255, 236),
                    b: C.of(0, 18, 255, 240)
                ),
                O.saturation(0.78), O.warmth(0.1),
            ]

        /// 鲜亮胶片（VSCO C1）：明亮、通透、饱和，带一点暖。
        case .vividFilm:
            return [
                O.exposure(0.05), O.vibrance(0.35), O.saturation(1.1), O.warmth(0.08),
                O.curves(master: C.of(0, 8, 64, 58, 192, 200, 255, 252)),
            ]

        /// 暖黄哑光（VSCO M5）：偏黄、褪色、低饱和的复古日常。
        case .mutedWarm:
            return [
                O.fade(0.32), O.saturation(0.72),
                O.curves(r: C.of(0, 6, 128, 134, 255, 252), b: C.of(0, 20, 128, 112, 255, 220)),
            ]

        /// 冷调褪色（VSCO HB2）：冷、蓝色暗部、褪色。
        case .coolFade:
            return [
                O.fade(0.28), O.warmth(-0.35), O.saturation(0.8),
                O.splitTone(0x4870A8, 0.18, 0xE8F0FF, 0.05),
            ]

        /// 暖调负片（人像负片）：暖肤色、柔和对比、粉彩色。
        case .warmNegative:
            return [
                O.curves(
                    master: C.of(0, 16, 64, 66, 128, 134, 192, 198, 255, 245),
                    r: C.of(0, 4, 128, 136, 255, 255),
                    b: C.of(0, 12, 128, 122, 255, 238)
                ),
                O.saturation(0.86), O.splitTone(0x6C8C78, 0.08, 0xFFD8B8, 0.1),
            ]

        /// 金色胶片（消费级暖黄胶卷）：浓郁的金黄、偏高饱和，暗角 + 颗粒。
        case .golden:
            return [
                O.warmth(0.45), O.tint(0.16), O.saturation(1.12),
                O.curves(
                    master: C.of(0, 10, 64, 60, 192, 202, 255, 250),
                    b: C.of(0, 8, 128, 112, 255, 226)
                ),
                O.splitTone(0x806030, 0.08, 0xFFC860, 0.14),
            ]

        /// 低饱和正片（经典铬色）：硬朗影调、低饱和、蓝色偏青。
        case .chrome:
            return [
                O.saturation(0.68),
                O.mix(1, 0, 0, 0, 1, 0, 0, 0.12, 0.88),
                O.curves(master: C.of(0, 6, 60, 48, 128, 128, 196, 206, 255, 250)),
                O.splitTone(0x3C7080, 0.12, 0xF0D8B0, 0.06),
            ]

        /// 怀旧负片（经典负片）：青绿暗部、偏红的亮部、硬对比。
        case .classicNeg:
            return [
                O.saturation(0.84),
                O.curves(
                    master: C.of(0, 12, 64, 54, 192, 206, 255, 246),
                    r: C.of(0, 0, 128, 124, 255, 255),
                    g: C.of(0, 10, 128, 130, 255, 244)
                ),
                O.splitTone(0x2E8070, 0.22, 0xF0A890, 0.1),
            ]

        /// CCD（Dazz 数码相机）：冷调、硬对比、高光早早溢出、微洋红，像千禧年卡片机直出。
        case .ccd:
            return [
                O.exposure(0.06), O.warmth(-0.22), O.tint(0.1), O.saturation(1.08),
                O.curves(master: C.of(0, 0, 56, 42, 160, 176, 234, 252, 255, 255)),
            ]

        /// 拍立得：褪色、青色暗部、暖色高光、明显暗角。
        case .instant:
            return [
                O.exposure(0.1), O.fade(0.3), O.saturation(0.85),
                O.splitTone(0x30A0B0, 0.2, 0xFFD090, 0.14),
            ]

        /// 复古胶卷（Dazz CPM35）：暖、褪色、黄绿暗部、颗粒感重。
        case .retro35:
            return [
                O.warmth(0.3), O.fade(0.22), O.saturation(0.9),
                O.curves(master: C.of(0, 10, 64, 58, 192, 200, 255, 244)),
                O.splitTone(0x8A9050, 0.14, 0xFFD8A0, 0.08),
            ]

        /// 钨丝灯（灯光片）：整体偏蓝、亮部回暖、夜景电影感。
        case .tungsten:
            return [
                O.warmth(-0.65), O.tint(0.06),
                O.curves(master: C.of(0, 8, 64, 56, 192, 204, 255, 252)),
                O.splitTone(0x2050A0, 0.12, 0xFF9860, 0.22),
            ]

        /// 电影青橙：暗部青、亮部橙，S 形对比。
        case .tealOrange:
            return [
                O.curves(master: C.of(0, 4, 64, 54, 192, 206, 255, 252)),
                O.splitTone(0x00A0B0, 0.4, 0xFF9040, 0.3),
                O.saturation(1.05),
            ]

        /// 氛围感：压暗、暖高光冷暗部、低饱和、轻褪色。
        case .moody:
            return [
                O.exposure(-0.18), O.saturation(0.74), O.fade(0.15),
                O.splitTone(0x405878, 0.2, 0xE8B080, 0.14),
                O.curves(master: C.of(0, 0, 80, 70, 200, 204, 255, 240)),
            ]

        /// 港风：暖红、绿色暗部、高对比高饱和，九十年代港片。
        case .hongKong:
            return [
                O.warmth(0.3), O.saturation(1.15),
                O.curves(master: C.of(0, 6, 64, 50, 192, 210, 255, 250)),
                O.splitTone(0x30804A, 0.22, 0xFF7050, 0.12),
            ]

        /// 霓虹：洋红与青的赛博夜色。
        case .neon:
            return [
                O.contrast(1.1), O.saturation(1.25),
                O.splitTone(0x00C8FF, 0.3, 0xFF40C0, 0.25),
            ]

        /// 鲜艳：对比 + 饱和，插画色彩更跳。
        case .vivid:
            return [O.contrast(1.08), O.vibrance(0.3), O.saturation(1.2)]

        case .mono:
            return [O.grayscale]

        /// 高反差黑白：深黑亮白 + 暗角。
        case .noir:
            return [
                O.grayscale,
                O.curves(master: C.of(0, 0, 70, 42, 128, 128, 186, 214, 255, 255)),
            ]

        /// 银盐黑白：柔和中间调、微暖的相纸色、细颗粒。
        case .silver:
            return [
                O.grayscale,
                O.curves(master: C.of(0, 14, 64, 64, 192, 198, 255, 248)),
                O.splitTone(0x605040, 0.06, 0xFFF0D8, 0.06),
            ]

        /// 怀旧：经典棕褐。
        case .sepia:
            return [O.sepia]
        }
    }
}

/// 手动调节项。`bipolar` 的滑条从中间往两边拉（−100…100），否则 0…100。
enum FilterAdjust: CaseIterable, Sendable {
    case brightness, contrast, saturation, warmth, tint, highlights, shadows, fade, vignette, grain

    var bipolar: Bool {
        switch self {
        case .fade, .vignette, .grain: return false
        default: return true
        }
    }

    var label: LocalizedKey {
        switch self {
        case .brightness: return .imageFilterAdjustBrightness
        case .contrast: return .imageFilterAdjustContrast
        case .saturation: return .imageFilterAdjustSaturation
        case .warmth: return .imageFilterAdjustWarmth
        case .tint: return .imageFilterAdjustTint
        case .highlights: return .imageFilterAdjustHighlights
        case .shadows: return .imageFilterAdjustShadows
        case .fade: return .imageFilterAdjustFade
        case .vignette: return .imageFilterAdjustVignette
        case .grain: return .imageFilterAdjustGrain
        }
    }

    var ordinal: Int { Self.allCases.firstIndex(of: self)! }
}

/// 页面上的全部编辑状态。`intensity` 与 `adjust` 都是滑条上的整数（强度 0–100，调节 −100–100），
/// 整数存储让「同一组参数」可以直接比较，导出缓存也按它判断是否要重算。
struct FilterState: Equatable, Sendable {
    var preset: FilterPreset = .original
    var intensity: Int = 100
    var adjust: [Int] = Array(repeating: 0, count: FilterAdjust.allCases.count)

    subscript(a: FilterAdjust) -> Int { adjust[a.ordinal] }

    func with(_ a: FilterAdjust, _ value: Int) -> FilterState {
        var copy = self
        copy.adjust[a.ordinal] = value
        return copy
    }

    var isModified: Bool { (preset != .original && intensity > 0) || adjust.contains { $0 != 0 } }

    private var strength: Float { preset == .original ? 0 : Float(intensity) / 100 }

    /// 手动调节里的颜色部分（暗角、颗粒是空间效果，单独交给内核），按修图 App 的惯常顺序。
    func adjustOps() -> [ColorOp] {
        func v(_ a: FilterAdjust) -> Float { Float(self[a]) / 100 }
        var ops: [ColorOp] = []
        if self[.brightness] != 0 { ops.append(FilterOps.brightness(v(.brightness))) }
        if self[.contrast] != 0 {
            // 往低拉收得慢一点：−100 时还留 40% 对比，不会糊成一片灰。
            let c = v(.contrast)
            ops.append(FilterOps.contrast(c > 0 ? 1 + c * 0.7 : 1 + c * 0.6))
        }
        if self[.highlights] != 0 { ops.append(FilterOps.highlights(v(.highlights))) }
        if self[.shadows] != 0 { ops.append(FilterOps.shadows(v(.shadows))) }
        if self[.saturation] != 0 { ops.append(FilterOps.saturation(1 + v(.saturation))) }
        if self[.warmth] != 0 { ops.append(FilterOps.warmth(v(.warmth))) }
        if self[.tint] != 0 { ops.append(FilterOps.tint(v(.tint))) }
        if self[.fade] != 0 { ops.append(FilterOps.fade(v(.fade))) }
        return ops
    }

    /// 颜色部分是否等同原图：是的话内核跳过查表。
    var colorIsIdentity: Bool { strength == 0 && adjustOps().isEmpty }

    /// 最终暗角强度 0–1：滤镜自带的按强度缩放，再叠上手动调节。
    func vignette() -> Float { min(max(preset.vignette * strength + Float(self[.vignette]) / 100, 0), 1) }

    /// 最终颗粒强度 0–1。
    func grain() -> Float { min(max(preset.grain * strength + Float(self[.grain]) / 100, 0), 1) }

    /// 滤镜部分的强度 0–1（原图恒为 0）。
    func presetStrength() -> Float { strength }

    /// 成品文件名里标识这组参数的那一截。纯滤镜满强度就是滤镜 key（`cream`），改过强度或调节再带 6 位参数指纹
    /// （`cream_3fa2c1`）：同名必是同一张图。指纹沿用 Java `String.hashCode`，与 Android 导出的同名成品逐字一致。
    func fileTag() -> String {
        // 原图没有强度可言，强度滑条的残值不该让两张一样的原图起不同的名字。
        let effectiveIntensity = preset == .original ? 100 : intensity
        if effectiveIntensity == 100 && adjust.allSatisfy({ $0 == 0 }) { return preset.key }
        let fingerprint = Self.javaHashCode("\(effectiveIntensity):" + adjust.map(String.init).joined(separator: ","))
        let hex = String(UInt32(bitPattern: fingerprint), radix: 16)
        return preset.key + "_" + String((String(repeating: "0", count: max(0, 8 - hex.count)) + hex).prefix(6))
    }

    /// Java `String.hashCode`：UTF-16 码元逐个 `h = 31h + c`，Int32 溢出回绕。
    static func javaHashCode(_ s: String) -> Int32 {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return h
    }
}

/// 把调色流水线采样成 3D LUT（`size`³ 个格点 × RGB，0–1，r 变化最快），以及暗角曲线。
/// 预设的格点结果按 key 缓存最近几只：拖强度 / 调节滑条时只重算「插值 + 调节」，不重跑整条滤镜。
enum FilterLut {

    static let size = 33

    /// 内核按 d² 查暗角乘子的精度。
    static let vignetteLutSize = 1024

    private static let vignetteInner: Float = 0.35
    private static let vignetteMaxDarkness: Float = 0.72

    /// 最近用过的三只预设（LRU，末位最新）。渲染跑在后台串行队列上，缩略图与预览可能交错访问，加锁。
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var presetCache: [(FilterPreset, [Float])] = []

    private static func cached(_ preset: FilterPreset) -> [Float]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let i = presetCache.firstIndex(where: { $0.0 == preset }) else { return nil }
        let entry = presetCache.remove(at: i)
        presetCache.append(entry)
        return entry.1
    }

    private static func store(_ preset: FilterPreset, _ grid: [Float]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        presetCache.removeAll { $0.0 == preset }
        presetCache.append((preset, grid))
        if presetCache.count > 3 { presetCache.removeFirst() }
    }

    /// 恒等 LUT：每个格点就是自己的坐标。
    static let identity: [Float] = sample([])

    /// 只采样一只预设（滤镜条缩略图用，满强度、不带调节）。不进缓存，免得一次挤掉正在用的。
    static func forPreset(_ preset: FilterPreset) -> [Float]? {
        if preset == .original { return nil }
        return cachedPeek(preset) ?? sample(preset.ops())
    }

    private static func cachedPeek(_ preset: FilterPreset) -> [Float]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return presetCache.first { $0.0 == preset }?.1
    }

    /// 整个状态的 LUT；颜色等同原图时返回 nil。
    static func forState(_ state: FilterState) -> [Float]? {
        if state.colorIsIdentity { return nil }
        let t = state.presetStrength()
        let base: [Float]
        if t > 0 {
            let grid = cached(state.preset) ?? {
                let g = sample(state.preset.ops())
                store(state.preset, g)
                return g
            }()
            if t >= 1 {
                base = grid
            } else {
                let id = identity
                base = (0..<grid.count).map { id[$0] + (grid[$0] - id[$0]) * t }
            }
        } else {
            base = identity
        }
        let ops = state.adjustOps()
        if ops.isEmpty { return base }
        var out = base
        var c = FilterRGB(r: 0, g: 0, b: 0)
        for i in stride(from: 0, to: out.count, by: 3) {
            c.r = out[i]; c.g = out[i + 1]; c.b = out[i + 2]
            for op in ops { op(&c) }
            out[i] = min(max(c.r, 0), 1); out[i + 1] = min(max(c.g, 0), 1); out[i + 2] = min(max(c.b, 0), 1)
        }
        return out
    }

    /// 在 `size`³ 个格点上跑一遍 `ops`，结果夹回 0–1。
    static func sample(_ ops: [ColorOp]) -> [Float] {
        let n = size
        var out = [Float](repeating: 0, count: n * n * n * 3)
        var c = FilterRGB(r: 0, g: 0, b: 0)
        var i = 0
        let step = Float(n) - 1
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    c.r = Float(r) / step; c.g = Float(g) / step; c.b = Float(b) / step
                    for op in ops { op(&c) }
                    out[i] = min(max(c.r, 0), 1)
                    out[i + 1] = min(max(c.g, 0), 1)
                    out[i + 2] = min(max(c.b, 0), 1)
                    i += 3
                }
            }
        }
        return out
    }

    /// 距中心 `d`（半对角线归一化，四角 = 1）处的暗化比例：smoothstep 过渡，没有可见的环。
    static func vignetteDarkness(_ d: Float, _ strength: Float) -> Float {
        if strength <= 0 { return 0 }
        let t = min(max((d - vignetteInner) / (1 - vignetteInner), 0), 1)
        return vignetteMaxDarkness * min(strength, 1) * t * t * (3 - 2 * t)
    }

    /// 按 d² 均匀采样的颜色乘子（1 = 不变暗）；强度为 0 返回 nil。用 d² 做下标，内核不用开方。
    static func vignette(_ strength: Float) -> [Float]? {
        if strength <= 0 { return nil }
        return (0...vignetteLutSize).map { i in
            1 - vignetteDarkness((Float(i) / Float(vignetteLutSize)).squareRoot(), strength)
        }
    }
}
