import CryptoKit
import XCTest
@testable import Shaft_iOS

/// 图片滤镜：颜色模型（Android `ImageFiltersTest`）、内核（Android `NativeImageFilterInstrumentedTest`），
/// 以及与 Android 原版的逐字节对拍 —— `ImageFilterFixtures/golden.txt` 由 `scripts/gen-image-filter-golden.py`
/// 用 Android 的 Kotlin 颜色模型 + C++ 内核渲出来，这里用 Swift 移植渲同一批用例，SHA-256 必须一致。
final class ImageFilterTests: XCTestCase {

    private let n = FilterLut.size

    private func at(_ lut: [Float], _ r: Int, _ g: Int, _ b: Int) -> [Float] {
        let i = ((b * n + g) * n + r) * 3
        return [lut[i], lut[i + 1], lut[i + 2]]
    }

    // MARK: 颜色模型（ImageFiltersTest.kt）

    func testIdentityLutMapsEachGridPointToItselfRVaryingFastest() {
        let id = FilterLut.identity
        XCTAssertEqual(id.count, n * n * n * 3)
        XCTAssertEqual(at(id, n - 1, 0, 0), [1, 0, 0])
        XCTAssertEqual(at(id, 0, 0, n - 1), [0, 0, 1])
        let mid = at(id, 16, 8, 24)
        XCTAssertEqual(mid[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(mid[1], 0.25, accuracy: 1e-6)
        XCTAssertEqual(mid[2], 0.75, accuracy: 1e-6)
    }

    func testUntouchedStateNeedsNoColourWork() {
        XCTAssertNil(FilterLut.forState(FilterState()))
        XCTAssertNil(FilterLut.forState(FilterState(preset: .cream, intensity: 0)))
        XCTAssertTrue(FilterState(preset: .original, intensity: 50).colorIsIdentity)
        XCTAssertEqual(FilterState().vignette(), 0)
        XCTAssertEqual(FilterState().grain(), 0)
    }

    func testStrengthInterpolatesBetweenOriginalAndFullPreset() throws {
        let full = try XCTUnwrap(FilterLut.forState(FilterState(preset: .tealOrange, intensity: 100)))
        let half = try XCTUnwrap(FilterLut.forState(FilterState(preset: .tealOrange, intensity: 50)))
        let id = FilterLut.identity
        for i in stride(from: 0, to: full.count, by: 997) {
            XCTAssertEqual(half[i], id[i] + (full[i] - id[i]) / 2, accuracy: 1e-5)
        }
        // 滤镜自带的暗角随强度一起缩放
        XCTAssertEqual(FilterState(preset: .tealOrange, intensity: 50).vignette(), FilterPreset.tealOrange.vignette / 2, accuracy: 1e-6)
    }

    func testEveryPresetStaysInRangeAndActuallyChangesTheImage() throws {
        for preset in FilterPreset.allCases {
            let lut = FilterLut.forPreset(preset)
            if preset == .original {
                XCTAssertNil(lut)
                continue
            }
            let values = try XCTUnwrap(lut, preset.key)
            XCTAssertTrue(values.allSatisfy { (0...1).contains($0) }, preset.key)
            let maxDelta = values.indices.map { abs(values[$0] - FilterLut.identity[$0]) }.max() ?? 0
            XCTAssertGreaterThan(maxDelta, 0.03, "\(preset.key) is a no-op")
        }
    }

    func testBlackAndWhitePresetsHaveNoColourLeft() throws {
        for preset in [FilterPreset.mono, .noir] {
            let lut = try XCTUnwrap(FilterLut.forPreset(preset))
            for i in stride(from: 0, to: lut.count, by: 3) {
                XCTAssertEqual(lut[i], lut[i + 1], accuracy: 1e-5, preset.key)
                XCTAssertEqual(lut[i], lut[i + 2], accuracy: 1e-5, preset.key)
            }
        }
    }

    func testPresetKeysAreUniqueAndRoundTrip() {
        let keys = FilterPreset.allCases.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count)
        FilterPreset.allCases.forEach { XCTAssertEqual(FilterPreset.fromKey($0.key), $0) }
        XCTAssertEqual(FilterPreset.fromKey("removed_preset"), .original)
        XCTAssertEqual(FilterPreset.allCases.count, 27, "原图 + 26 款，顺序即滤镜条顺序")
    }

    func testAdjustmentsMoveColoursTheWayTheirNamesSay() throws {
        func mid(_ state: FilterState) throws -> [Float] { at(try XCTUnwrap(FilterLut.forState(state)), 16, 16, 16) }
        let base = FilterState()
        XCTAssertGreaterThan(try mid(base.with(.brightness, 50))[0], 0.5)
        XCTAssertLessThan(try mid(base.with(.brightness, -50))[0], 0.5)
        let warm = try mid(base.with(.warmth, 80))
        XCTAssertGreaterThan(warm[0], warm[2])
        let cool = try mid(base.with(.warmth, -80))
        XCTAssertGreaterThan(cool[2], cool[0])
        // 褪色托起黑位
        XCTAssertGreaterThan(at(try XCTUnwrap(FilterLut.forState(base.with(.fade, 100))), 0, 0, 0)[0], 0.1)
        // 去饱和到底就是灰
        let red = at(try XCTUnwrap(FilterLut.forState(base.with(.saturation, -100))), n - 1, 0, 0)
        XCTAssertEqual(red[0], red[1], accuracy: 1e-5)
        // 暗角 / 颗粒不进颜色 LUT
        XCTAssertNil(FilterLut.forState(base.with(.vignette, 60).with(.grain, 60)))
    }

    func testFileTagNamesIdenticalImagesAlikeAndDifferentImagesApart() {
        let cream = FilterState(preset: .cream)
        XCTAssertEqual(cream.fileTag(), "cream")
        let brighter = cream.with(.brightness, 20)
        XCTAssertNotNil(brighter.fileTag().range(of: #"^cream_[0-9a-f]{6}$"#, options: .regularExpression))
        // 同一组参数永远同名
        XCTAssertEqual(brighter.fileTag(), FilterState(preset: .cream).with(.brightness, 20).fileTag())
        // 参数不同就不同名
        var lighter = cream
        lighter.intensity = 60
        let tags: Set = [cream.fileTag(), brighter.fileTag(), cream.with(.brightness, 21).fileTag(),
                         lighter.fileTag(), cream.with(.contrast, 20).fileTag()]
        XCTAssertEqual(tags.count, 5)
        // 原图的强度残值不影响命名
        XCTAssertEqual(FilterState(intensity: 40).fileTag(), "original")
        // Java String.hashCode
        XCTAssertEqual(FilterState.javaHashCode("hello"), 99_162_322)
        XCTAssertEqual(FilterState.javaHashCode("100:0,0,0,0,0,0,0,0,0,0"), "100:0,0,0,0,0,0,0,0,0,0".javaHash)
    }

    func testCurvePassesThroughItsControlPointsWithoutOvershoot() {
        let c = FilterCurve.of(0, 20, 64, 70, 128, 140, 255, 250)
        XCTAssertEqual(c.eval(0), 20 / 255, accuracy: 1e-4)
        XCTAssertEqual(c.eval(128 / 255), 140 / 255, accuracy: 1e-3)
        XCTAssertEqual(c.eval(1), 250 / 255, accuracy: 1e-4)
        var last: Float = -1
        for i in 0...255 {
            let v = c.eval(Float(i) / 255)
            XCTAssertGreaterThanOrEqual(v, last - 1e-6, "not monotone at \(i)")
            last = v
        }
    }

    func testVignetteIsUntouchedInTheCentreAndDarkestInTheCorners() throws {
        let lut = try XCTUnwrap(FilterLut.vignette(1))
        XCTAssertEqual(lut.count, FilterLut.vignetteLutSize + 1)
        XCTAssertEqual(lut[0], 1)
        for i in 1..<lut.count { XCTAssertLessThanOrEqual(lut[i], lut[i - 1] + 1e-6) }
        XCTAssertEqual(lut.last!, 1 - 0.72, accuracy: 1e-4)
        XCTAssertNil(FilterLut.vignette(0))
    }

    // MARK: 内核（NativeImageFilterInstrumentedTest.kt）

    private func bitmap(_ w: Int, _ h: Int, seed: UInt64, alpha: Bool = false) -> FilterBitmap {
        var rng = SplitMix(seed)
        let bmp = FilterBitmap(width: w, height: h)
        for i in 0..<(w * h) {
            let a = alpha ? Int(rng.next() % 255) + 1 : 255
            let p = bmp.pixels + i * 4
            for c in 0..<3 { p[c] = UInt8((Int(rng.next() % 256) * a + 127) / 255) }
            p[3] = UInt8(a)
        }
        return bmp
    }

    func testLutKernelMatchesFloatReferenceForEveryPreset() throws {
        let src = bitmap(61, 47, seed: 7)
        let dst = FilterBitmap(width: 61, height: 47)
        for preset in FilterPreset.allCases {
            // 只比颜色：暗角 / 颗粒是空间效果，单独测
            try ImageFilterKernel.render(src, into: dst, state: FilterState(preset: preset),
                                         lut: FilterLut.forPreset(preset), vignette: 0, grain: 0)
            var worst = 0
            let ops = preset.ops()
            for i in 0..<(61 * 47) {
                let s = src.pixels + i * 4, d = dst.pixels + i * 4
                var c = FilterRGB(r: Float(s[0]) / 255, g: Float(s[1]) / 255, b: Float(s[2]) / 255)
                for op in ops { op(&c) }
                for (k, v) in [c.r, c.g, c.b].enumerated() {
                    worst = max(worst, abs(Int(d[k]) - Int(min(max(v, 0), 1) * 255)))
                }
                XCTAssertEqual(d[3], 255)
            }
            // 33³ 网格对曲线类滤镜的插值误差在几个色阶之内，肉眼不可辨
            XCTAssertLessThanOrEqual(worst, 4, "\(preset.key) worst diff \(worst)")
        }
    }

    func testTranslucentPixelsSurviveIdentityRoundTrip() throws {
        let src = bitmap(40, 40, seed: 3, alpha: true)
        let copy = FilterBitmap(width: 40, height: 40)
        copy.pixels.update(from: src.pixels, count: 40 * 40 * 4)
        // 恒等 LUT：强制走一遍反乘 / 查表 / 乘回，颜色应该原样回来
        try ImageFilterKernel.render(copy, into: copy, state: FilterState(), lut: FilterLut.identity)
        for i in 0..<(40 * 40) {
            let a = src.pixels + i * 4, b = copy.pixels + i * 4
            XCTAssertEqual(a[3], b[3])
            for c in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(a[c]) - Int(b[c])), 1, "pixel \(i)") }
        }
    }

    func testVignetteDarkensCornersNotCentre() throws {
        let bmp = FilterBitmap(width: 201, height: 101)
        for i in 0..<(201 * 101) {
            let p = bmp.pixels + i * 4
            p[0] = 200; p[1] = 200; p[2] = 200; p[3] = 255
        }
        try ImageFilterKernel.render(bmp, into: bmp, state: FilterState().with(.vignette, 100))
        XCTAssertEqual(bmp.pixels[(50 * 201 + 100) * 4], 200)
        XCTAssertLessThan(bmp.pixels[0], 70)
    }

    // MARK: 模型端到端

    @MainActor
    private func readyModel() async throws -> ImageFilterModel {
        let illust = try JSONDecoder().decode(Illust.self, from: Data(#"{"id": 7, "title": "t"}"#.utf8))
        let source = Self.procedural(300, 200).makeImage().flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.95) }
        let model = ImageFilterModel(illust: illust, page: 0, sourceOverride: try XCTUnwrap(source))
        model.start(previewMaxEdge: 160, thumbPx: 32)
        for _ in 0..<200 where model.load != .ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.load, .ready)
        return model
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor
    func testModelRendersTheLatestStateAndThumbStrip() async throws {
        let model = try await readyModel()
        // 预览按长边缩到舞台尺寸；参数等同原图时预览帧就是预览小图本身。
        XCTAssertEqual(model.original?.width, 160)
        try await waitUntil { model.rendered != nil }
        XCTAssertTrue(model.rendered === model.original)
        try await waitUntil { model.thumbs.allSatisfy { $0 != nil } }
        XCTAssertEqual(model.thumbs.first??.width, 32)
        model.selectPreset(.mono)
        try await waitUntil { model.rendered !== model.original }
        let frame = try XCTUnwrap(model.rendered)
        let bitmap = try XCTUnwrap(FilterBitmap.draw(frame, width: frame.width, height: frame.height))
        for i in stride(from: 0, to: frame.width * frame.height, by: 37) where bitmap.pixels[i * 4 + 3] == 255 {
            let p = bitmap.pixels + i * 4
            XCTAssertEqual(p[0], p[1]); XCTAssertEqual(p[1], p[2])
        }
        // 重置回原图：预览帧回到预览小图
        model.reset()
        try await waitUntil { model.rendered === model.original }
    }

    @MainActor
    func testExportRendersFullResolutionOnceAndNamesTheFileByItsParameters() async throws {
        let model = try await readyModel()
        model.selectPreset(.cream)
        model.setAdjust(.brightness, 20)
        var results: [FilterExportResult] = []
        model.onResult = { results.append($0) }
        model.export(.share)
        try await waitUntil { results.count == 1 }
        guard case .share(let url) = results[0] else { return XCTFail("\(results[0])") }
        XCTAssertEqual(url.lastPathComponent, "7_p0_\(model.state.fileTag()).jpg")
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 200)
        // 同一组参数再导出一次：复用同一个成品，不重算
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        model.export(.share)
        try await waitUntil { results.count == 2 }
        guard case .share(let again) = results[1] else { return XCTFail("\(results[1])") }
        XCTAssertEqual(again, url)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, modified)
    }

    // MARK: 与 Android 原版逐字节对拍

    func testEveryGoldenCaseMatchesTheAndroidKernelByteForByte() throws {
        let bundle = Bundle(for: Self.self)
        let casesURL = try XCTUnwrap(bundle.url(forResource: "cases", withExtension: "txt", subdirectory: "ImageFilterFixtures"))
        let goldenURL = try XCTUnwrap(bundle.url(forResource: "golden", withExtension: "txt", subdirectory: "ImageFilterFixtures"))
        var golden: [String: (hash: String, tag: String)] = [:]
        for line in try String(contentsOf: goldenURL, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: " ").map(String.init)
            golden[f[0]] = (f[1], f[2])
        }
        var checked = 0
        for line in try String(contentsOf: casesURL, encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: " ").map(String.init)
            let name = f[0]
            let state = FilterState(preset: FilterPreset(rawValue: f[1])!, intensity: Int(f[2])!,
                                    adjust: f[3].split(separator: ",").map { Int($0)! })
            let w = Int(f[4])!, h = Int(f[5])!
            let expected = try XCTUnwrap(golden[name], name)
            XCTAssertEqual(state.fileTag(), expected.tag, "\(name) fileTag")
            let src = Self.procedural(w, h)
            let dst = FilterBitmap(width: w, height: h)
            try ImageFilterKernel.render(src, into: dst, state: state)
            let hash = SHA256.hash(data: Data(bytes: dst.pixels, count: w * h * 4)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, expected.hash, "\(name) differs from the Android kernel")
            checked += 1
        }
        XCTAssertEqual(checked, golden.count)
        XCTAssertGreaterThan(checked, 60)
    }

    /// 与生成脚本里 C++ 的 `procedural()` 同一张图：渐变、平涂块、噪点、左上角一块半透明。
    static func procedural(_ w: Int, _ h: Int) -> FilterBitmap {
        let bmp = FilterBitmap(width: w, height: h)
        let uw = UInt32(w), uh = UInt32(h)
        for y in 0..<uh {
            for x in 0..<uw {
                let n = hash2(x, y)
                var r = (x &* 255 / uw &+ (n & 15)) & 255
                var g = (y &* 255 / uh) & 255
                var b = ((x ^ y) &* 3 &+ (n >> 8 & 7)) & 255
                if (x / 16 + y / 16) % 5 == 0 { r = 200; g = 64; b = 32 }
                let a: UInt32 = (x * 3 < uw) && (y * 2 < uh) ? (n >> 16 & 255) : 255
                let p = bmp.pixels + (Int(y) * w + Int(x)) * 4
                p[0] = UInt8((r * a + 127) / 255)
                p[1] = UInt8((g * a + 127) / 255)
                p[2] = UInt8((b * a + 127) / 255)
                p[3] = UInt8(a)
            }
        }
        return bmp
    }

    private static func hash2(_ x: UInt32, _ y: UInt32) -> UInt32 {
        var h = (x &* 0x8DA6_B343) ^ (y &* 0xD816_3841)
        h ^= h >> 15
        h = h &* 0x2C1B_3C6D
        h ^= h >> 12
        h = h &* 0x297A_2D39
        h ^= h >> 15
        return h
    }
}

private struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension String {
    /// 参照实现：Java `String.hashCode` 的定义式 s[0]·31^(n−1) + … + s[n−1]。
    var javaHash: Int32 {
        let units = Array(utf16)
        var h: Int32 = 0
        for (i, u) in units.enumerated() {
            var p: Int32 = 1
            for _ in 0..<(units.count - 1 - i) { p = p &* 31 }
            h = h &+ Int32(u) &* p
        }
        return h
    }
}
