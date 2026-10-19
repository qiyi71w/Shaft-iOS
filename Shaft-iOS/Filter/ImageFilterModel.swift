import Foundation
import ImageIO
import Observation
import Photos
import UIKit
import UniformTypeIdentifiers

enum FilterLoad: Equatable {
    case loading(percent: Int?)
    case failed
    case ready
}

enum FilterExport { case save, share }

enum FilterExportResult {
    case saved
    case share(URL)
    case failed(String)
}

/// 滤镜页的状态与重活 —— Pixiv-Shaft `ImageFilterViewModel` 的移植。
///
/// - **预览**：原图按舞台尺寸解一张小图，所有滤镜都在它上面渲染；渲染串行在一条队列上，拖滑条时只渲最新的那一组参数
///   （排队中被新参数顶掉的直接跳过），而且先用 1/4 像素的草稿跟手、停手后补清晰帧。每一帧写进新的一张位图，
///   舞台正挂着的那一帧绝不会被下一次渲染写到，不会画出半帧。
/// - **滤镜条**：从预览小图居中裁一张缩略图，每只预设各渲一次（几万像素，毫秒级），按滤镜条顺序逐个出。
/// - **导出**：全分辨率解码 → 原地渲染 → 编码。结果按参数缓存，先保存再分享（或反过来）不重算。
@MainActor
@Observable
final class ImageFilterModel {

    private(set) var load: FilterLoad = .loading(percent: nil)
    private(set) var state = FilterState()
    /// 预览小图（「按住看原图」显示的就是它）。
    private(set) var original: CGImage?
    /// 当前参数渲染出的预览帧；参数等同原图时就是预览小图本身。
    private(set) var rendered: CGImage?
    /// 按 `FilterPreset.ordinal` 排的滤镜条缩略图，渲好一只填一只。
    private(set) var thumbs: [CGImage?] = Array(repeating: nil, count: FilterPreset.allCases.count)
    private(set) var exporting: FilterExport?
    /// 「滤镜 / 调节」两个模式，和调节模式下选中的那一项。
    var adjustMode = false
    var adjustTool = 0

    @ObservationIgnored var onResult: ((FilterExportResult) -> Void)?

    let illust: Illust
    let page: Int

    @ObservationIgnored private var previewMaxEdge = 0
    @ObservationIgnored private var thumbPx = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var sourceData: Data?
    @ObservationIgnored private var preview: FilterBitmap?
    /// 拖动中用的草稿：预览小图再缩一半（像素 1/4），手停下来再渲清晰的那一帧。
    @ObservationIgnored private var draft: FilterBitmap?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var lastChangeAt: TimeInterval = 0
    @ObservationIgnored private let gate = RenderGate()
    @ObservationIgnored private var lastExport: (FilterState, URL)?

    /// 预览与缩略图的渲染全部串行在这一条线上：内核自己会按像素量铺满核心，这里不必再并行。
    private nonisolated static let renderQueue = DispatchQueue(label: "shaft.image-filter.render", qos: .userInitiated)

    /// 两次参数变化间隔小于它就算在拖动。
    private static let dragGap: TimeInterval = 0.090
    /// 停手多久后补一张清晰帧。
    private static let settle: Duration = .milliseconds(120)
    private nonisolated static let jpegQuality: CGFloat = 0.95
    /// 预览小图的长边上限：再大屏幕上也看不出差别，像素却按平方涨。
    static let maxPreviewEdge = 2048
    /// 导出解码的像素预算（Android `NCNN_INPUT_MAX_PIXELS`），超过就按 2 的幂折半。
    private nonisolated static let exportMaxPixels = 32 * 1024 * 1024

    /// 只给调试预览（`ImageFilterPreview`）用：不走网络，直接拿这份编码好的图片当原图。
    @ObservationIgnored private let sourceOverride: Data?

    init(illust: Illust, page: Int, sourceOverride: Data? = nil) {
        self.illust = illust
        self.page = page
        self.sourceOverride = sourceOverride
    }

    func start(previewMaxEdge: Int, thumbPx: Int) {
        guard !started else { return }
        started = true
        self.previewMaxEdge = previewMaxEdge
        self.thumbPx = thumbPx
        loadSource()
    }

    func retry() {
        if load == .failed { loadSource() }
    }

    private func loadSource() {
        loadTask?.cancel()
        load = .loading(percent: nil)
        let pages = IllustPages.pages(for: illust)
        let url = pages.indices.contains(page) ? (pages[page].original ?? pages[page].large) : nil
        let maxEdge = previewMaxEdge
        let override = sourceOverride
        loadTask = Task { [weak self] in
            let data: Data?
            if let override {
                data = override
            } else {
                guard let url else { self?.load = .failed; return }
                // 复用看图页同一个共享下载任务（已加载直接拿到，没加载就等它下完）。
                data = await PixivImageCache.shared.loadData(url, forDownload: true, onTransfer: { [weak self] p in
                    guard let self, case .loading = self.load else { return }
                    self.load = .loading(percent: p.fraction.map { Int($0 * 100) })
                })
            }
            guard let self, !Task.isCancelled else { return }
            guard let data, let decoded = await Self.decodePreview(data, maxEdge: maxEdge) else {
                self.load = .failed
                return
            }
            guard !Task.isCancelled else { return }
            self.sourceData = data
            self.preview = decoded.preview
            self.draft = decoded.draft
            self.original = decoded.preview.makeImage()
            self.load = .ready
            self.requestRender(dragging: false)
            self.renderThumbs(decoded.preview)
        }
    }

    // MARK: 编辑

    func selectPreset(_ preset: FilterPreset) {
        // 再点一次已选中的滤镜不改强度；换滤镜时强度回满，和修图 App 的习惯一致。
        guard state.preset != preset else { return }
        var s = state
        s.preset = preset
        s.intensity = 100
        update(s)
    }

    func setIntensity(_ value: Int) {
        var s = state
        s.intensity = min(max(value, 0), 100)
        update(s)
    }

    func setAdjust(_ a: FilterAdjust, _ value: Int) {
        update(state.with(a, min(max(value, a.bipolar ? -100 : 0), 100)))
    }

    func reset() { update(FilterState()) }

    /// 「重置」后的撤销。
    func restore(_ s: FilterState) { update(s) }

    private func update(_ s: FilterState) {
        guard s != state else { return }
        state = s
        // 参数在连续变（拖滑条）：先出一张草稿跟手，停手后再出清晰帧。
        let now = ProcessInfo.processInfo.systemUptime
        let dragging = now - lastChangeAt < Self.dragGap
        lastChangeAt = now
        requestRender(dragging: dragging)
    }

    // MARK: 渲染

    /// 只渲最新的一组参数（`collectLatest`）：新参数到来时取消上一轮的等待；已经排进渲染队列、还没开跑的旧参数
    /// 由 `RenderGate` 跳过。已经开跑的那一帧照常发布 —— 它比屏幕上挂着的更新，拖动中不至于一帧都出不来。
    private func requestRender(dragging: Bool) {
        guard let preview else { return }
        renderTask?.cancel()
        let s = state
        let ticket = gate.next()
        let small = draft
        renderTask = Task { [weak self, gate] in
            if dragging, let small {
                if let frame = await Self.renderFrame(small, s, ticket: ticket, gate: gate) { self?.publish(frame, ticket) }
                do { try await Task.sleep(for: Self.settle) } catch { return }
            }
            if let frame = await Self.renderFrame(preview, s, ticket: ticket, gate: gate) { self?.publish(frame, ticket) }
        }
    }

    @ObservationIgnored private var publishedTicket = 0

    private func publish(_ frame: RenderedFrame, _ ticket: Int) {
        guard ticket >= publishedTicket else { return }
        publishedTicket = ticket
        switch frame {
        case .identity: rendered = original
        case .image(let image): rendered = image
        }
    }

    private enum RenderedFrame: @unchecked Sendable {
        case identity
        case image(CGImage)
    }

    /// 把 `s` 从 `source` 渲进一张新位图；参数等同原图时直接用预览小图。被更新的参数顶掉时返回 nil。
    private nonisolated static func renderFrame(_ source: FilterBitmap, _ s: FilterState,
                                                ticket: Int, gate: RenderGate) async -> RenderedFrame? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                guard gate.isCurrent(ticket) else { continuation.resume(returning: nil); return }
                if s.colorIsIdentity && s.vignette() == 0 && s.grain() == 0 {
                    continuation.resume(returning: .identity)
                    return
                }
                let out = FilterBitmap(width: source.width, height: source.height)
                do {
                    try ImageFilterKernel.render(source, into: out, state: s)
                    continuation.resume(returning: out.makeImage().map(RenderedFrame.image))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func renderThumbs(_ preview: FilterBitmap) {
        let side = min(preview.width, preview.height)
        // 长条漫画居中裁出来的往往是对白和空白，取上三分之一处更像「这张图」。
        let top = preview.height > preview.width * 2 ? (preview.height - side) / 3 : (preview.height - side) / 2
        let px = thumbPx
        let presets = FilterPreset.allCases
        Self.renderQueue.async { [weak self] in
            guard let thumb = preview.cropped(x: (preview.width - side) / 2, y: top, side: side, to: px) else { return }
            for preset in presets {
                let image: CGImage?
                if preset == .original {
                    image = thumb.makeImage()
                } else {
                    let out = FilterBitmap(width: px, height: px)
                    image = (try? ImageFilterKernel.render(thumb, into: out, state: FilterState(preset: preset),
                                                           lut: FilterLut.forPreset(preset))).flatMap { out.makeImage() }
                }
                let box = UncheckedImage(image)
                DispatchQueue.main.async { self?.thumbs[preset.ordinal] = box.image }
            }
        }
    }

    private struct UncheckedImage: @unchecked Sendable {
        let image: CGImage?
        init(_ image: CGImage?) { self.image = image }
    }

    private struct DecodedPreview: @unchecked Sendable {
        let preview: FilterBitmap
        let draft: FilterBitmap
    }

    /// 解码到舞台尺寸：长边不超过 `maxEdge`，任何源格式都统一成 8 位 sRGB 预乘（16 位 PNG 也照常可用）。
    private nonisolated static func decodePreview(_ data: Data, maxEdge: Int) async -> DecodedPreview? {
        await Task.detached(priority: .userInitiated) {
            guard let image = decode(data, maxEdge: maxEdge),
                  let preview = FilterBitmap.draw(image, width: image.width, height: image.height),
                  let draft = FilterBitmap.draw(image, width: max(1, image.width / 2), height: max(1, image.height / 2))
            else { return nil }
            return DecodedPreview(preview: preview, draft: draft)
        }.value
    }

    /// 长边超过 `maxEdge` 时缩到恰好 `maxEdge`，否则原尺寸。
    private nonisolated static func decode(_ data: Data, maxEdge: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(w, h), maxEdge),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // MARK: 导出

    func export(_ kind: FilterExport) {
        guard exporting == nil, load == .ready else { return }
        let s = state
        exporting = kind
        Task { [weak self] in
            guard let self else { return }
            let result: FilterExportResult
            do {
                let file = try await self.renderFull(s)
                switch kind {
                case .save:
                    try await Self.saveToPhotos(file, name: self.photoName(file, s))
                    result = .saved
                case .share:
                    result = .share(file)
                }
            } catch {
                result = .failed(error.localizedDescription)
            }
            self.exporting = nil
            self.onResult?(result)
        }
    }

    private enum ExportError: LocalizedError {
        case decodeFailed, encodeFailed, photosDenied
        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "decode failed"
            case .encodeFailed: return "encode failed"
            case .photosDenied: return "Photos access denied"
            }
        }
    }

    /// 全分辨率渲染并编码到临时目录；同一组参数只算一次。
    private func renderFull(_ s: FilterState) async throws -> URL {
        if let (state, file) = lastExport, state == s, FileManager.default.fileExists(atPath: file.path) { return file }
        guard let data = sourceData else { throw ExportError.decodeFailed }
        let base = "\(illust.id)_p\(page)_\(s.fileTag())"
        let file = try await Task.detached(priority: .userInitiated) {
            try Self.renderFullFile(data, s, baseName: base)
        }.value
        // 旧成品不删：可能刚分享出去，对方 App 还没读完。临时目录交给系统回收。
        lastExport = (s, file)
        return file
    }

    private nonisolated static func renderFullFile(_ data: Data, _ s: FilterState, baseName: String) throws -> URL {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0
        else { throw ExportError.decodeFailed }
        var sample = 1
        while (w / sample) * (h / sample) > exportMaxPixels { sample *= 2 }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h) / sample,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let bitmap = FilterBitmap.draw(image, width: image.width, height: image.height)
        else { throw ExportError.decodeFailed }
        try ImageFilterKernel.render(bitmap, into: bitmap, state: s)
        // 不透明的图出 JPEG 95，带透明通道的出 PNG（JPEG 存不下透明度）。
        let png = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filter", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(baseName + (png ? ".png" : ".jpg"))
        guard let rendered = bitmap.makeImage() else { throw ExportError.encodeFailed }
        let encoded = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(encoded, type, 1, nil) else { throw ExportError.encodeFailed }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(dest, rendered, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.encodeFailed }
        try (encoded as Data).write(to: out, options: .atomic)
        return out
    }

    /// 成品沿用插画命名加 `_filter_<滤镜>` 后缀（与 Android 同名），不同参数的成品不会互相覆盖。
    private func photoName(_ file: URL, _ s: FilterState) -> String {
        "\(illust.id)_p\(page)_filter_\(s.fileTag()).\(file.pathExtension)"
    }

    private nonisolated static func saveToPhotos(_ file: URL, name: String) async throws {
        guard await PhotoLibrarySaver.requestAuthorization() else { throw ExportError.photosDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = name
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: options)
        }
    }
}

/// 渲染排队的「最新参数」票号：排进队列、还没开跑时就已被新参数顶掉的那一帧直接跳过。
private final class RenderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        latest += 1
        return latest
    }

    func isCurrent(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket == latest
    }
}
