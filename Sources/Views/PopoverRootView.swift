// 弹窗根视图：头部 → 分隔 → 分组榜单 → 分隔 → 操作。
import AppKit
import SwiftUI

/// 菜单项动作集合（由 AppDelegate 注入）。
struct PopoverActions {
    var openWebsite: () -> Void
    var refresh: () -> Void
    var quit: () -> Void
}

/// 榜单内容的自然高度上报（滚动区高度靠它钉死，不依赖外部提议的尺寸）。
private struct BoardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 榜单以外的固定区域（头部 / 模式与筛选条 / 底部操作）的自然高度之和。
/// 榜单滚动区的上限由「屏幕可用高度 − 这部分实测高度」决定，长榜单或头部提示变长时
/// 底部的刷新 / 打开网站 / 退出也始终留在屏幕内、可点到，而不是靠一个写死的估算值。
private struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private extension View {
    func reportsChromeHeight() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ChromeHeightKey.self, value: geo.size.height)
        })
    }
}

struct PopoverRootView: View {
    @ObservedObject var vm: RadarViewModel
    let actions: PopoverActions

    @State private var boardHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HeaderView(vm: vm)
                Rectangle().fill(DS.divider).frame(height: 0.5)
            }
            .reportsChromeHeight()

            content

            VStack(spacing: 0) {
                Rectangle().fill(DS.divider).frame(height: 0.5)
                    .padding(.top, 6).padding(.bottom, 4)
                MenuListView(actions: actions)
            }
            .reportsChromeHeight()
        }
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .padding(.vertical, 6)
        .frame(width: DS.width)
        .background(
            ZStack {
                VisualEffectView()
                DS.containerBG.opacity(0.72)   // 叠 #242426 让毛玻璃透出细微底色
            }
        )
    }

    /// 榜单滚动区上限：按屏幕可用高度动态计算，尽量整屏展示全部条目，超出才滚动/限制。
    /// chromeHeight 是榜单以外固定区域的实测高度（首帧未测到时用 260 估算）；
    /// 外加 12 为根视图上下内边距，safetyMargin 给屏幕顶部菜单栏与底部留白，避免弹窗贴边。
    /// 屏幕再矮也至少留 120 的滚动区；其余情况下滚动区 + 固定区域恰好不超过屏幕，固定操作区始终可达。
    static func boardMaxHeight(screenHeight: CGFloat, chromeHeight: CGFloat) -> CGFloat {
        let chrome = chromeHeight > 0 ? chromeHeight + 12 : 260
        let safetyMargin: CGFloat = 40
        return max(120, screenHeight - chrome - safetyMargin)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = vm.snapshot {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ModeSwitchBar(vm: vm)
                    Rectangle().fill(DS.divider).frame(height: 0.5)

                    // 筛选行与榜单共用 snapshot.availableSections，顺序一致、不会筛出空组。
                    FilterBarView(vm: vm, sections: snapshot.availableSections)
                    Rectangle().fill(DS.divider).frame(height: 0.5)

                    // 场景推荐区：只在「完整榜单」模式展示——「模型推荐」视图本身就是推荐结论，
                    // 两套推荐口径（综合 IQ 场景推荐 vs 真实工程 IQ + 均价推荐）同时出现会互相打架。
                    // Radar Bench 没有站长场景推荐（insights 为空），该区自然不出现。
                    if vm.listMode == .full {
                        let showPicks = vm.boardFilter == nil || vm.boardFilter == .vendor(.openai)
                        let picks = showPicks ? ScenarioPicksView.groups(in: snapshot) : []
                        if !picks.isEmpty {
                            ScenarioPicksView(groups: picks)
                            Rectangle().fill(DS.divider).frame(height: 0.5)
                        }
                    }
                }
                .reportsChromeHeight()

                let maxHeight = Self.boardMaxHeight(
                    screenHeight: NSScreen.main?.visibleFrame.height ?? 900, chromeHeight: chromeHeight
                )
                // 榜单始终放在滚动区里，高度钉死为 min(自然高度, 上限)：放得下时高度恰好等于内容、
                // 视觉上不滚动；放不下才真的滚动。不能用 ViewThatFits —— 它按"外部提议的高度"二选一，
                // 而 popover 的提议高度反过来又取决于内容高度，会互相咬死（首帧只有两百多点时
                // 永远选中滚动分支，榜单被压成两三行），也会在无界提议下选中不滚动分支被裁掉。
                ScrollView(.vertical) {
                    boardContent(snapshot)
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: BoardHeightKey.self, value: geo.size.height)
                        })
                }
                .frame(height: boardHeight > 0 ? min(boardHeight, maxHeight) : nil)
                .onPreferenceChange(BoardHeightKey.self) { boardHeight = $0 }
                // 切换「只看前沿」/展开推荐行会一次性增减若干行，硬跳会很突兀。
                .animation(.easeInOut(duration: 0.2), value: vm.onlyFrontier)
                .animation(.easeInOut(duration: 0.2), value: vm.listMode)
                .animation(.easeInOut(duration: 0.2), value: vm.expandedRecommendationIDs)
            }
            .opacity(vm.isLoading ? 0.5 : 1)   // 刷新时降低透明度（骨架感）
            .animation(.easeInOut(duration: 0.2), value: vm.isLoading)
        } else if vm.lastError == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("加载中…").font(DF.pro(12, .regular)).foregroundStyle(DS.sec(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            Color.clear.frame(height: 8)   // 首次即失败：错误已在头部显示
        }
    }

    /// 按当前榜单模式分派：模型推荐（默认）走折叠分组视图，完整榜单走现有全量档位列表。
    @ViewBuilder
    private func boardContent(_ snapshot: RadarSnapshot) -> some View {
        switch vm.listMode {
        case .recommendation:
            ModelRecommendationBoardView(vm: vm, snapshot: snapshot)
        case .full:
            board(snapshot)
        }
    }

    /// 按 BoardSection.displayOrder 渲染分区（OpenAI → Claude Code → Grok → DeepSeek），
    /// 选中某个分区时只渲染那一个。组内一律按 IQ 降序；推荐结论在顶部场景推荐区，
    /// 行内只保留场景 chip（见 GroupRowView）。
    private func board(_ snapshot: RadarSnapshot) -> some View {
        let sections = snapshot.availableSections.filter { vm.boardFilter == nil || $0 == vm.boardFilter }
        return VStack(spacing: 0) {
            ForEach(sections) { section in
                switch section {
                case .vendor(let vendor):
                    if let group = snapshot.codexGroupsByVendor.first(where: { $0.vendor == vendor }) {
                        GroupSectionView(
                            title: section.title,
                            models: group.models,
                            isLocalEstimate: snapshot.codexSource == .localEstimate,
                            onlyFrontier: vm.onlyFrontier,
                            protectedID: snapshot.menuBarDisplayedID,
                            scoreColumnTitle: snapshot.benchmark.map { "分数 /\(Int($0.binding.scoreMax))" } ?? "IQ"
                        )
                    }
                case .claude:
                    GroupSectionView(
                        title: section.title,
                        models: snapshot.claudeDisplayGroup,
                        unavailable: snapshot.claudeStatus == .unavailable,
                        onlyFrontier: vm.onlyFrontier,
                        protectedID: snapshot.menuBarDisplayedID
                    )
                }
            }
        }
        .padding(.bottom, 2)
    }
}

/// 榜单上方的单行筛选器：全部 + 当前快照里有内容的分区（OpenAI / Claude Code / Grok / DeepSeek）。
/// 合并前是「范围」分段控件 + 「厂商」chip 两行，两行各有一个含义不同的「全部」，且切到
/// Claude Code 时第二行整行消失导致弹窗高度跳变；现在一行到底。
struct FilterBarView: View {
    @ObservedObject var vm: RadarViewModel
    let sections: [BoardSection]   // 顺序即 BoardSection.displayOrder

    var body: some View {
        // 自绘 capsule 而非原生 Picker(.menu)/Menu 下拉：AppDelegate 中 popover.behavior = .transient，
        // 原生下拉背后的 NSMenu 会开启独立事件跟踪循环，被 transient popover 判定为"外部交互"而立即关窗。
        // 自绘按钮全程停留在 SwiftUI/AppKit 同一事件循环内，不触发该问题。
        // 横向 ScrollView 只是兜底：分区变多或字体放大时不至于把最后一个 chip 挤没。
        // 分区筛选是单选组，「只看前沿」是独立开关，两者含义不同：开关固定在右端不随筛选滚走，
        // 中间用竖线隔断，避免被误读成第 N 个分区。
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    vendorChip(title: "全部", isSelected: vm.boardFilter == nil) { vm.boardFilter = nil }
                    ForEach(sections) { section in
                        vendorChip(title: section.title, isSelected: vm.boardFilter == section) {
                            vm.boardFilter = section
                        }
                    }
                }
                .padding(.leading, 15)
                .padding(.trailing, 8)
            }

            Rectangle().fill(DS.divider).frame(width: 0.5, height: 14)

            frontierChip
                .padding(.leading, 8)
                .padding(.trailing, 15)
        }
        .padding(.vertical, 8)
    }

    /// 「只看前沿」开关：选中态用 DS.orange —— 它管的正是价格标橙的那批被压制档位，同色自洽，
    /// 也一眼区分于蓝色的分区筛选。
    private var frontierChip: some View {
        Button { vm.onlyFrontier.toggle() } label: {
            Text("只看前沿")
                .font(DF.pro(10, .medium))
                .foregroundStyle(vm.onlyFrontier ? Color.white : DS.sec(0.55))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(vm.onlyFrontier ? DS.orange : Color.white.opacity(0.06)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("隐藏被同组更便宜档位压制的行")
        .accessibilityLabel("只看性价比前沿")
        .accessibilityAddTraits(vm.onlyFrontier ? [.isButton, .isSelected] : .isButton)
    }

    private func vendorChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DF.pro(10, .medium))
                .foregroundStyle(isSelected ? Color.white : DS.sec(0.55))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? DS.blue : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 榜单模式切换：模型推荐（默认）/ 完整榜单，仅两个选项。跟 FilterBarView 一样自绘 capsule
/// 而非原生 Picker(.menu)/Menu 下拉：AppDelegate 中 popover.behavior = .transient，原生下拉
/// 背后的 NSMenu 会开启独立事件跟踪循环，被 transient popover 判定为"外部交互"而立即关窗
/// （哪怕只是二选一的低频开关，NSMenu 事件循环一开，popover 照样被判定关闭，跟点击频率无关）。
struct ModeSwitchBar: View {
    @ObservedObject var vm: RadarViewModel

    var body: some View {
        // 说明文字单独成行（可换行、不挤占模式 chip 的横向空间），窄窗下也不会把 chip 或其右侧挤出可视区。
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                modeChip(.recommendation)
                modeChip(.full)
                Spacer(minLength: 0)
            }

            if let note = footnote {
                Text(note)
                    .font(DF.pro(9, .regular))
                    .foregroundStyle(DS.sec(0.35))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
    }

    /// 口径说明。Radar Bench：分数满分、费用是 API 等价估算而非订阅扣费，推荐是本地计算而非网站推荐。
    private var footnote: String? {
        if let bench = vm.snapshot?.benchmark {
            let scale = "分数满分 \(Int(bench.binding.scoreMax))"
            let cost = "$ 为 API 等价费用，非订阅扣费；* 为样本不全的已知样本均值"
            if vm.listMode == .recommendation {
                return "本地计算，非网站推荐：分数达该模型最高档 95% 内取费用最低；档位未读全、覆盖或费用样本不全时不推荐。\(scale)。\(cost)"
            }
            return "\(scale)。\(cost)"
        }
        guard vm.listMode == .recommendation else { return nil }
        return "推荐 = 真实工程 IQ 达该模型最高档 95% 内取价最低档；价格为等价按量计费估算，非订阅扣费"
    }

    private func modeChip(_ mode: ModelListMode) -> some View {
        let isSelected = vm.listMode == mode
        return Button { vm.listMode = mode } label: {
            Text(mode.title)
                .font(DF.pro(10, .medium))
                .foregroundStyle(isSelected ? Color.white : DS.sec(0.55))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? DS.blue : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#if DEBUG
#Preview("正常") { previewRoot(vm: .preview(previewSnapshot())) }
#Preview("加载态") { previewRoot(vm: .preview(isLoading: true)) }
#Preview("错误态") { previewRoot(vm: .preview(lastError: "无法连接 codexradar.com")) }

private func previewRoot(vm: RadarViewModel) -> PopoverRootView {
    PopoverRootView(
        vm: vm,
        actions: PopoverActions(openWebsite: {}, refresh: {}, quit: {})
    )
}

/// 接近真实线上规模的预览数据（Radar Bench 口径，固定 fixture、无随机性）：
/// 3 个模型 × 若干思考档，含一档覆盖不完整（暂定）与一档费用样本不全，用于验证榜单高度 clamp 与各类角标。
func previewSnapshot() -> RadarSnapshot {
    let layout: [(model: String, efforts: [String])] = [
        ("gpt-6.1-sol", ["low", "medium", "high", "xhigh", "max", "ultra"]),
        ("gpt-6-astra", ["low", "medium", "high", "xhigh", "max", "ultra"]),
        ("gpt-5.6-luna", ["low", "medium", "high", "xhigh", "max"]),
    ]
    let selections = layout.flatMap { item in item.efforts.map { BenchSelection(model: item.model, effort: $0) } }
    let binding = RadarBenchBinding(
        benchmark: "radar-bench-final64-20261004", catalogVersion: "preview",
        taskSetSHA256: String(repeating: "a", count: 64), scoreVersion: "radar-bench-v2-150",
        scoreMax: 150, totalTasks: 64, selections: selections
    )
    let now = Date()
    let read = now.addingTimeInterval(-14 * 60)
    var entries: [String: RadarBenchEntry] = [:]
    for (index, selection) in selections.enumerated() {
        let score = 96.0 - Double(index) * 3.4
        let partialCoverage = index == 9
        let partialCost = index == 1
        let cost = RadarBenchMetric(
            knownTotal: (0.4 + Double(index) * 0.35) * (partialCost ? 79 : 80),
            knownSamples: partialCost ? 79 : 80, missingSamples: partialCost ? 1 : 0, missingReason: nil
        )
        let elapsed = RadarBenchMetric(
            knownTotal: (240_000 + Double(index) * 38_000) * 80, knownSamples: 80, missingSamples: 0, missingReason: nil
        )
        let observation = RadarBenchObservation(
            selection: selection, schema: "radar-bench-public-summary-v6-150-details",
            benchmark: binding.benchmark, catalogVersion: binding.catalogVersion,
            taskSetSHA256: binding.taskSetSHA256, scoreVersion: binding.scoreVersion, scoreMax: 150,
            score: score, scoreStatus: partialCoverage ? "provisional" : "complete",
            coverage: partialCoverage ? 43 : 64, requiredTasks: 64, gradedRunsCount: 80, sampleCount: 80,
            costBasis: "official_standard_api_equivalent", elapsed: elapsed, apiEquivalentUSD: cost,
            latestGradedAt: now.addingTimeInterval(-9 * 3600), sourceAsOf: nil, raw: .object([:])
        )
        entries[selection.id] = RadarBenchEntry(observation: observation, fetchedAt: read)
    }
    return RadarBenchParser.makeSnapshot(binding: binding, entries: entries, now: now)!
}
#endif
