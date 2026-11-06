import SwiftUI
import UIKit

/// 当前 Android AppTheme（#686BDD）推出来的 `V3Palette` 与 witstudio 色值 —— 滤镜页自己的一份，
/// 和广场 / 推介计划一样不改动 iOS 全局色板。数值由 `V3Palette` 的派生公式对 #686BDD 逐项算出。
enum FilterPalette {
    static let primary = Color(hex: 0x686BDD)
    static let onPrimary = Color.white
    static let alpha10 = primary.opacity(0.10)
    static let alpha20 = primary.opacity(0.20)
    static let alpha30 = primary.opacity(0.30)
    /// `cardFill` / `cardHairline` / `textAccent`（与 `PlazaPalette` 同值）。
    static let cardFill = Color(light: 0xF2F2F8, dark: 0x1F1F26)
    static let cardHairline = Color(light: 0x2529A7, dark: 0x686BDD, lightAlpha: 0.12, darkAlpha: 0.12)
    static let textAccent = Color(light: 0x2529A7, dark: 0x8183E3)
    /// `textTag`：选中胶囊 / 连通段的字色，按「20% 主题色合成在卡片底上」校正过对比度。
    static let textTag = Color(light: 0x24279E, dark: 0x9395E7)
    /// `LibraryFilterViews` 的未选底（`v3_surface_3` 合成在 `v3_bg` 上）与选中底（20% 主题色合成在 `v3_bg` 上）。
    static let idleFill = Color(light: 0xE6E6E6, dark: 0x1B1B1F)
    static let selectedFill = Color(light: 0xDDDDF4, dark: 0x1B1C36)
    /// `floatingPillContent` / `floatingPillBg`（`cardFill` 80%）。
    static let floatingPillContent = Color(light: 0x565790, dark: 0xFFFFFF)
    static let floatingPillBg = cardFill.opacity(0.80)
    static let text1 = Theme.v3Text1
    static let text2 = Theme.v3Text2
    static let fade = Animation.easeInOut(duration: 0.18)
}

/// 图片滤镜：给作品的某一页套上当下修图 App 里的热门滤镜，再按需微调，存一张新图或直接分享 ——
/// Pixiv-Shaft `ImageFilterFragment` 的 1:1 移植。
///
/// 页面按 V3「作品 / 内容」配方：舞台（这一页，按住看原图）优先 → 「滤镜 | 调节」→ 滤镜条或调节项 →
/// 一条滑条 → 一个最强操作（「保存」实色胶囊）。宽屏横放时舞台在左、控制台在右。
struct ImageFilterView: View {
    let illust: Illust
    let page: Int
    var onClose: (() -> Void)?

    @State private var model: ImageFilterModel
    @Environment(OnboardingStore.self) private var l10n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var holding = false
    @State private var hintOpacity: Double = 0
    @State private var hintShown = false
    @State private var flashOpacity: Double = 0
    @State private var savedLabel = false
    @State private var savedLabelTask: Task<Void, Never>?
    @State private var snack: FilterSnack?
    @State private var toast: FilterToast?
    @State private var shareItem: ShareTarget?

    private static let thumbSize: CGFloat = 64
    private static let savedLabelDuration: TimeInterval = 1.6

    init(illust: Illust, page: Int, onClose: (() -> Void)? = nil) {
        self.init(model: ImageFilterModel(illust: illust, page: page), onClose: onClose)
    }

    init(model: ImageFilterModel, onClose: (() -> Void)? = nil) {
        illust = model.illust
        page = model.page
        self.onClose = onClose
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            PlazaToolbar(back: close, backID: "image-filter-back") {
                Text(l10n.t(.imageFilter))
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.trailing, 16)
            } trailing: { EmptyView() }
            .shadow(color: .black.opacity(0.24), radius: 3, y: 2)
            .zIndex(1)
            GeometryReader { geo in
                content(size: geo.size)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Theme.v3Bg)
        .toolbar(.hidden, for: .navigationBar, .tabBar)
        .background(SwipeBackEnabler())
        .overlay(alignment: .bottom) { snackOverlay }
        .overlay(alignment: .bottom) { toastOverlay }
        .sheet(item: $shareItem) { V3ShareSheet(items: $0.items) }
        .onAppear {
            model.onResult = handle
            let bounds = UIScreen.main.bounds
            let w = Int(bounds.width * displayScale), h = Int(bounds.height * displayScale)
            // 预览小图的长边：按舞台大约能占到的屏幕尺寸取，而不是整块屏幕的长边 —— 预览每一帧都要整张渲一遍，
            // 多出来的像素只会拖慢滑条，屏幕上也看不出来。
            let edge = min(max(w, Int(Double(h) * 0.62)), ImageFilterModel.maxPreviewEdge)
            model.start(previewMaxEdge: edge, thumbPx: Int(Self.thumbSize * displayScale))
        }
        .onChange(of: model.load) { _, load in
            if load == .ready { showHoldHintOnce() }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: 布局

    /// 手机竖放：上舞台、下控制台；宽屏横放：舞台在左，控制台 380 在右。
    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let wide = size.width >= 600 && size.width > size.height
        let pageWidth = min(size.width, wide ? 1200 : 720)
        Group {
            if wide {
                HStack(spacing: 0) {
                    stage
                        .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 8))
                    // 控制台高度随字号涨，横放手机放不下就竖滑，「保存」不会被底边裁掉；放得下时照旧垂直居中。
                    ScrollView(.vertical) { controls(wide: true) }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: 380)
                        .frame(maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    stage
                        .padding(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                    controls(wide: false)
                }
            }
        }
        .frame(width: pageWidth)
        .frame(maxWidth: .infinity)
    }

    private func controls(wide: Bool) -> some View {
        VStack(spacing: 0) {
            modeRow
                .padding(.leading, 16).padding(.trailing, 8).padding(.top, wide ? 0 : 8)
            // 两个面板叠在一起、不用的那个隐藏：容器高度取两者较高的，切模式时舞台不跳。
            ZStack(alignment: .top) {
                presetPanel.panelVisible(!model.adjustMode)
                adjustPanel.panelVisible(model.adjustMode)
            }
            .padding(.top, 4)
            actions
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
        }
    }

    // MARK: 舞台

    /// 舞台：26 圆角容器里完整显示这一页；按住看原图，左上角浮出「原图」玻璃小标。
    private var stage: some View {
        ZStack {
            if let image = holding ? model.original : (model.rendered ?? model.original) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Color.white.opacity(flashOpacity).allowsHitTesting(false)
            switch model.load {
            case .loading(let percent): loadingBox(percent)
            case .failed: failedBox
            case .ready: EmptyView()
            }
            if holding {
                glassPill(l10n.t(.imageFilterOriginalBadge))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            glassPill(l10n.t(.imageFilterHoldHint))
                .opacity(hintOpacity)
                .padding(.horizontal, 12).padding(.bottom, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FilterPalette.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(FilterPalette.cardHairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 26))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard model.load == .ready, !holding else { return }
                    holdOriginal(true)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .onEnded { _ in if holding { holdOriginal(false) } }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n.t(.imageFilterStageDesc, illust.title ?? ""))
        .accessibilityAddTraits(.isImage)
    }

    private func loadingBox(_ percent: Int?) -> some View {
        VStack(spacing: 8) {
            FilterProgressRing(progress: percent.map { Double($0) / 100 })
                .frame(width: 30, height: 30)
            PlazaText(value: percent.map { l10n.t(.imageFilterLoadingPercent, String($0)) } ?? l10n.t(.imageFilterNowLoading),
                      size: 12, weight: 500, color: .white)
                .lineLimit(1)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .frame(minWidth: 160)
        .background(Color.black.opacity(0xB3 / 255), in: RoundedRectangle(cornerRadius: 12))
    }

    private var failedBox: some View {
        VStack(spacing: 12) {
            PlazaText(value: l10n.t(.imageFilterLoadFailed), size: 14, weight: 500, color: .white)
                .multilineTextAlignment(.center)
            Button { model.retry() } label: {
                HStack(spacing: 8) {
                    FilterIcon(glyph: .refresh).frame(width: 18, height: 18)
                    PlazaText(value: l10n.t(.imageFilterRetry), size: 14, weight: 600, color: FilterPalette.onPrimary)
                }
                .foregroundStyle(FilterPalette.onPrimary)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(minWidth: 48, minHeight: 48)
                .background(FilterPalette.primary, in: Capsule())
            }
            .buttonStyle(FilterPressStyle(ripple: Capsule()))
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(Color.black.opacity(0xB3 / 255), in: RoundedRectangle(cornerRadius: 16))
    }

    private func glassPill(_ text: String) -> some View {
        PlazaText(value: text, size: 12, weight: 600, color: FilterPalette.floatingPillContent)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(FilterPalette.floatingPillBg, in: Capsule())
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    // MARK: 「滤镜 | 调节」+ 重置

    private var modeRow: some View {
        HStack(spacing: 4) {
            FilterConnectedGroup(
                labels: [l10n.t(.imageFilterModePresets), l10n.t(.imageFilterModeAdjust)],
                selected: model.adjustMode ? 1 : 0
            ) { model.adjustMode = $0 == 1 }
            let enabled = model.state.isModified && model.load == .ready
            Button(action: reset) {
                FilterIcon(glyph: .refresh)
                    .foregroundStyle(FilterPalette.textAccent)
                    .padding(13)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(FilterPressStyle(ripple: Circle()))
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.38)
            .accessibilityLabel(l10n.t(.imageFilterReset))
        }
    }

    // MARK: 滤镜条

    /// 滤镜条：按来源分组横滑，每组上方一枚小标；下面是强度滑条。
    private var presetPanel: some View {
        let ready = model.load == .ready
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                FadingHScroll {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Self.columns, id: \.self) { group in
                            presetColumn(group)
                                .padding(.trailing, 10)
                        }
                    }
                    .padding(.leading, 16).padding(.trailing, 8)
                }
                .onAppear { reveal(proxy) }
                .onChange(of: model.adjustMode) { _, adjust in if !adjust { reveal(proxy) } }
            }
            .padding(.top, 4)
            .opacity(ready ? 1 : 0.38)
            .disabled(!ready)
            FilterSliderRow(
                title: l10n.t(.imageFilterIntensity), value: model.state.intensity,
                bipolar: false, neutral: 100, enabled: ready
            ) { model.setIntensity($0) }
            .padding(.leading, 16).padding(.trailing, 12).padding(.top, 2)
            // 原图没有「强度」可调：滑条留着位置但收起来，免得切滤镜时面板跳动。
            .opacity(model.state.preset == .original ? 0 : 1)
            .allowsHitTesting(model.state.preset != .original)
            .accessibilityHidden(model.state.preset == .original)
        }
    }

    /// 原图那一列（`nil`）也占一行组标，保证所有缩略图顶对齐。
    private static let columns: [FilterGroup?] = [nil] + FilterGroup.allCases

    private func presetColumn(_ group: FilterGroup?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PlazaText(value: group.map { l10n.t($0.label) } ?? " ", size: 11, weight: 600, color: FilterPalette.text2)
                .lineLimit(1)
                .padding(.leading, 2).padding(.bottom, 6)
            HStack(spacing: 0) {
                ForEach(FilterPreset.allCases.filter { $0.group == group }, id: \.self) { preset in
                    FilterPresetItem(
                        name: l10n.t(preset.label),
                        thumb: model.thumbs[preset.ordinal],
                        chosen: model.state.preset == preset
                    ) {
                        if model.state.preset != preset { UISelectionFeedbackGenerator().selectionChanged() }
                        model.selectPreset(preset)
                    }
                    .id(preset)
                }
            }
        }
    }

    /// 选中的那一格滚到滤镜条正中（切回「滤镜」模式、进页时）。
    private func reveal(_ proxy: ScrollViewProxy) {
        let preset = model.state.preset
        DispatchQueue.main.async { proxy.scrollTo(preset, anchor: .center) }
    }

    // MARK: 调节

    /// 调节：一行横滑的调节项胶囊（改过的带数值），下面是当前项的滑条。
    private var adjustPanel: some View {
        let ready = model.load == .ready
        let tool = currentTool
        return VStack(spacing: 0) {
            FilterChoiceChips(labels: adjustLabels, selected: tool.ordinal) { model.adjustTool = $0 }
                .padding(.top, 4)
                .opacity(ready ? 1 : 0.38)
                .disabled(!ready)
            FilterSliderRow(
                title: l10n.t(tool.label), value: model.state[tool],
                bipolar: tool.bipolar, neutral: 0, enabled: ready
            ) { model.setAdjust(tool, $0) }
            .id(tool)
            .padding(.leading, 16).padding(.trailing, 12).padding(.top, 2)
        }
    }

    private var currentTool: FilterAdjust {
        FilterAdjust.allCases.indices.contains(model.adjustTool) ? FilterAdjust.allCases[model.adjustTool] : .brightness
    }

    private var adjustLabels: [String] {
        FilterAdjust.allCases.map { a in
            let v = model.state[a]
            return v == 0 ? l10n.t(a.label) : "\(l10n.t(a.label)) \(FilterSliderRow.signed(v, a.bipolar))"
        }
    }

    // MARK: 主操作

    private var actions: some View {
        let ready = model.load == .ready
        let busy = model.exporting != nil
        return HStack(spacing: 12) {
            Button { model.export(.share) } label: {
                FilterIcon(glyph: .share)
                    .foregroundStyle(FilterPalette.textAccent)
                    .padding(16)
                    .frame(width: 56, height: 56)
                    .background(FilterPalette.alpha20, in: Circle())
                    .overlay(Circle().strokeBorder(FilterPalette.alpha30, lineWidth: 1))
            }
            .buttonStyle(FilterPressStyle(ripple: Circle()))
            .disabled(!ready || busy)
            .opacity(ready && !busy ? 1 : 0.38)
            .accessibilityLabel(l10n.t(.imageFilterShare))

            Button { model.export(.save) } label: {
                saveLabel
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                .background(FilterPalette.primary, in: Capsule())
            }
            .buttonStyle(FilterPressStyle(ripple: Capsule()))
            .disabled(!ready || busy)
            .opacity(ready ? 1 : 0.38)
        }
    }

    @ViewBuilder
    private var saveLabel: some View {
        let (text, glyph): (String, FilterGlyph?) = {
            switch model.exporting {
            case .save: return (l10n.t(.imageFilterSaving), nil)
            case .share: return (l10n.t(.imageFilterPreparing), nil)
            case nil:
                return savedLabel ? (l10n.t(.imageFilterSaved), .check) : (l10n.t(.imageFilterSave), .download)
            }
        }()
        HStack(spacing: 8) {
            if let glyph { FilterIcon(glyph: glyph).frame(width: 18, height: 18) }
            PlazaText(value: text, size: 15, weight: 600, color: FilterPalette.onPrimary).lineLimit(1)
        }
        .foregroundStyle(FilterPalette.onPrimary)
        .padding(.horizontal, 20)
    }

    // MARK: 交互

    private func reset() {
        let previous = model.state
        guard previous.isModified else { return }
        model.reset()
        withAnimation(.easeOut(duration: 0.25)) {
            snack = FilterSnack(message: l10n.t(.imageFilterResetDone), action: l10n.t(.imageFilterUndo)) {
                model.restore(previous)
            }
        }
    }

    private func holdOriginal(_ hold: Bool) {
        holding = hold
        if hold {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { hintOpacity = 0 }
        }
    }

    /// 进页面后在舞台底部提示一次「按住看原图」，2.5 秒后淡出。关闭动态效果时直接不显示。
    private func showHoldHintOnce() {
        guard !hintShown, !reduceMotion else { return }
        hintShown = true
        withAnimation(.linear(duration: 0.2)) { hintOpacity = 1 }
        withAnimation(.linear(duration: 0.3).delay(0.2 + 2.5)) { hintOpacity = 0 }
    }

    /// 快门式的一次白闪：告诉用户「存下来了」。关闭动态效果时不闪。
    private func flashStage() {
        guard !reduceMotion else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { flashOpacity = 0.35 }
        withAnimation(.easeInOut(duration: 0.26)) { flashOpacity = 0 }
    }

    private func handle(_ result: FilterExportResult) {
        switch result {
        case .saved:
            flashStage()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            show(toast: l10n.t(.imageFilterSavedToast))
            savedLabel = true
            savedLabelTask?.cancel()
            savedLabelTask = Task {
                try? await Task.sleep(for: .seconds(Self.savedLabelDuration))
                if !Task.isCancelled { savedLabel = false }
            }
        case .share(let url):
            shareItem = ShareTarget(url: url)
        case .failed(let message):
            show(toast: l10n.t(.imageFilterSaveFailed, message))
        }
    }

    private func show(toast message: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = FilterToast(message: message) }
    }

    // MARK: Snackbar / Toast

    @ViewBuilder private var snackOverlay: some View {
        if let snack {
            FilterSnackbar(snack: snack) { withAnimation(.easeOut(duration: 0.25)) { self.snack = nil } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: snack.id) {
                    // Snackbar.LENGTH_LONG
                    do { try await Task.sleep(for: .milliseconds(2750)) } catch { return }
                    withAnimation(.easeOut(duration: 0.25)) { if self.snack?.id == snack.id { self.snack = nil } }
                }
        }
    }

    @ViewBuilder private var toastOverlay: some View {
        if let toast {
            // Toaster（BlackToastStyle）：70% 黑底、10 圆角、14 号白字，底部导航栏之上 48。
            Text(toast.message)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0xEE / 255))
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .padding(.horizontal, 24).padding(.vertical, 16)
                .background(Color.black.opacity(0xB3 / 255), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
                .allowsHitTesting(false)
                .transition(.opacity)
                .task(id: toast.id) {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    withAnimation(.easeOut(duration: 0.2)) { if self.toast?.id == toast.id { self.toast = nil } }
                }
        }
    }
}

// MARK: - 零件

private struct FilterSnack: Identifiable {
    let id = UUID()
    let message: String
    let action: String
    let perform: () -> Void
}

private struct FilterToast: Identifiable {
    let id = UUID()
    let message: String
}

/// AppCompat 主题下的 `Snackbar`：#323232 整宽条、14 号白字，动作是 `colorAccent`（#1B88EE）的全大写按钮。
private struct FilterSnackbar: View {
    let snack: FilterSnack
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text(snack.message)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
            Button {
                snack.perform()
                dismiss()
            } label: {
                Text(snack.action.uppercased())
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: 0x1B88EE))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 48, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 24).padding(.trailing, 8)
        .frame(minHeight: 48)
        .background(Color(hex: 0x323232))
    }
}

/// V3 按下反馈：缩到 0.96（按下 120ms、松开 200ms），叠一层 20% 主题色的涟漪底；关闭动态效果时不缩。
private struct FilterPressStyle: ButtonStyle {
    /// 涟漪的遮罩形状；`nil` = 只有缩放（滤镜条的一格在 Android 上没有涟漪底）。
    var ripple: AnyShape?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init<S: Shape>(ripple: S) { self.ripple = AnyShape(ripple) }
    init() { ripple = nil }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                ripple?.fill(FilterPalette.alpha20).opacity(configuration.isPressed ? 1 : 0).allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.12 : 0.2), value: configuration.isPressed)
    }
}

/// 涟漪只铺在可见的那一截上：上下透明沿（补热区用的）不算。
private struct VerticalInset: Shape {
    let base: AnyShape
    let dy: CGFloat
    func path(in rect: CGRect) -> Path { base.path(in: rect.insetBy(dx: 0, dy: dy)) }
}

private extension View {
    /// 叠放面板里不用的那一块：保留尺寸（ZStack 取较高的一块），但看不见、点不到、读屏跳过。
    func panelVisible(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

/// 横滑条 + 两端 24 的渐隐边（`HorizontalScrollView` 的 fading edge：哪一端还有内容，哪一端才渐隐）。
private struct FadingHScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var fadeLeading: CGFloat = 0
    @State private var fadeTrailing: CGFloat = 0
    private let edge: CGFloat = 24

    var body: some View {
        ScrollView(.horizontal) { content() }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollMetricsChange(for: [CGFloat].self) { geo in
                [geo.contentOffset.x + geo.contentInsets.leading,
                 geo.contentSize.width - geo.containerSize.width - geo.contentOffset.x]
            } action: { _, value in
                fadeLeading = min(max(value[0] / edge, 0), 1)
                fadeTrailing = min(max(value[1] / edge, 0), 1)
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(1 - fadeLeading), .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: edge)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(1 - fadeTrailing)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: edge)
                }
            }
    }
}

/// 滤镜条的一格：64 缩略图（17 圆角）+ 名字。选中 = 2.5 主题描边 + 主题色 600 字重。
private struct FilterPresetItem: View {
    let name: String
    let thumb: CGImage?
    let chosen: Bool
    let action: () -> Void
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17).fill(FilterPalette.alpha10)
                    if let thumb {
                        Image(decorative: thumb, scale: displayScale)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 17))
                .overlay {
                    // Android 的描边宽度是 (2.5dp × density + 0.5) 取整的整像素。
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(FilterPalette.textAccent, lineWidth: (2.5 * displayScale + 0.5).rounded(.down) / displayScale)
                        .opacity(chosen ? 1 : 0)
                }
                PlazaText(value: name, size: 12, weight: chosen ? 600 : 500,
                          color: chosen ? FilterPalette.textAccent : FilterPalette.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4).padding(.bottom, 4)
            .frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(FilterPressStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// MD3-E 连通按钮组（`LibraryFilterViews.connectedGroup`）：等分整行、段间 2 缝，可见 40（上下 4 透明沿补足 48 热区）；
/// 未选是外角 20、内角 8 的中性底，选中变全圆胶囊 + 主题浅色容器 + 主题字色 600。
private struct FilterConnectedGroup: View {
    let labels: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                let chosen = index == selected
                Button { onSelect(index) } label: {
                    PlazaText(value: label, size: 14, weight: chosen ? 600 : 500,
                              color: chosen ? FilterPalette.textTag : FilterPalette.text1)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            ZStack {
                                segmentShape(index).fill(FilterPalette.idleFill).opacity(chosen ? 0 : 1)
                                Capsule().fill(FilterPalette.selectedFill).opacity(chosen ? 1 : 0)
                            }
                            .animation(FilterPalette.fade, value: chosen)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(FilterPressStyle(ripple: VerticalInset(base: AnyShape(segmentShape(index)), dy: 4)))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }

    private func segmentShape(_ index: Int) -> UnevenRoundedRectangle {
        let start: CGFloat = index == 0 ? 20 : 8
        let end: CGFloat = index == labels.count - 1 ? 20 : 8
        return UnevenRoundedRectangle(topLeadingRadius: start, bottomLeadingRadius: start,
                                      bottomTrailingRadius: end, topTrailingRadius: end)
    }
}

/// 横滑选择胶囊（`LibraryFilterViews.choiceChips(scroll = true)`）：可见 36（上下 6 透明沿补足 48 热区），
/// 未选 10 圆角中性底，选中变全圆 + 主题浅色容器 + 勾。首尾留白对齐本页 16 的边。
private struct FilterChoiceChips: View {
    let labels: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            FadingHScroll {
                HStack(spacing: 8) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        chip(label, chosen: index == selected) { onSelect(index) }
                            .id(index)
                    }
                }
                .padding(.leading, 16).padding(.trailing, 16)
            }
            .onChange(of: selected) { _, index in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index) }
            }
        }
    }

    private func chip(_ label: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if chosen {
                    FilterIcon(glyph: .check)
                        .foregroundStyle(FilterPalette.textTag)
                        .frame(width: 18, height: 18)
                }
                PlazaText(value: label, size: 14, weight: chosen ? 600 : 500,
                          color: chosen ? FilterPalette.textTag : FilterPalette.text1)
                    .lineLimit(1)
            }
            .padding(.leading, chosen ? 10 : 14).padding(.trailing, 14)
            .frame(minHeight: 36)
            .frame(maxWidth: UIScreen.main.bounds.width - 48)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(FilterPalette.idleFill).opacity(chosen ? 0 : 1)
                    RoundedRectangle(cornerRadius: 18).fill(FilterPalette.selectedFill).opacity(chosen ? 1 : 0)
                }
                .animation(FilterPalette.fade, value: chosen)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(FilterPressStyle(ripple: VerticalInset(base: AnyShape(RoundedRectangle(cornerRadius: 10)), dy: 6)))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// 一条「名字 · 滑条 · 数值」。双向项（亮度、色温…）的滑条从中间往两边拉，过 0 时轻震一下；
/// 点数值复位到 `neutral`（不起作用的那一档：调节项不论单向双向都是 0，强度是 100）。
struct FilterSliderRow: View {
    let title: String
    let value: Int
    let bipolar: Bool
    let neutral: Int
    let enabled: Bool
    let onChange: (Int) -> Void

    static func signed(_ v: Int, _ bipolar: Bool) -> String { bipolar && v > 0 ? "+\(v)" : String(v) }

    var body: some View {
        let from = bipolar ? -100 : 0
        let clamped = min(max(value, from), 100)
        HStack(spacing: 0) {
            PlazaText(value: title, size: 14, weight: 600, color: FilterPalette.text1)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .leading)
            FilterM3Slider(value: clamped, from: from, to: 100, centered: bipolar, enabled: enabled) { v in
                if bipolar && v == 0 { UISelectionFeedbackGenerator().selectionChanged() }
                onChange(v)
            }
            .accessibilityLabel("\(title) \(Self.signed(clamped, bipolar))")
            Button { onChange(neutral) } label: {
                PlazaText(value: Self.signed(clamped, bipolar), size: 14, weight: 600, color: FilterPalette.textAccent)
                    .lineLimit(1)
                    .frame(minWidth: 48, minHeight: 48)
                    .contentShape(Circle())
            }
            .buttonStyle(FilterPressStyle(ripple: Circle()))
            .disabled(!enabled)
            .accessibilityHidden(true)
        }
        .frame(minHeight: 48)
        .opacity(enabled ? 1 : 0.38)
    }
}

/// Material Components 1.14 `Widget.Material3.Slider` 的自绘：16 高的轨道（外端 8 圆角、贴着滑块的一端 2 圆角），
/// 4 × 44 的竖条滑块，滑块两侧 6 的缝，轨道左右各 22 的内边距（16 + (16 − 4) / 2），未激活一端有 4 的停止点。
/// 居中模式（双向项）的激活段从中点长出，中点处同样留缝。
private struct FilterM3Slider: View {
    let value: Int
    let from: Int
    let to: Int
    let centered: Bool
    let enabled: Bool
    let onChange: (Int) -> Void

    private let sidePadding: CGFloat = 22
    private let trackHeight: CGFloat = 16
    private let outerCorner: CGFloat = 8
    private let insideCorner: CGFloat = 2
    private let thumbWidth: CGFloat = 4
    private let thumbHeight: CGFloat = 44
    private let gap: CGFloat = 6
    private let stopSize: CGFloat = 4

    @State private var lastEmitted: Int?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let trackWidth = max(w - sidePadding * 2, 1)
            let x = { (v: Int) -> CGFloat in sidePadding + CGFloat(v - from) / CGFloat(to - from) * trackWidth }
            let t = x(value)
            let mid = geo.size.height / 2
            let thumbReach = gap + thumbWidth / 2
            let start = sidePadding - outerCorner, end = w - sidePadding + outerCorner
            ZStack(alignment: .topLeading) {
                if centered {
                    let c = x((from + to) / 2)
                    if t > c + 0.5 {
                        segment(start, c - gap, mid, active: false, leadingOuter: true, trailingOuter: false)
                        segment(c + gap, t - thumbReach, mid, active: true, leadingOuter: false, trailingOuter: false)
                        segment(t + thumbReach, end, mid, active: false, leadingOuter: false, trailingOuter: true)
                    } else if t < c - 0.5 {
                        segment(start, t - thumbReach, mid, active: false, leadingOuter: true, trailingOuter: false)
                        segment(t + thumbReach, c - gap, mid, active: true, leadingOuter: false, trailingOuter: false)
                        segment(c + gap, end, mid, active: false, leadingOuter: false, trailingOuter: true)
                    } else {
                        segment(start, t - thumbReach, mid, active: false, leadingOuter: true, trailingOuter: false)
                        segment(t + thumbReach, end, mid, active: false, leadingOuter: false, trailingOuter: true)
                    }
                    stop(at: x(from), thumb: t, mid: mid)
                } else {
                    segment(start, t - thumbReach, mid, active: true, leadingOuter: true, trailingOuter: false)
                    segment(t + thumbReach, end, mid, active: false, leadingOuter: false, trailingOuter: true)
                }
                if value < to { stop(at: x(to), thumb: t, mid: mid) }
                RoundedRectangle(cornerRadius: thumbWidth / 2)
                    .fill(FilterPalette.primary)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .position(x: t, y: mid)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in emit(g.location.x, trackWidth) }
                    .onEnded { _ in lastEmitted = nil }
            )
        }
        .frame(height: 48)
        .allowsHitTesting(enabled)
        .accessibilityElement()
        .accessibilityValue(String(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 1, to))
            case .decrement: onChange(max(value - 1, from))
            @unknown default: break
            }
        }
    }

    private func emit(_ locationX: CGFloat, _ trackWidth: CGFloat) {
        let fraction = min(max((locationX - sidePadding) / trackWidth, 0), 1)
        let v = from + Int((fraction * CGFloat(to - from)).rounded())
        guard v != lastEmitted else { return }
        lastEmitted = v
        if v != value { onChange(v) }
    }

    @ViewBuilder
    private func segment(_ left: CGFloat, _ right: CGFloat, _ mid: CGFloat,
                         active: Bool, leadingOuter: Bool, trailingOuter: Bool) -> some View {
        if right - left > 0.5 {
            let half = (right - left) / 2
            let l = min(leadingOuter ? outerCorner : insideCorner, half)
            let r = min(trailingOuter ? outerCorner : insideCorner, half)
            UnevenRoundedRectangle(topLeadingRadius: l, bottomLeadingRadius: l,
                                   bottomTrailingRadius: r, topTrailingRadius: r)
                .fill(active ? FilterPalette.primary : FilterPalette.alpha20)
                .frame(width: right - left, height: trackHeight)
                .position(x: (left + right) / 2, y: mid)
        }
    }

    /// 停止点：落在滑块和它两侧的缝里时不画。
    @ViewBuilder
    private func stop(at x: CGFloat, thumb: CGFloat, mid: CGFloat) -> some View {
        if abs(x - thumb) > gap + thumbWidth / 2 {
            Circle()
                .fill(FilterPalette.primary)
                .frame(width: stopSize, height: stopSize)
                .position(x: x, y: mid)
        }
    }
}

/// `item_progress`（`SeamlessCircularProgressIndicator`）：30 直径、5 粗、圆头，白色指示 + 20% 白轨道；
/// 进度未知时一段弧持续旋转。
private struct FilterProgressRing: View {
    let progress: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().inset(by: 2.5).stroke(Color.white.opacity(0x33 / 255), lineWidth: 5)
            Circle().inset(by: 2.5)
                .trim(from: 0, to: progress.map { max(0.02, $0) } ?? 0.3)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90 + (progress == nil && spin ? 360 : 0)))
                .animation(progress == nil ? .linear(duration: 1.2).repeatForever(autoreverses: false) : .default, value: spin)
        }
        .onAppear { spin = true }
    }
}
