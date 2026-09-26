// 视图层使用的领域模型（已与解码层解耦）。
// 主路径：站长推荐（radar-insights）+ 智力效率（intelligence-efficiency-metrics）为权威源；
// current.json 综合分公式只保留为完整失败回退（本地估算）。
import Foundation

/// Claude 参考数据（来自 codexradar 的 claude-* 竞品条目，见 RadarParser.mergeAnthropicIntoClaude）的可用状态。
enum ClaudeStatus {
    case ok
    case unavailable
}

/// 指标来源 —— 同一分区里可能混着两个站点的数据，量级不可横比（任务集不同，
/// claudecoderadar 的花费是 $10~127 量级，codexradar 竞品列是 $1.7~17）。
/// 只用于把性价比判定限制在同源内，不参与排序与分组。
enum MetricSource: Hashable {
    case codexRadar    // codexradar.com（intelligence-efficiency / insights / current.json）
    case claudeRadar   // claudecoderadar.com

    /// 「模型推荐」折叠行同名去重标签：同一模型名在两个源都出现时（如 Claude Code 分区里
    /// claudecoderadar 直测 + codexradar 竞品列各一份），仅凭模型名无法区分是哪一条，
    /// 需要一个短标签。measured/listed 用来暗示两者性质不同——不是同一份数据的两种展示。
    var shortTag: String {
        switch self {
        case .codexRadar:  return "codexradar"
        case .claudeRadar: return "claudecoderadar"
        }
    }
}

/// 模型族 —— 决定分组归属。
enum ModelFamily {
    case codex
    case claude

    /// 组标题（正常大小写）。
    var title: String {
        switch self {
        case .codex:  return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

/// 厂商 —— 弹窗榜单内 Codex 模型的展示子分组，由模型名前缀/关键字派生。
enum ModelVendor: String, CaseIterable, Hashable {
    case openai
    case xai
    case deepseek
    case google
    case zhipu
    case moonshot
    case tencent
    case other

    /// 组标题。
    var title: String {
        switch self {
        case .openai:   return "OpenAI"
        case .xai:      return "Grok"
        case .deepseek: return "DeepSeek"
        case .google:   return "Google"
        case .zhipu:    return "智谱"
        case .moonshot: return "Moonshot"
        case .tencent:  return "腾讯"
        case .other:    return "其他"
        }
    }

    /// 按模型名前缀/关键字派生厂商（大小写不敏感）；未知前缀归入"其他"，不丢弃模型。
    /// Anthropic/Claude 命名的竞品条目不参与本归类，由 `isAnthropicCompetitor` 单独识别并
    /// 整体从 Codex 展示中剔除（见 RadarSnapshot.codexGroupsByVendor 的注释）。
    static func from(modelName: String) -> ModelVendor {
        let n = modelName.lowercased()
        if n.hasPrefix("gpt-") { return .openai }
        if n.hasPrefix("grok-") { return .xai }
        if n.contains("deepseek") { return .deepseek }
        if n.contains("gemini") || n.hasPrefix("google") { return .google }
        if n.contains("glm") || n.contains("zhipu") { return .zhipu }
        if n.contains("kimi") || n.hasPrefix("moonshot") { return .moonshot }
        if n.contains("hunyuan") || n.hasPrefix("tencent") { return .tencent }
        return .other
    }

    /// Codex 竞品列表中的 Anthropic/Claude 命名条目：不进 Codex 榜单（不归入任何厂商，含"其他"），
    /// 而是由 RadarParser.mergeAnthropicIntoClaude 并入 Claude Code 分区，与 claudecoderadar 的数据同区展示。
    /// 两个源任务集不同、花费量级差一个数量级，性价比判定按 metricSource 分桶隔离（见 CostEfficiency）。
    static func isAnthropicCompetitor(modelName: String) -> Bool {
        modelName.lowercased().hasPrefix("claude-")
    }

    /// Codex 侧弹窗展示白名单：由 BoardSection.displayOrder 派生，顺序与榜单/筛选行完全一致，
    /// 不再两处各写一份。未列入的厂商（Google/智谱/Moonshot/腾讯/其他）整体隐藏，
    /// 不影响 snapshot.all / codexGroup 等权威数据。
    static var displayWhitelist: [ModelVendor] {
        BoardSection.displayOrder.compactMap { section in
            if case .vendor(let vendor) = section { return vendor }
            return nil
        }
    }
}

/// 榜单分区。`displayOrder` 是单一事实来源：既是弹窗里分组的上下顺序，也是筛选行的左右顺序。
enum BoardSection: Hashable, Identifiable {
    case vendor(ModelVendor)   // Codex 侧的厂商分组
    case claude                // Claude Code 参考组

    /// 展示顺序：OpenAI → Claude Code → Grok → DeepSeek。
    static let displayOrder: [BoardSection] = [.vendor(.openai), .claude, .vendor(.xai), .vendor(.deepseek)]

    var id: String {
        switch self {
        case .vendor(let vendor): return vendor.rawValue
        case .claude:             return "claude"
        }
    }

    var title: String {
        switch self {
        case .vendor(let vendor): return vendor.title
        case .claude:             return ModelFamily.claude.title
        }
    }
}

/// 弹窗榜单展示模式：「模型推荐」（默认，按「模型 + 指标来源」折叠展示推荐结论）/
/// 「完整榜单」（现有全部档位列表，行为不变）。跨会话记忆，见 RadarViewModel.listMode。
enum ModelListMode: String {
    case recommendation
    case full

    var title: String {
        switch self {
        case .recommendation: return "模型推荐"
        case .full:           return "完整榜单"
        }
    }
}

/// Codex 弹窗展示层质量过滤阈值（集中管理，只影响榜单展示，不影响综合分/menuBarBest/菜单栏标题）。
enum CodexDisplayQuality {
    static let minTasks = 20
    static let minIQ = 50.0
    static let minDepthIQRatio = 0.6

    /// 过滤样本量过少（tasks < minTasks）或质量过低（iq < minIQ）的候选；
    /// 推荐项（recommendedIn 非空）、menuBarBest、gpt-* 始终保留，避免误伤权威推荐与菜单栏一致性。
    /// 随后按模型名分组，过滤同一模型内 IQ 低于该模型（组内幸存档位中）最高档位 minDepthIQRatio 的思考档位；
    /// 最高档位与自身的比值恒为 1，天然保留，无需额外特判；推荐项/menuBarBest 同样豁免此过滤。
    static func filtered(_ models: [ScoredModel], menuBarBestID: String?) -> [ScoredModel] {
        let protectedIDs = Set(models.filter { !$0.recommendedIn.isEmpty }.map(\.id))
            .union(menuBarBestID.map { [$0] } ?? [])

        let afterThreshold = models.filter { model in
            if protectedIDs.contains(model.id) || model.result.isGPTModel { return true }
            return model.result.tasks >= minTasks && model.result.iq >= minIQ
        }

        let maxIQByName = Dictionary(grouping: afterThreshold, by: \.result.name)
            .mapValues { $0.map(\.result.iq).max() ?? 0 }

        return afterThreshold.filter { model in
            if protectedIDs.contains(model.id) { return true }
            guard let maxIQ = maxIQByName[model.result.name], maxIQ > 0 else { return true }
            return model.result.iq >= maxIQ * minDepthIQRatio
        }
    }
}

/// Codex 弹窗展示层单档收敛：gpt-5.6-terra / gpt-5.6-luna 候选档位较多，只展示一档，避免挤占版面。
/// 只影响展示层分组，不影响 snapshot.all/menuBarBest 等权威数据。
enum CodexSingleTierCondense {
    /// 需要收敛为单档展示的模型名（与 result.name 小写完全匹配）。
    static let targetNames: Set<String> = ["gpt-5.6-terra", "gpt-5.6-luna"]

    /// 收敛规则：菜单栏当前最佳档位（menuBarBestID）优先，即使不是该模型 IQ 最高档；
    /// 该模型候选中没有命中 menuBarBest 时取 IQ 最高档；IQ 并列时取 depth 字典序最小的一档，
    /// 保证结果确定、可测试。
    static func filtered(_ models: [ScoredModel], menuBarBestID: String?) -> [ScoredModel] {
        let targetGroups = Dictionary(
            grouping: models.filter { targetNames.contains($0.result.name.lowercased()) },
            by: { $0.result.name.lowercased() }
        )
        guard !targetGroups.isEmpty else { return models }

        var survivorIDs = Set<String>()
        for candidates in targetGroups.values {
            if let menuBarBestID, let matched = candidates.first(where: { $0.id == menuBarBestID }) {
                survivorIDs.insert(matched.id)
                continue
            }
            let winner = candidates.sorted { a, b in
                a.result.iq != b.result.iq ? a.result.iq > b.result.iq : a.result.depth < b.result.depth
            }.first
            if let winner { survivorIDs.insert(winner.id) }
        }

        let droppedIDs = Set(targetGroups.values.flatMap { $0.map(\.id) }).subtracting(survivorIDs)
        return models.filter { !droppedIDs.contains($0.id) }
    }
}

/// Codex 弹窗展示层 DeepSeek 分组限额：现有质量过滤（+ 单档收敛）后最多展示 3 个候选；
/// 推荐项优先保留，推荐项数量超过 3 个时全部保留（不误伤站长推荐）。只影响展示层，不影响权威数据。
enum DeepSeekDisplayLimit {
    static let maxCount = 3

    /// 推荐项无条件保留（榜单按 IQ 排序后它们可能落在任意位置），其余保序补足到 maxCount 为止。
    static func limited(_ models: [ScoredModel]) -> [ScoredModel] {
        let recommendedIDs = Set(models.filter { !$0.recommendedIn.isEmpty }.map(\.id))
        var remainingSlots = max(maxCount - recommendedIDs.count, 0)
        return models.filter { model in
            if recommendedIDs.contains(model.id) { return true }
            guard remainingSlots > 0 else { return false }
            remainingSlots -= 1
            return true
        }
    }

    /// 同一限额应用到「模型推荐」折叠分组：一组一个模型，与完整榜单展示同样多的候选，
    /// 避免同一 DeepSeek 分区在两种模式下看到不一样的条数。推荐判定（ModelRecommendationOutcome）
    /// 已经用全量档位算完，这里只砍展示的组数，不重算、不合并任何组——不同模型/不同 metricSource
    /// 天然是独立的组（见 groupedForRecommendation），不存在"合并冒充同一模型"的风险。
    /// 保护规则与 limited(_:) 一致：组内任一档位带站长推荐（recommendedIn 非空）即整组无条件保留。
    static func limitedGroups(_ groups: [ModelRecommendationGroup]) -> [ModelRecommendationGroup] {
        let protectedIDs = Set(groups.filter { group in
            group.tiers.contains { !$0.recommendedIn.isEmpty }
        }.map(\.id))
        var remainingSlots = max(maxCount - protectedIDs.count, 0)
        return groups.filter { group in
            if protectedIDs.contains(group.id) { return true }
            guard remainingSlots > 0 else { return false }
            remainingSlots -= 1
            return true
        }
    }
}

/// 「只看前沿」展示层过滤：隐藏被组内其他档位压制的行。纯展示层，不影响权威数据与菜单栏选型。
enum FrontierFilter {
    /// 判定必须由调用方在**全量**组内算好后传入：先过滤再判定会让前沿基准漂移
    /// （隐藏掉压制者之后，被压制的行反而会翻身变成前沿）。
    ///
    /// 保留三类行：未被压制的、没有判定的（缺价格或耗时，价格显示中性灰，不算被压制）、
    /// 以及推荐项与菜单栏档位——顶部场景推荐区固定展示这些档位，榜单里对应行消失
    /// 会造成「上面推荐了、下面找不到」。豁免留下的行由视图淡化显示。
    static func isVisible(
        _ model: ScoredModel,
        verdicts: [String: CostVerdict],
        protectedID: String? = nil,
        additionalProtectedID: String? = nil
    ) -> Bool {
        guard verdicts[model.id]?.isDominated ?? false else { return true }
        return !model.recommendedIn.isEmpty || model.id == protectedID || model.id == additionalProtectedID
    }
}

/// 「模型推荐」折叠视图的整组前沿可见性 + 展开档位前沿可见性。纯展示层，
/// 不改变推荐判定（ModelRecommendation）或权威数据；调用方在 verdicts 计算与保护名单的选择上
/// 必须遵守下面两条不变量，否则会重新引入过的两个 bug：
///
/// 1. verdicts 必须由分区**全部原始 tiers**（`groups.flatMap(\.tiers)`，与推荐判定同一份候选池，
///    含每个模型未被选为代表档的其它档位）算出——只用各组代表档算 verdicts 会漏掉「压制者本身
///    不是任何组的代表档」这种情况，把本该被标记压制的代表档误判成前沿。
/// 2. 保护名单不能只比较代表档 id：菜单栏当前档位可能落在组内非代表档的另一档上（推荐算法选的
///    是更省钱的档位，菜单栏可能仍停在旧选择上），只比较代表档会把整组错误隐藏。
enum ModelRecommendationFrontierFilter {
    /// 折叠行的整组可见性（保留规则命中任一即保留）：
    /// 1. 新推荐档：.recommended 结论——即使代表档被压制也保留整组，推荐了就不能在榜单里消失，
    ///    与旧站长推荐豁免同一语义，只是主语换成新推荐算法的结论。
    /// 2. 菜单栏当前档位落在本组内任意一档（不要求是代表档）。
    /// 3. 旧站长推荐豁免（recommendedIn 非空）落在本组内任意一档，沿用 FrontierFilter 原语义。
    /// 4. 无代表档（.unavailable，无可靠结论）：不知道该不该信任这组数据，不能因为没结论就整体
    ///    隐藏或整体放行——退化为组内任一原始档「未被压制」（没有判定 = 缺价格/耗时，同样不算
    ///    被压制，不隐藏未知数据）。
    /// 5. 其余情况：看代表档是否被压制。
    static func isGroupVisible(
        _ group: ModelRecommendationGroup,
        verdicts: [String: CostVerdict],
        menuBarID: String?
    ) -> Bool {
        if case .recommended = group.outcome { return true }
        if let menuBarID, group.tiers.contains(where: { $0.id == menuBarID }) { return true }
        if group.tiers.contains(where: { !$0.recommendedIn.isEmpty }) { return true }
        guard let model = group.outcome.displayModel else {
            return group.tiers.contains { !(verdicts[$0.id]?.isDominated ?? false) }
        }
        return !(verdicts[model.id]?.isDominated ?? false)
    }

    /// 展开列表的单档可见性：保护名单与整组可见性一致（新推荐档 / 菜单栏档 / 旧站长推荐豁免），
    /// forceShowAll 用于用户点了行内「显示全部档位」时整体旁路，不影响全局 onlyFrontier 开关。
    static func visibleTiers(
        in group: ModelRecommendationGroup,
        verdicts: [String: CostVerdict],
        menuBarID: String?,
        forceShowAll: Bool
    ) -> [ScoredModel] {
        guard !forceShowAll else { return group.tiers }
        return group.tiers.filter {
            FrontierFilter.isVisible(
                $0,
                verdicts: verdicts,
                protectedID: menuBarID,
                additionalProtectedID: group.outcome.recommendedID
            )
        }
    }
}

/// 单行的性价比结论（组内比较，只影响展示）。
struct CostVerdict {
    /// 压制本档的最便宜档位；nil = 组内无人能压制它（性价比前沿）。
    let dominator: ScoredModel?
    /// 达到角标门槛的花费倍数（本档花费 ÷ 压制者花费）；未达门槛时为 nil。
    let badgeMultiple: Double?

    static let frontier = CostVerdict(dominator: nil, badgeMultiple: nil)

    var isDominated: Bool { dominator != nil }

    /// 角标文案：10 倍及以上取整（"×46"），10 倍以内保留一位小数（"×2.6"）——
    /// 取整会把 2.6 夸成 3，量级已经很大时那点小数又没意义。
    var badgeLabel: String? {
        guard let badgeMultiple else { return nil }
        return badgeMultiple >= 10
            ? String(format: "×%.0f", badgeMultiple)
            : String(format: "×%.1f", badgeMultiple)
    }
}

/// 性价比判定：**只在同一分组内比较**（OpenAI 只跟 OpenAI 比，Grok / DeepSeek / Claude Code 各自成组）。
/// 组内若存在另一档「IQ 不更低 + 花费更少 + 耗时不明显更慢」，则本档被压制，参照取其中最便宜的一档。
/// 纯展示层结论：不改榜单排序，也不影响 menuBarBest / 菜单栏标题 / 场景推荐区。
enum CostEfficiency {
    /// 耗时容差：压制者只要"不明显更慢"就算数。没有它，快 1 分钟就能让一个贵一倍、IQ 还更低的
    /// 档位逃脱标记（线上 deepseek-v4-pro high 29 分 vs flash-vision-exp max 30 分就是这种情况）。
    static let timeTolerance = 1.1

    /// 角标门槛：低于 2 倍不标，避免满屏角标；是否在前沿仍由价格配色区分。
    static let badgeMultipleThreshold = 2.0

    /// 一次算完整组（逐行调用会重复做 O(n²) 比较）。
    /// 花费或耗时缺失的档位既不参与压制、也不会被判为被压制，直接不出现在结果里。
    /// 组内再按 metricSource 分桶：Claude Code 分区混了两个站点的数据，任务集不同导致花费差一个量级，
    /// 跨源比会把整批 claudecoderadar 条目误判为被 codexradar 侧的便宜档位压制。
    static func verdicts(in group: [ScoredModel]) -> [String: CostVerdict] {
        var result: [String: CostVerdict] = [:]
        for (_, bucket) in Dictionary(grouping: group, by: \.result.metricSource) {
            result.merge(verdictsWithinSource(bucket)) { current, _ in current }
        }
        return result
    }

    private static func verdictsWithinSource(_ group: [ScoredModel]) -> [String: CostVerdict] {
        let comparable = group.filter { $0.result.cost > 0 && $0.result.timeMinutes > 0 }
        var result: [String: CostVerdict] = [:]
        for model in comparable {
            let cheapestDominator = comparable.filter { other in
                other.id != model.id
                    && other.result.iq >= model.result.iq
                    && other.result.cost < model.result.cost
                    && Double(other.result.timeMinutes) <= Double(model.result.timeMinutes) * timeTolerance
            }.min { $0.result.cost < $1.result.cost }

            guard let cheapestDominator else {
                result[model.id] = .frontier
                continue
            }
            let multiple = model.result.cost / cheapestDominator.result.cost
            result[model.id] = CostVerdict(
                dominator: cheapestDominator,
                badgeMultiple: multiple >= badgeMultipleThreshold ? multiple : nil
            )
        }
        return result
    }
}

/// 按厂商拆分的模型分组（组内保持传入顺序）。
struct VendorGroup: Identifiable {
    let vendor: ModelVendor
    let models: [ScoredModel]

    var id: ModelVendor { vendor }

    /// 概览用去重模型名列表（保留组内首次出现顺序，同名不同档位只算一次）；
    /// OpenAI 沿用现有紧凑命名习惯去掉 "gpt-" 前缀，其余厂商展示原名。
    var overviewModelNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for model in models {
            let raw = model.result.name
            guard seen.insert(raw).inserted else { continue }
            names.append(vendor == .openai ? raw.replacingOccurrences(of: "gpt-", with: "") : raw)
        }
        return names
    }

    /// 厂商概览行文本："5 · 6-astra, 5.6-sol, 5.5 +2"（数量 + 前 3 个实际模型名 + 剩余数）。
    var overviewSummary: String {
        let names = overviewModelNames
        let shownCount = 3
        let shown = names.prefix(shownCount).joined(separator: ", ")
        let remaining = names.count - shownCount
        let suffix = remaining > 0 ? " +\(remaining)" : ""
        return "\(names.count) · \(shown)\(suffix)"
    }
}

/// 单条候选模型的原始记录（来自两个 JSON 数据源）。
struct ModelResult {
    let name: String        // "gpt-5.5" / "opus-4.8"
    let depth: String       // 思考档：medium / high / xhigh / max
    let iq: Double          // 智力基准分（外部 intelligence index，质量主轴）
    let passed: Int         // 通过任务数
    let tasks: Int          // 任务总数（展示用，与综合分归一脱钩）
    let cost: Double        // 美元成本（越低越好）
    let timeMinutes: Int    // 耗时（分钟，越低越好）
    let family: ModelFamily
    let isReference: Bool   // 参考性单日快照（Claude 参考列）
    /// 指标来自哪个站点（默认 codexradar；claudecoderadar 解析处显式传入）。
    var metricSource: MetricSource = .codexRadar

    /// 菜单栏候选只接受 GPT 型号；大小写归一后要求标准 `gpt-` 前缀。
    var isGPTModel: Bool { name.lowercased().hasPrefix("gpt-") }
}

/// 站长推荐条目（radar-insights，identity = model + effort）。
/// 站长推荐接口的综合 IQ 数据点，用于在推荐分组为空时复刻网页端补算逻辑。
struct ComprehensivePoint {
    let model: String
    let effort: String
    let iq: Double

    var id: String { "\(model)/\(effort)" }
}

struct InsightItem {
    let model: String
    let effort: String
    let iq: Double
    let passed: Int?
    let samples: Int?
    let averageCostUSD: Double?
    let averageDurationMinutes: Double?
    let combinedCostIndex: Double?   // 成本指标：越低越省，绝不作为能力排序依据
    let rule: String?
    let trend48h: String?

    var id: String { "\(model)/\(effort)" }
}

/// 站长推荐分组（保持服务端数组顺序）。
struct InsightGroup: Identifiable {
    let key: String
    let title: String
    let rule: String?
    let items: [InsightItem]

    var id: String { key }
}

/// 智力效率数据点（intelligence-efficiency-metrics，identity = model + effort）。
struct EfficiencyPoint {
    let model: String
    let effort: String
    let iq: Double
    let passed: Int?
    let validTasks: Int?
    let averagePriceUSD: Double?
    let averageMinutes: Double?
    let combinedCostIndex: Double?

    var id: String { "\(model)/\(effort)" }
}

/// Codex 列表的数据来源，`rawValue` 即完整度（越大越完整）。
/// 顺序有语义：RadarViewModel 用它拒绝「用更不完整的快照覆盖上一次的好快照」。
enum CodexDataSource: Int, Comparable {
    /// 只剩站长推荐条目可用（efficiency 与 current.json 都不可用），通常只有两三条，最小兜底。
    case recommendationsOnly = 0
    /// current.json 本地估算的完整候选列表（UI 标注「本地估算」）。
    case localEstimate = 1
    /// intelligence-efficiency 网站权威指标，覆盖最全。
    case website = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 带综合分的模型（综合分由 RadarParser 计算；网站主源模式下 score 仅为 IQ 视觉比例）。
struct ScoredModel: Identifiable {
    let result: ModelResult
    let score: Double
    var recommendedIn: [String] = []   // 被哪些站长推荐分组选中（分组 title，服务端顺序）
    var costIndex: Double? = nil       // combined_cost_index（越低越省，仅展示）

    var id: String { "\(result.name)/\(result.depth)" }

    // 展示派生 —————————————————————————————————————————————

    /// 综合分保留两位小数："0.93"。
    var scoreLabel: String { String(format: "%.2f", score) }

    /// 进度条填充比例 0...1。
    var barFraction: Double { min(max(score, 0), 1) }

    /// 智力基准分（透传 result）。
    var iq: Double { result.iq }

    /// 厂商分组（按模型名前缀派生，透传 result）。
    var vendor: ModelVendor { ModelVendor.from(modelName: result.name) }

    /// IQ 数值文本（一位小数）："87.5"。
    var iqLabel: String { String(format: "%.1f", result.iq) }

    /// "7/12"。
    var passLabel: String { "\(result.passed)/\(result.tasks)" }

    /// "$23.9"（保留一位小数）。
    var costLabel: String { String(format: "$%.1f", result.cost) }

    /// "1h25m" / "28m"。
    var timeLabel: String {
        let h = result.timeMinutes / 60
        let m = result.timeMinutes % 60
        if h > 0 { return m > 0 ? "\(h)h\(m)m" : "\(h)h" }
        return "\(m)m"
    }

    /// 有效价格标签（非正数不伪装为 $0.0，逐字段省略）。
    var validCostLabel: String? { result.cost > 0 ? costLabel : nil }

    /// 有效耗时标签（非正数不伪装为 0m，逐字段省略）。
    var validTimeLabel: String? { result.timeMinutes > 0 ? timeLabel : nil }

    /// 成本指数紧凑格式（3 位有效数字，兼顾 0.0002～100 量级；缺失/非正数省略）。
    var costIndexLabel: String? {
        guard let v = costIndex, v > 0 else { return nil }
        return String(format: "%.3g", v)
    }

    /// 紧凑指标行："$23.9 · 1h25m · 指数0.27"；缺失字段逐个省略，全缺失返回 nil。
    var metricsLabel: String? {
        let parts = [validCostLabel, validTimeLabel, costIndexLabel.map { "指数\($0)" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 菜单栏紧凑名："5.5·medium"（去掉 gpt- 前缀）。
    var compactName: String {
        let base = result.name.replacingOccurrences(of: "gpt-", with: "")
        return "\(base)·\(result.depth)"
    }
}

/// 一次拉取后的视图快照。
struct RadarSnapshot {
    let all: [ScoredModel]   // 全部候选（已按展示顺序排列：Codex 推荐优先，Claude 按源 IQ 降序）
    let updatedAt: Date      // 多源时间戳：insights/efficiency source_updated_at → current.json → 当前时间
    var claudeStatus: ClaudeStatus = .ok   // Claude 参考列是否抓取成功
    var insights: [InsightGroup] = []      // 站长推荐分组（服务端顺序；本地估算回退时为空）
    var codexSource: CodexDataSource = .localEstimate   // Codex 数据来自网站权威源还是本地估算
    var localBestID: String? = nil   // current.json 本地冠军 identity（efficiency-only 时菜单栏独立回退用）

    /// Codex 组（保持解析层给定的展示顺序）。
    var codexGroup: [ScoredModel] { all.filter { $0.result.family == .codex } }

    /// Claude Code 组（保持解析层给定的展示顺序）。
    var claudeGroup: [ScoredModel] { all.filter { $0.result.family == .claude } }

    /// Codex 弹窗展示专用投影：剔除 Anthropic/Claude 命名竞品条目（正常路径下解析层已把它们搬进
    /// Claude Code 分区，这里是直接构造快照时的兜底）→ 展示层质量过滤
    /// （见 CodexDisplayQuality）→ Terra/Luna 单档收敛（见 CodexSingleTierCondense）；
    /// 不影响 all / codexGroup / menuBarBest 等权威数据与菜单栏逻辑。
    private var codexDisplayGroup: [ScoredModel] {
        let withoutAnthropic = codexGroup.filter { !ModelVendor.isAnthropicCompetitor(modelName: $0.result.name) }
        let qualityFiltered = CodexDisplayQuality.filtered(withoutAnthropic, menuBarBestID: menuBarBest?.id)
        return CodexSingleTierCondense.filtered(qualityFiltered, menuBarBestID: menuBarBest?.id)
    }

    /// Codex 组按厂商拆分（厂商组顺序固定为 ModelVendor.displayWhitelist，跳过空组；
    /// 组内保持 codexGroup 原有顺序；非白名单厂商整体隐藏，不落入"其他"）；
    /// DeepSeek 组额外应用展示层限额（见 DeepSeekDisplayLimit）。
    var codexGroupsByVendor: [VendorGroup] {
        let grouped = Dictionary(grouping: codexDisplayGroup, by: \.vendor)
        return ModelVendor.displayWhitelist.compactMap { vendor in
            guard let models = grouped[vendor], !models.isEmpty else { return nil }
            let displayed = vendor == .deepseek ? DeepSeekDisplayLimit.limited(models) : models
            return VendorGroup(vendor: vendor, models: displayed)
        }
    }

    /// 当前快照里确实有内容的分区，顺序即 BoardSection.displayOrder。
    /// 筛选行只列出这些分区，榜单也只渲染这些分区——两者共用同一份来源，不会出现"筛了个空组"。
    /// Claude 抓取失败时仍算有内容：该组会显示「数据提取失败」提示行。
    var availableSections: [BoardSection] {
        let vendors = Set(codexGroupsByVendor.map(\.vendor))
        return BoardSection.displayOrder.filter { section in
            switch section {
            case .vendor(let vendor): return vendors.contains(vendor)
            case .claude:             return !claudeDisplayGroup.isEmpty || claudeStatus == .unavailable
            }
        }
    }

    /// Claude Code 弹窗展示专用投影：剔除 fable-* 系列（内部代号，不作为 Claude 竞品展示）。
    /// 该组数据完全来自 codexradar 的 claude-* 竞品条目（RadarService 不再单独请求 claudecoderadar.com）；
    /// 不影响 all / claudeGroup 等权威数据。
    var claudeDisplayGroup: [ScoredModel] {
        claudeGroup.filter { !$0.result.name.lowercased().hasPrefix("fable-") }
    }

    /// 「模型推荐」榜单的分组来源：始终用**全量**数据（codexGroup 按厂商过滤 / claudeDisplayGroup），
    /// 不经过 CodexDisplayQuality / CodexSingleTierCondense / DeepSeekDisplayLimit / CostEfficiency+
    /// FrontierFilter 等展示层过滤——那些过滤只决定「完整榜单」怎么显示，绝不能改变推荐判定依据的候选池
    /// （即前沿过滤开关切换、厂商内质量过滤都不改变某个模型该推荐哪一档）。
    /// claudeDisplayGroup 剔除 fable-* 内部代号例外：那不是质量过滤，是「这压根不是外部竞品」的身份过滤，
    /// 与 codexGroup 已经不含 claude-* 竞品条目（解析层已并入 Claude 分区）同一性质。
    func recommendationGroups(for section: BoardSection) -> [ModelRecommendationGroup] {
        let groups: [ModelRecommendationGroup]
        switch section {
        case .vendor(let vendor):
            let pool = codexGroup.filter {
                !ModelVendor.isAnthropicCompetitor(modelName: $0.result.name)
                    && ModelVendor.from(modelName: $0.result.name) == vendor
            }
            groups = pool.groupedForRecommendation()
        case .claude:
            groups = claudeDisplayGroup.groupedForRecommendation()
        }
        // codexSource != .website：Codex 侧这一轮拿到的是 current.json 本地估算公式分
        // （.localEstimate）或只剩站长推荐条目（.recommendationsOnly），都不是网站权威的真实
        // 工程 IQ。凡是 metricSource == .codexRadar 的组（含并入 Claude 分区的 Anthropic 竞品
        // 条目——它们与 codexSource 同一次抓取、同样会跟着降级）一律标记不可靠；claudeRadar
        // 组不受影响，它由 claudeStatus 独立管控。可靠性标记不改变组的数量/身份，因此在
        // DeepSeek 展示层限额之前或之后做都一样，这里先做以保持与旧代码顺序一致。
        let reliabilityAdjusted: [ModelRecommendationGroup]
        if codexSource != .website {
            reliabilityAdjusted = groups.map { $0.metricSource == .codexRadar ? $0.markedUnreliableCodexSource() : $0 }
        } else {
            reliabilityAdjusted = groups
        }
        // DeepSeek 展示层限额（见 DeepSeekDisplayLimit）：只砍这里返回的展示组数，
        // 不影响上面已经用全量档位算完的推荐结论——与「完整榜单」的 DeepSeekDisplayLimit.limited
        // 保持同样的条数，避免「模型推荐」比「完整榜单」多出好几条的错觉。
        if case .vendor(.deepseek) = section {
            return DeepSeekDisplayLimit.limitedGroups(reliabilityAdjusted)
        }
        return reliabilityAdjusted
    }

    /// 菜单栏只推荐 GPT 型号：daily_development 首个可匹配 GPT → 本地 GPT 冠军 → 第一个 GPT。
    var menuBarBest: ScoredModel? {
        let gptCandidates = codexGroup.filter { $0.result.isGPTModel }
        if let daily = insights.first(where: { $0.key == "daily_development" }),
           let matched = daily.items.lazy.compactMap({ pick in
               gptCandidates.first(where: {
                   $0.result.name == pick.model && $0.result.depth == pick.effort
               })
           }).first {
            return matched
        }
        if let localBestID,
           let matched = gptCandidates.first(where: { $0.id == localBestID }) {
            return matched
        }
        return gptCandidates.first
    }

    /// 绝对检测时间戳："2026-06-25 14:28"（本地时区）。
    var checkedAtLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: updatedAt)
    }
}

// MARK: - 模型推荐（同模型同源比较，真实工程 IQ + 均价，纯函数）
//
// 与旧的「综合分」（RadarParser.score，混了通过数/耗时）、insights 场景推荐（daily_development /
// hard_problems，按接口 rule 各自的排序口径）都无关：模型推荐只认 ScoredModel.result.iq（网站给出的
// 真实工程有效 IQ）与 result.cost（均价），在同一模型 + 同一 metricSource 的档位之间比较，
// 避免混用不同口径互相打架。

/// 思考档展开顺序：low → medium → high → xhigh → max → ultra 依次在前；其余未知档按字典序跟在后面，
/// 未知档之间也保持稳定、可预期的顺序（不依赖数据源给出的原始顺序）。
enum DepthTier {
    private static let known = ["low", "medium", "high", "xhigh", "max", "ultra"]

    /// 排序键：已知档 → (下标, "")；未知档 → (known.count, 小写档名)。用于 sorted(by:) 的 `<` 比较。
    static func sortKey(_ depth: String) -> (Int, String) {
        let normalized = depth.lowercased()
        if let index = known.firstIndex(of: normalized) { return (index, "") }
        return (known.count, normalized)
    }
}

/// 单个「模型 + 指标来源」分组的推荐结论。
enum ModelRecommendationOutcome {
    /// 组内没有任何有效（有限、非 NaN、> 0）真实工程 IQ 成绩——没有可推荐的依据。
    /// 达到 95% 门槛的档位里没有一个有效正数价格——同样不能推荐，价格缺失不能伪装成 $0。
    enum Reason {
        case noValidScore
        case noValidPrice
        /// codexRadar 指标来自 codexSource == .localEstimate（current.json 本地估算公式）或
        /// .recommendationsOnly（只剩站长推荐条目，无独立效率测量）时触发：这两种模式下的
        /// IQ 不是网站权威的真实工程测量，不能冒充「比较后选出的」工程推荐（见
        /// RadarSnapshot.recommendationGroups）。claudeRadar 指标不受此约束——它由
        /// claudeStatus 独立管控，与 Codex 侧的抓取状态无关。
        case unreliableCodexSource
    }

    case recommended(ScoredModel, maxIQ: Double, thresholdIQ: Double)
    /// 组内只有一个有效成绩的档位：没有第二档可比，不冒充「比较后选出的」可靠推荐。
    case singleComparableTier(ScoredModel)
    case unavailable(Reason)

    /// 折叠行展示用的档位（推荐档，或唯一可比较档；无可靠数据时为 nil）。
    var displayModel: ScoredModel? {
        switch self {
        case .recommended(let model, _, _):    return model
        case .singleComparableTier(let model): return model
        case .unavailable:                     return nil
        }
    }

    /// 推荐档的 identity（仅 .recommended 时非 nil），供展开列表高亮对应行。
    var recommendedID: String? {
        if case .recommended(let model, _, _) = self { return model.id }
        return nil
    }
}

/// 模型推荐核心纯函数：给定同一模型 + 同一 metricSource 的全部档位，挑出「工程能力不明显掉档、
/// 价格最低」的那一档。调用方传入的顺序即平局仲裁顺序（先出现者赢），不在此处重新排序。
///
/// 规则：
/// 1. 有效成绩 = result.iq 有限且 > 0。少于两档有效成绩时构不成「比较」（见 singleComparableTier /
///    unavailable(.noValidScore)）。
/// 2. 门槛 = 全部有效成绩档位（**含没有价格的档位**）中的最高 IQ × 95%。不能先剔除缺价格的档位再取
///    最高分——那会让真正的最高分因为缺价格被排除在外、门槛虚低，把本该落选的低 IQ 档位错误纳入候选。
/// 3. 候选 = IQ ≥ 门槛 且 价格有限、为正数的档位。
/// 4. 候选中取价格最低者；同价平局取调用方给定顺序中先出现的一档。
enum ModelRecommendation {
    static let iqRetentionRatio = 0.95

    static func evaluate(_ tiers: [ScoredModel]) -> ModelRecommendationOutcome {
        let validScore = tiers.filter { $0.result.iq.isFinite && $0.result.iq > 0 }
        guard !validScore.isEmpty else { return .unavailable(.noValidScore) }
        guard validScore.count >= 2 else { return .singleComparableTier(validScore[0]) }

        let maxIQ = validScore.map(\.result.iq).max()!
        let threshold = maxIQ * iqRetentionRatio
        let candidates = validScore.filter {
            $0.result.iq >= threshold && $0.result.cost.isFinite && $0.result.cost > 0
        }
        guard !candidates.isEmpty else { return .unavailable(.noValidPrice) }

        var best = candidates[0]
        for candidate in candidates.dropFirst() where candidate.result.cost < best.result.cost {
            best = candidate
        }
        return .recommended(best, maxIQ: maxIQ, thresholdIQ: threshold)
    }
}

/// 「模型推荐」榜单一行：同一模型 + 同一指标来源的全部档位，折叠展示推荐结论，
/// 展开显示该模型全部档位（按 DepthTier 稳定排序，与推荐判定用的原始顺序互不影响）。
struct ModelRecommendationGroup: Identifiable {
    let modelName: String
    let metricSource: MetricSource
    let tiers: [ScoredModel]   // 展开顺序：DepthTier 排序
    var outcome: ModelRecommendationOutcome   // 可由 RadarSnapshot.recommendationGroups 降级为不可靠

    var id: String {
        let sourceTag = metricSource == .claudeRadar ? "claudeRadar" : "codexRadar"
        return "\(modelName)#\(sourceTag)"
    }

    /// 折叠行是否可展开：只看实际档位数，不看推荐结论（outcome）。多档但只有一条有效 IQ 的组
    /// （outcome 仍是 .singleComparableTier）照样可展开——展开列表展示的是全部原始档位，
    /// 与"是否参与过推荐比较"无关；真正的单档（tiers.count <= 1）才没有东西可展开。
    var isExpandable: Bool { tiers.count > 1 }

    init(modelName: String, metricSource: MetricSource, tiers: [ScoredModel]) {
        self.modelName = modelName
        self.metricSource = metricSource
        // 推荐判定用调用方传入的原始顺序（见 ModelRecommendation.evaluate 的平局规则），
        // 展开列表另外按思考档排序展示，两者互不干扰。
        self.outcome = ModelRecommendation.evaluate(tiers)
        self.tiers = tiers.sorted { DepthTier.sortKey($0.result.depth) < DepthTier.sortKey($1.result.depth) }
    }

    /// 展开列表（真实档位数据）不受影响，只是折叠行不再声称「推荐」/「仅一档」结论——
    /// 那两种结论都暗示"比较过、可信"，而本地估算/站长推荐综合分撑不起这个暗示。
    func markedUnreliableCodexSource() -> ModelRecommendationGroup {
        var copy = self
        copy.outcome = .unavailable(.unreliableCodexSource)
        return copy
    }
}

extension Array where Element == ScoredModel {
    /// 按「模型名 + 指标来源」分组，不跨源合并（同名不同站点口径不可比，见 MetricSource）；
    /// 分组顺序与组内档位顺序都保持首次出现的原始顺序。
    func groupedForRecommendation() -> [ModelRecommendationGroup] {
        var order: [String] = []
        var names: [String: String] = [:]
        var sources: [String: MetricSource] = [:]
        var tiersByKey: [String: [ScoredModel]] = [:]

        for model in self {
            let key = "\(model.result.name)#\(model.result.metricSource)"
            if tiersByKey[key] == nil {
                order.append(key)
                names[key] = model.result.name
                sources[key] = model.result.metricSource
            }
            tiersByKey[key, default: []].append(model)
        }

        return order.compactMap { key in
            guard let name = names[key], let source = sources[key], let tiers = tiersByKey[key] else { return nil }
            return ModelRecommendationGroup(modelName: name, metricSource: source, tiers: tiers)
        }
    }
}
