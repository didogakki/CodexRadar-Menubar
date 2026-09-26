// 分组：组标题（名 + 右侧细线）+ 组内行，一律按 IQ 降序；推荐结论由顶部场景推荐区承担。
import SwiftUI

struct GroupSectionView: View {
    let title: String
    let models: [ScoredModel]   // 已按展示顺序排列（解析层决定）
    var unavailable: Bool = false   // 该组数据抓取失败时显示提示行
    var isLocalEstimate: Bool = false   // Codex 回退到 current.json 本地估算时明确标注
    var onlyFrontier: Bool = false      // 只看性价比前沿：隐藏被压制的行
    var protectedID: String? = nil      // 菜单栏当前档位：被压制也不隐藏，避免菜单栏结论在榜单里消失

    var body: some View {
        if unavailable {
            VStack(alignment: .leading, spacing: 0) {
                header(hiddenCount: 0)
                Text("因网页格式变化，Claude 数据提取失败")
                    .font(DF.pro(11, .regular))
                    .foregroundStyle(DS.sec(0.45))
                    .padding(.horizontal, 15)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }
        } else if !models.isEmpty {
            // 性价比判定只在本组内做，整组算一次后分发给各行（见 CostEfficiency）。
            // 判定始终基于**全量** models：先过滤再判定会让前沿基准漂移（隐藏掉压制者后，
            // 被压制的行反而会翻身变成前沿）。过滤只作用于展示。
            let verdicts = CostEfficiency.verdicts(in: models)
            // 名次色沿用全量列表里的原始位次，切换开关不会让同一行改变颜色。
            let rows = Array(models.enumerated()).filter { isVisible($0.element, verdicts: verdicts) }
            VStack(alignment: .leading, spacing: 0) {
                header(hiddenCount: models.count - rows.count)
                ForEach(rows, id: \.element.id) { index, model in
                    GroupRowView(model: model, color: DS.rankColor(index), verdict: verdicts[model.id])
                        // 被压制却因推荐/菜单栏豁免而留下的行：淡化，表明它本该被这个开关藏起来。
                        .opacity(onlyFrontier && isDominated(model, verdicts: verdicts) ? 0.55 : 1)
                }
            }
        }
    }

    /// 缺价格或耗时的行没有判定（价格显示中性灰），不算被压制。
    private func isDominated(_ model: ScoredModel, verdicts: [String: CostVerdict]) -> Bool {
        verdicts[model.id]?.isDominated ?? false
    }

    /// 开关关闭时全展示；开启时按 FrontierFilter 的规则过滤。
    private func isVisible(_ model: ScoredModel, verdicts: [String: CostVerdict]) -> Bool {
        guard onlyFrontier else { return true }
        return FrontierFilter.isVisible(model, verdicts: verdicts, protectedID: protectedID)
    }

    /// 组标题：名 + 占满剩余宽度的细线 + 右侧列标注（本地估算回退时明确标出，
    /// 「只看前沿」隐藏了行时追加隐藏条数）。
    private func header(hiddenCount: Int) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(DF.mono(10, .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.72))
            Rectangle()
                .fill(DS.groupLine)
                .frame(height: 0.5)
            Text(isLocalEstimate ? "本地估算" : (hiddenCount > 0 ? "IQ · 隐藏 \(hiddenCount)" : "IQ"))
                .font(DF.pro(9, .regular))
                .foregroundStyle(isLocalEstimate ? DS.orange.opacity(0.8) : DS.sec(0.35))
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }
}

// MARK: - 模型推荐视图：按 BoardSection 分组，组内每个「模型 + 指标来源」折叠一行。
//
// 推荐结论由 RadarModels.swift 的 ModelRecommendation 纯函数计算，本视图只负责渲染；
// 分组来源固定为 RadarSnapshot.recommendationGroups（全量数据，已按 codexSource 做过可靠性
// 降级），不受 CodexDisplayQuality 等展示层质量过滤影响——那些只决定「完整榜单」怎么显示。
// 「只看前沿」在这里则确实生效：判定用组的展示代表档（推荐档/唯一档）与完整榜单同一批
// CostEfficiency 比较，过滤只作用于展示，不改变推荐判定依据的候选池，见 sectionBody。

/// 模型推荐榜单：按 BoardSection.displayOrder 渲染分区，厂商筛选（vm.boardFilter）与完整榜单共用。
struct ModelRecommendationBoardView: View {
    @ObservedObject var vm: RadarViewModel
    let snapshot: RadarSnapshot

    var body: some View {
        let sections = snapshot.availableSections.filter { vm.boardFilter == nil || $0 == vm.boardFilter }
        VStack(spacing: 0) {
            ForEach(sections) { section in
                switch section {
                case .vendor:
                    sectionBody(section)
                case .claude:
                    if snapshot.claudeStatus == .unavailable {
                        unavailableClaudeSection
                    } else {
                        sectionBody(section)
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func sectionBody(_ section: BoardSection) -> some View {
        let groups = snapshot.recommendationGroups(for: section)
        if !groups.isEmpty {
            // 性价比判定必须基于分区**全部原始 tiers**（含每个模型未被选为代表档的其它档位），
            // 且始终基于全量 groups——先过滤再判定会让前沿基准漂移，见 GroupSectionView 同名注释。
            // 只用代表档算 verdicts 会漏掉「压制者本身不是任何组代表档」的情况，见
            // ModelRecommendationFrontierFilter 头部注释。
            let verdicts = CostEfficiency.verdicts(in: groups.flatMap(\.tiers))
            let menuBarID = snapshot.menuBarBest?.id
            let visible = groups.filter { isVisible($0, verdicts: verdicts, menuBarID: menuBarID) }
            // 圆点颜色沿用该条目在完整榜单里的原始排名位次，不按这里的折叠分组顺序重新计数——
            // 同一条目切换「模型推荐」/「完整榜单」看到的应是同一个颜色。展示层过滤掉、不在
            // 完整榜单里出现的条目没有位次，退化为最低排名色。
            let fullList = fullBoardModels(for: section)
            let duplicateNames = duplicateModelNames(in: groups)
            VStack(alignment: .leading, spacing: 0) {
                header(section.title, hiddenCount: groups.count - visible.count)
                ForEach(visible, id: \.id) { group in
                    ModelRecommendationRowView(
                        group: group,
                        color: rankColor(for: group.outcome.displayModel, in: fullList),
                        showsSourceTag: duplicateNames.contains(group.modelName),
                        isExpanded: vm.expandedRecommendationIDs.contains(group.id),
                        onToggle: { vm.toggleRecommendationExpanded(group.id) },
                        onlyFrontier: vm.onlyFrontier,
                        verdicts: verdicts,
                        menuBarID: menuBarID
                    )
                    .opacity(vm.onlyFrontier && isDominated(group, verdicts: verdicts) ? 0.55 : 1)
                }
            }
        }
    }

    /// 开关关闭时全展示；开启时按 ModelRecommendationFrontierFilter 的整组规则过滤
    /// （新推荐档 / 菜单栏档 / 旧站长推荐豁免落在组内任意一档都保留，见其注释）。
    private func isVisible(_ group: ModelRecommendationGroup, verdicts: [String: CostVerdict], menuBarID: String?) -> Bool {
        guard vm.onlyFrontier else { return true }
        return ModelRecommendationFrontierFilter.isGroupVisible(group, verdicts: verdicts, menuBarID: menuBarID)
    }

    /// 缺代表档（无可靠数据）的组没有判定，不算被压制。
    private func isDominated(_ group: ModelRecommendationGroup, verdicts: [String: CostVerdict]) -> Bool {
        guard let model = group.outcome.displayModel else { return false }
        return verdicts[model.id]?.isDominated ?? false
    }

    /// 该分区在「完整榜单」模式下实际展示的列表（与 PopoverRootView.board 同一数据源），
    /// 用于取圆点颜色的原始排名位次。
    private func fullBoardModels(for section: BoardSection) -> [ScoredModel] {
        switch section {
        case .vendor(let vendor):
            return snapshot.codexGroupsByVendor.first { $0.vendor == vendor }?.models ?? []
        case .claude:
            return snapshot.claudeDisplayGroup
        }
    }

    private func rankColor(for model: ScoredModel?, in fullList: [ScoredModel]) -> Color {
        guard let model, let index = fullList.firstIndex(where: { $0.id == model.id }) else {
            return DS.rankColor(fullList.count)
        }
        return DS.rankColor(index)
    }

    /// 本分区内出现多次的模型名（同名不同 metricSource 时才会出现，见 MetricSource 的注释；
    /// Claude Code 分区目前只来自 codexradar 竞品条目，实际不会触发，仅为未来兼容保留）——
    /// 这些行需要来源小标签区分。
    private func duplicateModelNames(in groups: [ModelRecommendationGroup]) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for group in groups {
            if !seen.insert(group.modelName).inserted { duplicates.insert(group.modelName) }
        }
        return duplicates
    }

    private var unavailableClaudeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(BoardSection.claude.title)
            Text("因网页格式变化，Claude 数据提取失败")
                .font(DF.pro(11, .regular))
                .foregroundStyle(DS.sec(0.45))
                .padding(.horizontal, 15)
                .padding(.top, 2)
                .padding(.bottom, 8)
        }
    }

    private func header(_ title: String, hiddenCount: Int = 0) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(DF.mono(10, .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.72))
            Rectangle().fill(DS.groupLine).frame(height: 0.5)
            Text(hiddenCount > 0 ? "推荐 · 隐藏 \(hiddenCount)" : "推荐")
                .font(DF.pro(9, .regular))
                .foregroundStyle(DS.sec(0.35))
        }
        .padding(.horizontal, 15)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }
}

/// 单个「模型 + 指标来源」折叠行：圆点(排名色) + 模型名 + 推荐结论摘要 + 展开箭头；
/// 展开后按 DepthTier 顺序列出该模型全部档位，推荐档轻高亮。键盘/VoiceOver 可达：
/// 折叠行是一个 Button，可通过空格/回车展开收起，accessibilityValue 播报当前展开状态。
struct ModelRecommendationRowView: View {
    let group: ModelRecommendationGroup
    let color: Color
    var showsSourceTag: Bool = false   // 本分区内有同名不同来源的行时打开，标出本行来自哪个站点
    let isExpanded: Bool
    let onToggle: () -> Void
    var onlyFrontier: Bool = false               // 全局「只看前沿」开关（展开列表随之过滤）
    var verdicts: [String: CostVerdict] = [:]    // 分区全量 tiers 算出的性价比判定，见 sectionBody
    var menuBarID: String? = nil                 // 菜单栏当前档位，保护名单之一

    /// 行内局部覆盖：不改变全局 onlyFrontier 开关，只让这一行的展开列表临时显示全部档位。
    @State private var forceShowAllTiers = false

    /// 按 ModelRecommendationFrontierFilter 规则过滤后的档位（不受 forceShowAllTiers 影响，
    /// 用来算隐藏条数与决定是否展示「显示全部档位」按钮）。
    private var filteredTiers: [ScoredModel] {
        ModelRecommendationFrontierFilter.visibleTiers(
            in: group, verdicts: verdicts, menuBarID: menuBarID, forceShowAll: false
        )
    }

    /// 实际渲染的档位：全局开关关闭，或用户点了「显示全部档位」，都展示全部；否则展示过滤后的。
    private var displayedTiers: [ScoredModel] {
        (!onlyFrontier || forceShowAllTiers) ? group.tiers : filteredTiers
    }

    private var hiddenTierCount: Int { group.tiers.count - filteredTiers.count }

    /// 只有真正存在多个档位时才可展开——单档没有东西可展开，不渲染 chevron、不响应点击。
    /// 判断逻辑见 ModelRecommendationGroup.isExpandable。
    private var canExpand: Bool { group.isExpandable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if canExpand {
                Button(action: onToggle) { collapsedRow }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                    .accessibilityHint("双击展开查看该模型全部档位")
            } else {
                collapsedRow
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(accessibilityLabel)
            }

            if canExpand && isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedTiers, id: \.id) { tier in
                        expandedTierRow(tier)
                    }
                    if onlyFrontier && (hiddenTierCount > 0 || forceShowAllTiers) {
                        expandedTierToggle(hiddenCount: hiddenTierCount)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    /// 「显示全部档位 N」/「恢复前沿筛选」：只作用于本行展开列表，不动全局 onlyFrontier 开关。
    private func expandedTierToggle(hiddenCount: Int) -> some View {
        Button {
            forceShowAllTiers.toggle()
        } label: {
            Text(forceShowAllTiers ? "恢复前沿筛选" : "显示全部档位 \(hiddenCount)")
                .font(DF.pro(9, .medium))
                .foregroundStyle(DS.sec(0.4))
        }
        .buttonStyle(.plain)
        .padding(.leading, GroupRowView.RowMetrics.horizontalPadding + 14)
        .padding(.vertical, 4)
    }

    /// 折叠代表行与展开档位行共用的数字列宽（价格/IQ/末尾箭头），trailing 对齐，
    /// 保证两种行在同一模型内数字右沿完全对齐，不随某一行缺价格/缺展开箭头而错位。
    private enum TierColumnMetrics {
        static let priceWidth: CGFloat = 52     // 容纳 "$99.9" 一类价格，缺价格时留空列
        static let iqWidth: CGFloat = 54        // 容纳 "IQ 120.0"
        static let arrowWidth: CGFloat = 14     // 折叠行 chevron 宽度；展开行用同宽透明占位对齐右沿
    }

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(group.modelName)
                .font(DF.mono(12, .semibold))
                .foregroundStyle(DS.text92)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsSourceTag {
                Text(group.metricSource.shortTag)
                    .font(DF.mono(8, .medium))
                    .foregroundStyle(DS.sec(0.4))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .fixedSize()
            }
            if let depth = group.outcome.displayModel?.result.depth {
                Text(depth)
                    .font(DF.mono(11, .medium))
                    .foregroundStyle(DS.sec(0.5))
                    .fixedSize()
                    .layoutPriority(1)
            }
            if let note = collapsedNote {
                Text(note)
                    .font(DF.pro(9, .regular))
                    .foregroundStyle(DS.sec(0.4))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let model = group.outcome.displayModel {
                Group {
                    if let cost = model.validCostLabel {
                        Text(cost)
                            .font(DF.mono(11, .medium))
                            .monospacedDigit()
                            .foregroundStyle(DS.sec(0.45))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(width: TierColumnMetrics.priceWidth, alignment: .trailing)
                HStack(spacing: 3) {
                    Text("IQ").font(DF.pro(8, .regular)).foregroundStyle(DS.sec(0.4))
                    Text(model.iqLabel)
                        .font(DF.mono(13, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(DS.iqColor(model.iq))
                }
                .frame(width: TierColumnMetrics.iqWidth, alignment: .trailing)
            }
            if canExpand {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DS.sec(0.3))
                    .frame(width: TierColumnMetrics.arrowWidth, alignment: .trailing)
            } else {
                Color.clear.frame(width: TierColumnMetrics.arrowWidth, height: 1)
            }
        }
        .padding(.vertical, GroupRowView.RowMetrics.verticalPadding)
        .padding(.horizontal, GroupRowView.RowMetrics.horizontalPadding)
        .contentShape(Rectangle())
    }

    /// 折叠行的推荐结论备注：推荐档、单档都不需要额外文案——单档时真实档名已经通过
    /// `group.outcome.displayModel?.result.depth` 展示在行内，不用再加「仅一档」这种暗示
    /// 「比较过」的文案；无成绩、无价格两种情况仍需明确说明，避免误以为是可靠推荐。
    private var collapsedNote: String? {
        switch group.outcome {
        case .recommended, .singleComparableTier:
            return nil
        case .unavailable(.noValidScore):
            return "暂无可靠推荐 · 无有效成绩"
        case .unavailable(.noValidPrice):
            return "暂无可靠推荐 · 无有效价格"
        case .unavailable(.unreliableCodexSource):
            return "暂无可靠推荐 · 数据源降级（本地估算/站长推荐）"
        }
    }

    private func expandedTierRow(_ tier: ScoredModel) -> some View {
        let isRecommended = group.outcome.recommendedID == tier.id
        return HStack(spacing: 8) {
            Text(tier.result.depth)
                .font(DF.mono(11, isRecommended ? .semibold : .regular))
                .foregroundStyle(isRecommended ? DS.text88 : DS.sec(0.5))
                .frame(width: 52, alignment: .leading)
            if isRecommended {
                Text("推荐")
                    .font(DF.pro(8, .semibold))
                    .foregroundStyle(DS.blue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.blue.opacity(0.16)))
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Group {
                if let cost = tier.validCostLabel {
                    Text(cost)
                        .font(DF.mono(11, isRecommended ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isRecommended ? DS.green : DS.sec(0.4))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(width: TierColumnMetrics.priceWidth, alignment: .trailing)
            HStack(spacing: 3) {
                Text("IQ").font(DF.pro(8, .regular)).foregroundStyle(DS.sec(0.35))
                Text(tier.iqLabel)
                    .font(DF.mono(12, isRecommended ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(DS.iqColor(tier.iq))
            }
            .frame(width: TierColumnMetrics.iqWidth, alignment: .trailing)
            // 同宽透明箭头占位：折叠行末尾有 chevron，展开行没有，靠这个占位对齐两者右沿。
            Image(systemName: "chevron.up")
                .font(.system(size: 8, weight: .semibold))
                .opacity(0)
                .frame(width: TierColumnMetrics.arrowWidth, alignment: .trailing)
        }
        .padding(.leading, GroupRowView.RowMetrics.horizontalPadding + 14)
        .padding(.trailing, GroupRowView.RowMetrics.horizontalPadding)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(tier.result.depth) 档，IQ \(tier.iqLabel)"
                + (tier.validCostLabel.map { "，\($0)" } ?? "")
                + (isRecommended ? "，推荐档位" : "")
        )
    }

    private var accessibilityLabel: String {
        var parts = [group.modelName]
        switch group.outcome {
        case .recommended(let model, let maxIQ, let threshold):
            parts.append("推荐 \(model.result.depth) 档")
            parts.append("IQ \(model.iqLabel)")
            if let cost = model.validCostLabel { parts.append("价格 \(cost)") }
            parts.append("门槛为最高档 IQ \(String(format: "%.1f", maxIQ)) 的 95%，即 \(String(format: "%.1f", threshold))")
        case .singleComparableTier(let model):
            parts.append("仅一档可比较：\(model.result.depth)，IQ \(model.iqLabel)")
        case .unavailable(.noValidScore):
            parts.append("暂无可靠推荐，无有效成绩")
        case .unavailable(.noValidPrice):
            parts.append("暂无可靠推荐，无有效价格")
        case .unavailable(.unreliableCodexSource):
            parts.append("暂无可靠推荐，数据源为本地估算或站长推荐，非网站权威测量")
        }
        return parts.joined(separator: "，")
    }
}
