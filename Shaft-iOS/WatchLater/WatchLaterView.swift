import SwiftUI

/// "稍后再看" (Watch Later) list page — 1:1 port of upstream `WatchLaterFragment`:
/// a waterfall of the locally-saved works, most-recently-added first, with a
/// toolbar menu for "播放全部" (slideshow the whole list, shuffled) and "清空列表"
/// (clear, behind a confirm). Empty state mirrors `watch_later_empty`.
///
/// Storage lives in `WatchLaterStore`; because it's `@Observable`, adding or
/// removing a work from any card long-press updates this list live — the iOS
/// equivalent of upstream's `ACTION_WATCH_LATER_CHANGED` broadcast (upstream
/// deliberately avoids an onResume hard-reload so optimistic bookmark hearts
/// don't snap back; here the store simply is the source of truth, no reload).
struct WatchLaterView: View {
    @State private var store = WatchLaterStore.shared
    @State private var slideshowSeed: SlideshowSeed?
    @State private var showClearConfirm = false
    @State private var section: Section = .illust
    @Environment(OnboardingStore.self) private var l10n

    private enum Section: Hashable { case illust, novel }

    var body: some View {
        Group {
            if section == .novel {
                novelList
            } else if store.items.isEmpty {
                ContentUnavailableView(l10n.t(.watchLaterEmpty), systemImage: "clock.badge.checkmark")
            } else {
                // Local list: never loading, no errors, no pagination.
                // `prefiltered: true` — show every saved work, do NOT apply the
                // mute/R-18 filter. Parity with upstream `WatchLaterViewModel`,
                // which renders the raw DB rows unfiltered (a personal curated
                // queue, like bookmarks); filtering here would silently hide works
                // the user explicitly saved, and hide the list entirely if every
                // saved artist happened to be muted.
                IllustWaterfallList(
                    illusts: store.items,
                    isLoading: false,
                    errorMessage: nil,
                    onRefresh: {},
                    prefiltered: true
                )
            }
        }
        .navigationTitle(l10n.t(.watchLaterTitle))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SoftTopBar {
            // Upstream keeps novels in a second list (`isNovelInWatchLater`).
            Picker("", selection: $section) {
                Text(l10n.t(.dynTypeIllustManga)).tag(Section.illust)
                Text(l10n.t(.dynTypeNovel)).tag(Section.novel)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        })
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if section == .novel {
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label(l10n.t(.watchLaterClear), systemImage: "trash")
                        }
                    } else {
                        Button {
                            // "播放全部": shuffle the whole saved list (upstream
                            // `SlideshowLauncher.launchFromIllustsBeans`, random = true).
                            if let first = store.items.first {
                                slideshowSeed = SlideshowBuilder.seed(from: store.items, tapped: first)
                            }
                        } label: {
                            Label(l10n.t(.watchLaterPlayAll), systemImage: "play.rectangle.on.rectangle")
                        }
                        Button(role: .destructive) {
                            showClearConfirm = true
                        } label: {
                            Label(l10n.t(.watchLaterClear), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(section == .novel ? store.novelItems.isEmpty : store.items.isEmpty)
            }
        }
        .confirmationDialog(
            l10n.t(.watchLaterClearConfirm),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(l10n.t(.watchLaterClearOk), role: .destructive) {
                if section == .novel { store.clearNovels() } else { store.clear() }
            }
            Button(l10n.t(.actionCancel), role: .cancel) {}
        }
        .fullScreenCover(item: $slideshowSeed) { SlideshowView(seed: $0) }
    }

    @ViewBuilder
    private var novelList: some View {
        if store.novelItems.isEmpty {
            ContentUnavailableView(l10n.t(.watchLaterEmpty), systemImage: "clock.badge.checkmark")
        } else {
            ScrollView {
                NovelListContent(novels: store.novelItems, hasMore: false, onLoadMore: nil)
            }
        }
    }
}

/// The section picker pinned under the navigation bar. iOS 26+: a `safeAreaBar`, so the list
/// scrolls under it with the system soft scroll-edge effect (set explicitly — built with the
/// iOS 27 SDK, `automatic` turns hard for `safeAreaBar`). Earlier systems: a bar-material inset.
private struct SoftTopBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
        }
    }
}
