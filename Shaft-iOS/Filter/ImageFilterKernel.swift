import CoreGraphics
import Foundation

/// 一张 RGBA8888 预乘位图（字节序 R, G, B, A —— 与 Android `ARGB_8888` 的内存布局相同），sRGB。
/// 内存归它自己管；`makeImage()` 零拷贝地把这块内存交给 CGImage，图像活多久内存就留多久。
/// 所以交出去以后**不能再写**：滤镜每渲一帧都写进新的一张，见 `ImageFilterModel`。
final class FilterBitmap: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: UnsafeMutablePointer<UInt8>

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytesPerRow = width * 4
        pixels = .allocate(capacity: bytesPerRow * height)
        pixels.initialize(repeating: 0, count: bytesPerRow * height)
    }

    deinit { pixels.deallocate() }

    /// 把 `image` 按 `width` × `height` 画进一张新位图（双线性高质量插值），任何源格式 —— 16 位 PNG、
    /// 灰度、P3 —— 都在这里统一成 8 位 sRGB 预乘，内核只认这一种。
    static func draw(_ image: CGImage, width: Int, height: Int) -> FilterBitmap? {
        guard width > 0, height > 0 else { return nil }
        let bitmap = FilterBitmap(width: width, height: height)
        guard let ctx = CGContext(
            data: bitmap.pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bitmap.bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap
    }

    /// 从自己里面裁一块再缩放成新位图（滤镜条缩略图）。
    func cropped(x: Int, y: Int, side: Int, to size: Int) -> FilterBitmap? {
        guard let image = makeImage()?.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else { return nil }
        return Self.draw(image, width: size, height: size)
    }

    func makeImage() -> CGImage? {
        let retained = Unmanaged.passRetained(self)
        guard let provider = CGDataProvider(
            dataInfo: retained.toOpaque(), data: pixels, size: bytesPerRow * height,
            releaseData: { info, _, _ in
                if let info { Unmanaged<FilterBitmap>.fromOpaque(info).release() }
            }
        ) else {
            retained.release()
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

/// 图片滤镜内核：把采样好的 3D LUT（+ 暗角 + 颗粒）作用到 `FilterBitmap` 上 ——
/// Pixiv-Shaft `app/src/main/cpp/shaft_image_filter.cpp` 的逐行移植。预览（屏幕尺寸的小图，每次拖滑条）
/// 和导出（全分辨率，保存 / 分享时一次）走的是同一个函数，所以预览与成品逐像素一致；
/// 整数定点运算与 C++ 内核逐位相同，同一张图同一组参数在两端渲出来的像素一样。
///
/// 快在这几件事：
/// 1. 滤镜、强度、调节先采样成**一只** 33³ LUT，像素侧无论滤镜多复杂都只是一次查表；
/// 2. 四面体插值（4 个格点，不是三线性的 8 个），整数定点、无分支：LUT 存 Q6，通道分数存 Q8，
///    每个通道值落在哪个格、分数多少预先打成 256 项表，像素循环里没有除法和浮点；
///    和左边像素同色（插画的平涂区）直接复用上一次的结果；
/// 3. 暗角、颗粒与查表融在同一遍里：每个像素只读一次、写一次；
/// 4. 行带（16 行）分给各线程，线程数按像素量定（每线程 ≥ 512K 像素），屏幕尺寸的预览不为起线程付出比计算还多的时间。
///
/// 位图是预乘的：不透明像素（绝大多数插画）直接算；带透明的像素先反乘、算完再乘回。
enum ImageFilterKernel {

    private static let lutFracBits = 8    // 通道分数 Q8（0–256）
    private static let lutValueBits = 6   // LUT 值 Q6（0–255 × 64）
    private static let bandRows = 16
    private static let pixelsPerThread = 512 * 1024
    /// 颗粒的格子边长按短边换算：短边 ≤ 900px 时一像素一颗，更大的图颗粒等比放大，
    /// 让屏幕尺寸的预览和几千像素的成品看起来是同一种「颗粒感」。
    private static let grainDensity = 900
    /// 满强度颗粒在中间调上的最大振幅（0–255 域）。
    private static let grainAmplitude: Float = 22

    enum Failure: Error { case badArgs, badBitmap }

    /// 把 `state` 从 `src` 渲染到 `dst`（可以是同一张，原地改写）。两张须同尺寸。
    /// `lut` 允许调用方传入已经算好的 LUT（`FilterLut.forState` / `forPreset`），省一次采样；
    /// `vignette` / `grain` 默认取 `state` 的，单独比颜色时可以置 0。动像素前完成全部校验，不会留下半张图。
    static func render(_ src: FilterBitmap, into dst: FilterBitmap, state: FilterState,
                       vignette: Float? = nil, grain: Float? = nil) throws {
        try render(src, into: dst, state: state, lut: FilterLut.forState(state), vignette: vignette, grain: grain)
    }

    static func render(_ src: FilterBitmap, into dst: FilterBitmap, state: FilterState, lut: [Float]?,
                       vignette: Float? = nil, grain: Float? = nil) throws {
        try render(src, into: dst, lut: lut, lutSize: FilterLut.size,
                   vignetteLut: FilterLut.vignette(vignette ?? state.vignette()), grain: grain ?? state.grain())
    }

    /// `lut` 为 nil 表示颜色不变；`vignetteLut` 为 nil 表示无暗角；`grain` ≤ 0 表示无颗粒。
    static func render(_ src: FilterBitmap, into dst: FilterBitmap, lut: [Float]?, lutSize: Int,
                       vignetteLut: [Float]?, grain: Float) throws {
        guard src.width == dst.width, src.height == dst.height, src.width > 0, src.height > 0 else {
            throw Failure.badBitmap
        }
        let k = Kernel()
        if let lut, !k.loadLut(lut, size: lutSize) { throw Failure.badArgs }
        if let vignetteLut {
            guard vignetteLut.count >= 2 else { throw Failure.badArgs }
            k.vlut = vignetteLut.map { UInt16((min(max($0, 0), 1) * 256).rounded()) }
            k.vignetteOn = true
        }
        if grain > 0 {
            k.grainOn = true
            k.grainAmpQ8 = Int(Int32((min(grain, 1) * grainAmplitude * 256).rounded()))
        }
        let w = src.width, h = src.height
        if k.vignetteOn {
            // 与 FilterLut 同一几何：圆心在图中心，半径是半对角线（四角 d = 1）。
            k.cx = Float(w) * 0.5
            k.cy = Float(h) * 0.5
            k.invR2 = 1 / (k.cx * k.cx + k.cy * k.cy)
        }
        k.grainCell = max(1, min(w, h) / grainDensity)
        run(k, src: src, dst: dst)
    }

    // MARK: - 内核

    private final class Kernel: @unchecked Sendable {
        // 3D LUT
        var lutOn = false
        var lut: [Int16] = []          // n³ × 4（r, g, b, pad），Q6
        // 每个通道值 → 该通道在 LUT 里的元素偏移（已乘好步长与 4 个分量），像素循环里只剩三次加法。
        var offR = [Int](repeating: 0, count: 256)
        var offG = [Int](repeating: 0, count: 256)
        var offB = [Int](repeating: 0, count: 256)
        var stepG = 0, stepB = 0
        var frac = [Int](repeating: 0, count: 256)

        // 暗角
        var vignetteOn = false
        var vlut: [UInt16] = []        // Q8 乘子（0–256），按 d² 采样
        var cx: Float = 0, cy: Float = 0, invR2: Float = 0

        // 颗粒
        var grainOn = false
        var grainAmpQ8 = 0             // 振幅 × 256
        var grainCell = 1

        func loadLut(_ values: [Float], size: Int) -> Bool {
            guard size >= 2, size <= 65 else { return false }
            let count = size * size * size
            guard values.count == count * 3 else { return false }
            let scale = Float(255) * Float(1 << ImageFilterKernel.lutValueBits)
            lut = [Int16](repeating: 0, count: count * 4)
            for i in 0..<count {
                for c in 0..<3 {
                    lut[i * 4 + c] = Int16((min(max(values[i * 3 + c], 0), 1) * scale).rounded())
                }
            }
            stepG = 4 * size
            stepB = 4 * size * size
            for v in 0..<256 {
                let pos = Float(v) * Float(size - 1) / 255
                var i = Int(pos)
                var f = Int(((pos - Float(i)) * 256).rounded())
                if i >= size - 1 { i = size - 2; f = 256 }
                offR[v] = 4 * i
                offG[v] = stepG * i
                offB[v] = stepB * i
                frac[v] = f
            }
            lutOn = true
            return true
        }
    }

    @inline(__always)
    private static func hash2(_ x: UInt32, _ y: UInt32) -> UInt32 {
        var h = (x &* 0x8DA6_B343) ^ (y &* 0xD816_3841)
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return h
    }

    /// 颗粒噪声 −128…127。格子大于 1px 时在四角之间双线性插值，颗粒是软的而不是方块。
    @inline(__always)
    private static func grainNoise(_ cell: Int, _ x: Int, _ y: Int) -> Int {
        if cell == 1 { return Int(hash2(UInt32(x), UInt32(y)) & 0xFF) - 128 }
        let gx = UInt32(x / cell), gy = UInt32(y / cell)
        let fx = ((x % cell) << 8) / cell
        let fy = ((y % cell) << 8) / cell
        let a = Int(hash2(gx, gy) & 0xFF)
        let b = Int(hash2(gx &+ 1, gy) & 0xFF)
        let c = Int(hash2(gx, gy &+ 1) & 0xFF)
        let d = Int(hash2(gx &+ 1, gy &+ 1) & 0xFF)
        let top = (a << 8) + (b - a) * fx
        let bottom = (c << 8) + (d - c) * fx
        return (((top << 8) + (bottom - top) * fy) >> 16) - 128
    }

    private static func run(_ k: Kernel, src: FilterBitmap, dst: FilterBitmap) {
        let width = src.width, height = src.height
        var dx2 = [Float]()
        if k.vignetteOn {
            dx2 = (0..<width).map { x in
                let dx = Float(x) + 0.5 - k.cx
                return dx * dx * k.invR2
            }
        }
        let bands = (height + bandRows - 1) / bandRows
        // 起线程、唤醒睡着的核心都要毫秒级：活儿少的时候（预览草稿、缩略图）多开线程只会更慢。
        // 按像素数分：每个线程至少分到 pixelsPerThread，24MP 的导出才会铺满所有核心。
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let byWork = max(1, width * height / pixelsPerThread)
        let threads = min(cores, byWork, bands)
        k.lut.withUnsafeBufferPointer { lut in
        k.offR.withUnsafeBufferPointer { offR in
        k.offG.withUnsafeBufferPointer { offG in
        k.offB.withUnsafeBufferPointer { offB in
        k.frac.withUnsafeBufferPointer { frac in
        k.vlut.withUnsafeBufferPointer { vlut in
        dx2.withUnsafeBufferPointer { dx2 in
            let t = Tables(lut: lut, offR: offR, offG: offG, offB: offB, frac: frac, vlut: vlut, dx2: dx2)
            let work = { (worker: Int) in
                // 行带交错分给各线程：大图上各线程跑完的时间差不多。
                var band = worker
                while band < bands {
                    let end = min(height, (band + 1) * bandRows)
                    for y in (band * bandRows)..<end {
                        processRow(k, t, src.pixels + y * src.bytesPerRow, dst.pixels + y * dst.bytesPerRow, width, y)
                    }
                    band += threads
                }
            }
            if threads == 1 { work(0) } else { DispatchQueue.concurrentPerform(iterations: threads, execute: work) }
        }}}}}}}
    }

    private struct Tables {
        let lut: UnsafeBufferPointer<Int16>
        let offR: UnsafeBufferPointer<Int>
        let offG: UnsafeBufferPointer<Int>
        let offB: UnsafeBufferPointer<Int>
        let frac: UnsafeBufferPointer<Int>
        let vlut: UnsafeBufferPointer<UInt16>
        let dx2: UnsafeBufferPointer<Float>
    }

    /// 四面体插值：按三个通道分数的大小关系落进 6 个四面体之一，只取 4 个格点。
    ///
    /// 写成无分支：把分数排成 f1 ≥ f2 ≥ f3，最大分数所在的轴决定第二个顶点、最小分数所在的轴决定第三个顶点
    /// （= 对角顶点退回最小轴一步）。并列时按 r → g → b 取最大轴、按 b → g → r 取最小轴，两者永远不会是同一根轴。
    @inline(__always)
    private static func lutLookup(_ k: Kernel, _ t: Tables, _ r: Int, _ g: Int, _ b: Int) -> (Int, Int, Int) {
        let fr = t.frac[r], fg = t.frac[g], fb = t.frac[b]
        let c000 = t.offR[r] + t.offG[g] + t.offB[b]
        let sr = 4, sg = k.stepG, sb = k.stepB
        let c111 = c000 + sr + sg + sb
        let f1 = max(fr, max(fg, fb))
        let f3 = min(fr, min(fg, fb))
        let f2 = fr + fg + fb - f1 - f3
        let sHi = fr == f1 ? sr : (fg == f1 ? sg : sb)
        let sLo = fb == f3 ? sb : (fg == f3 ? sg : sr)
        let p1 = c000 + sHi
        let p2 = c111 - sLo
        let w0 = 256 - f1, w1 = f1 - f2, w2 = f2 - f3, w3 = f3
        let shift = lutFracBits + lutValueBits
        let round = 1 << (shift - 1)
        let l = t.lut
        @inline(__always) func channel(_ i: Int) -> Int {
            (Int(l[c000 + i]) * w0 + Int(l[p1 + i]) * w1 + Int(l[p2 + i]) * w2 + Int(l[c111 + i]) * w3 + round) >> shift
        }
        return (channel(0), channel(1), channel(2))
    }

    @inline(__always)
    private static func clampU8(_ v: Int) -> Int { min(max(v, 0), 255) }

    private static func processRow(_ k: Kernel, _ t: Tables, _ src: UnsafeMutablePointer<UInt8>,
                                   _ dst: UnsafeMutablePointer<UInt8>, _ width: Int, _ y: Int) {
        // 暗角：这一行的 dy² 只算一次，逐像素只剩加法 + 查表，不开方。
        var dy2: Float = 0
        var vlast = 0
        var vscale: Float = 0
        if k.vignetteOn {
            let dy = Float(y) + 0.5 - k.cy
            dy2 = dy * dy * k.invR2
            vlast = t.vlut.count - 1
            vscale = Float(vlast)
        }
        var lastKey = -1  // 不可能的颜色：第一个像素必然查表
        var last = (0, 0, 0)
        for x in 0..<width {
            let s = src + x * 4
            let d = dst + x * 4
            let a = Int(s[3])
            if a == 0 {
                // 全透明：预乘后的颜色恒为 0，算什么都一样。
                if d != s { d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3] }
                continue
            }
            var r = Int(s[0]), g = Int(s[1]), b = Int(s[2])
            if a < 255 {
                r = min(255, (r * 255 + a / 2) / a)
                g = min(255, (g * 255 + a / 2) / a)
                b = min(255, (b * 255 + a / 2) / a)
            }
            if k.lutOn {
                // 插画里大片平涂：和上一个像素同色就直接复用查表结果。
                let key = r | g << 8 | b << 16
                if key != lastKey {
                    last = lutLookup(k, t, r, g, b)
                    lastKey = key
                }
                r = last.0; g = last.1; b = last.2
            }
            if k.vignetteOn {
                let i = Int(Int32((t.dx2[x] + dy2) * vscale + 0.5))
                let v = Int(t.vlut[min(i, vlast)])
                r = (r * v + 128) >> 8
                g = (g * v + 128) >> 8
                b = (b * v + 128) >> 8
            }
            if k.grainOn {
                // 颗粒集中在中间调：黑位和高光保持干净，像真胶片那样。
                let l = (r * 77 + g * 150 + b * 29) >> 8
                let w = (l * (255 - l)) >> 6  // 0–254，中灰处最大
                let delta = (grainNoise(k.grainCell, x, y) * k.grainAmpQ8 / 128 * w) >> 16
                r += delta; g += delta; b += delta
            }
            r = clampU8(r); g = clampU8(g); b = clampU8(b)
            if a < 255 {
                r = (r * a + 127) / 255
                g = (g * a + 127) / 255
                b = (b * a + 127) / 255
            }
            d[0] = UInt8(r)
            d[1] = UInt8(g)
            d[2] = UInt8(b)
            d[3] = UInt8(a)
        }
    }
}
