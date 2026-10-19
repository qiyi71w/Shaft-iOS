#if DEBUG
import SwiftUI
import UIKit

/// 滤镜页的确定性预览：不联网、不需要登录，用一张本地绘制的插画式图片打开真实的 `ImageFilterView`，
/// 供模拟器截图与 Android 对照。Release 不编译。
///
///     simctl launch <udid> com.shaft.ShaftiOS --image-filter-preview [--filter-dark] [--filter-language=en]
///         [--filter-mode=adjust] [--filter-preset=cream] [--filter-intensity=60] [--filter-tool=3]
///         [--filter-adjust=3:40,0:-20] [--filter-large]
struct ImageFilterPreview: View {
    @State private var locale = OnboardingStore()
    @State private var model: ImageFilterModel
    private let args = ProcessInfo.processInfo.arguments

    init() {
        let args = ProcessInfo.processInfo.arguments
        func option(_ key: String) -> String? {
            args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        let json = #"{"id": 123456789, "title": "滤镜预览", "type": "illust"}"#
        let illust = try! JSONDecoder().decode(Illust.self, from: Data(json.utf8))
        let model = ImageFilterModel(illust: illust, page: 0, sourceOverride: Self.picture())
        if let key = option("--filter-preset") { model.selectPreset(FilterPreset.fromKey(key)) }
        if let v = option("--filter-intensity").flatMap(Int.init) { model.setIntensity(v) }
        for pair in (option("--filter-adjust") ?? "").split(separator: ",") {
            let kv = pair.split(separator: ":").compactMap { Int($0) }
            if kv.count == 2, FilterAdjust.allCases.indices.contains(kv[0]) { model.setAdjust(FilterAdjust.allCases[kv[0]], kv[1]) }
        }
        model.adjustMode = option("--filter-mode") == "adjust"
        model.adjustTool = option("--filter-tool").flatMap(Int.init) ?? 0
        _model = State(initialValue: model)
    }

    private func option(_ key: String) -> String? {
        args.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    var body: some View {
        NavigationStack {
            ImageFilterView(model: model)
        }
        .environment(locale)
        .environment(\.dynamicTypeSize, args.contains("--filter-large") ? .accessibility1 : .large)
        .preferredColorScheme(args.contains("--filter-dark") ? .dark : .light)
        .onAppear { locale.chosenTag = option("--filter-language") ?? "zh-Hans" }
    }

    /// 插画式的测试图：天空渐变、落日、远山、平涂人物色块、细节高光 —— 各类滤镜的变化都看得出来。
    static func picture() -> Data {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let sky = CGGradient(colorsSpace: space, colors: [
                UIColor(red: 0.20, green: 0.42, blue: 0.86, alpha: 1).cgColor,
                UIColor(red: 0.98, green: 0.62, blue: 0.48, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 1000), options: [.drawsAfterEndLocation])
            UIColor(red: 1, green: 0.86, blue: 0.55, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 760, y: 520, width: 300, height: 300))
            let hills: [(CGFloat, UIColor)] = [
                (900, UIColor(red: 0.36, green: 0.30, blue: 0.55, alpha: 1)),
                (1080, UIColor(red: 0.18, green: 0.45, blue: 0.40, alpha: 1)),
                (1260, UIColor(red: 0.10, green: 0.24, blue: 0.22, alpha: 1)),
            ]
            for (i, (y, color)) in hills.enumerated() {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: y))
                for x in stride(from: 0, through: 1200, by: 40) {
                    path.addLine(to: CGPoint(x: CGFloat(x), y: y - 90 * sin(CGFloat(x) / 170 + CGFloat(i) * 1.7)))
                }
                path.addLine(to: CGPoint(x: 1200, y: 1600))
                path.addLine(to: CGPoint(x: 0, y: 1600))
                color.setFill()
                path.fill()
            }
            // 人物：肤色脸、深色头发、红色衣服、白色高光
            UIColor(red: 0.16, green: 0.12, blue: 0.20, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 250, y: 640, width: 400, height: 460))
            UIColor(red: 0.98, green: 0.84, blue: 0.74, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 300, y: 720, width: 300, height: 340))
            UIColor(red: 0.86, green: 0.18, blue: 0.24, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 220, y: 1060, width: 460, height: 540), cornerRadius: 160).fill()
            UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 370, y: 850, width: 50, height: 60))
            cg.fillEllipse(in: CGRect(x: 480, y: 850, width: 50, height: 60))
            UIColor.white.setFill()
            cg.fillEllipse(in: CGRect(x: 380, y: 858, width: 16, height: 16))
            cg.fillEllipse(in: CGRect(x: 490, y: 858, width: 16, height: 16))
            UIColor(red: 0.95, green: 0.55, blue: 0.62, alpha: 0.6).setFill()
            cg.fillEllipse(in: CGRect(x: 330, y: 930, width: 70, height: 40))
            cg.fillEllipse(in: CGRect(x: 500, y: 930, width: 70, height: 40))
            for i in 0..<14 {
                UIColor.white.withAlphaComponent(0.8).setFill()
                let x = CGFloat((i * 397) % 1150), y = CGFloat((i * 211) % 420) + 40
                cg.fillEllipse(in: CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        return image.jpegData(compressionQuality: 0.95)!
    }
}
#endif
