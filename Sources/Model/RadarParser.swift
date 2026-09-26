// current.json → Codex（主源）+ 综合分 + 排序分组 + 时间戳。
// claude-code-radar.json → Claude 的解析函数（parseClaude/buildClaudeByIQ）仍保留，
// 但 RadarService 已不再请求该源；线上 Claude Code 分区改由 codexradar 的 claude-* 竞品条目
// 通过 mergeAnthropicIntoClaude 并入。
//
// Codex 评分数据来自 current.json 的 model_iq.latest / model_iq.comparisons；
// 时间戳来自 current.json 的 quota_radar.updated_at。综合分按 family 各自归一化。
import Foundation

enum RadarParserError: LocalizedError {
    case empty
    case codexUnavailable
    case claudeUnavailable
    case insightsUnavailable
    case efficiencyUnavailable

    var errorDescription: String? {
        switch self {
        case .empty: return "无可用模型"
        case .codexUnavailable: return "current.json 无可用 Codex 数据"
        case .claudeUnavailable: return "claude-code-radar.json 无可用 Claude 数据"
        case .insightsUnavailable: return "radar-insights 无可用推荐数据"
        case .efficiencyUnavailable: return "intelligence-efficiency-metrics 无可用数据"
        }
    }
}

enum RadarParser {

    // MARK: - 综合分

    /// score = (iq/maxIq)^0.42 · (min(passed,8)/8)^0.13 · (minCost/cost)^0.30 · (minTime/time)^0.15。
    /// IQ 为质量主轴；通过数降为低权重辅助校验项，封顶 8 避免 passed > 8 把综合分推过 1（与 barFraction 的 clamp 语义保持一致）。
    static func score(iq: Double, passed: Int, cost: Double, timeMinutes: Int, maxIq: Double, minCost: Double, minTime: Int) -> Double {
        let iqNorm = pow(iq / maxIq, 0.42)
        let q = pow(Double(min(passed, 8)) / 8.0, 0.13)
        let costNorm = pow(minCost / cost, 0.30)
        let speedNorm = pow(Double(minTime) / Double(timeMinutes), 0.15)
        return iqNorm * q * costNorm * speedNorm
    }

    /// 全部候选算综合分并按降序排序。归一化按 family 分组进行：每组各自取 maxIq/minCost/minTime，
    /// 组间分数不可横比（某组为空时另一组照常评分）。极值只在有效正数候选里取，避免无效数据带来 inf/NaN。
    static func scoreAndSort(_ models: [ModelResult]) throws -> [ScoredModel] {
        let valid = models.filter { $0.iq > 0 && $0.cost > 0 && $0.timeMinutes > 0 }
        guard !valid.isEmpty else { throw RadarParserError.empty }
        var scored: [ScoredModel] = []
        for (_, group) in Dictionary(grouping: valid, by: \.family) {
            let maxIq = group.map(\.iq).max() ?? 1
            let minCost = group.map(\.cost).min() ?? 1
            let minTime = group.map(\.timeMinutes).min() ?? 1
            scored += group.map { ScoredModel(result: $0, score: score(
                iq: $0.iq, passed: $0.passed, cost: $0.cost, timeMinutes: $0.timeMinutes,
                maxIq: maxIq, minCost: minCost, minTime: minTime)) }
        }
        return scored.sorted { $0.score > $1.score }
    }

    // MARK: - radar-insights → 站长推荐（权威源）

    /// 解析 https://codexradar.com/api/radar-insights：schema 必须为 1，
    /// recommendations 保持服务端数组顺序；空分组/坏条目防御性过滤，全空则不可用。
    static func parseInsights(json data: Data) throws -> [InsightGroup] {
        guard let resp = try? JSONDecoder().decode(InsightsResponse.self, from: data),
              resp.schema == 1 else {
            throw RadarParserError.insightsUnavailable
        }
        let groups = resp.recommendations.map { dto in
            InsightGroup(
                key: dto.key, title: dto.title, rule: dto.rule,
                items: dto.items.filter { $0.iq > 0 }.map { item in
                    InsightItem(
                        model: item.model, effort: item.effort, iq: item.iq,
                        passed: item.passed, samples: item.samples,
                        averageCostUSD: item.averageCostUSD,
                        averageDurationMinutes: item.averageDurationMinutes,
                        combinedCostIndex: item.combinedCostIndex,
                        rule: item.rule, trend48h: item.trend48h
                    )
                }
            )
        }.filter { !$0.items.isEmpty }
        guard !groups.isEmpty else { throw RadarParserError.insightsUnavailable }
        return groups
    }

    /// 解析 radar-insights 的 source_updated_at → Date（schema 不匹配或不可用返回 nil，不采信坏响应的时间戳）。
    static func parseInsightsTimestamp(json data: Data) -> Date? {
        guard let resp = try? JSONDecoder().decode(InsightsResponse.self, from: data),
              resp.schema == 1,
              let iso = resp.sourceUpdatedAt else { return nil }
        return parseISO(iso)
    }

    /// 解析 radar-insights 的 comprehensive_points，供空推荐分组的网页同款补算使用。
    static func parseComprehensivePoints(json data: Data) -> [ComprehensivePoint] {
        guard let resp = try? JSONDecoder().decode(InsightsResponse.self, from: data),
              resp.schema == 1 else { return [] }
        return (resp.comprehensivePoints ?? [])
            .filter { $0.iq > 0 }
            .map { ComprehensivePoint(model: $0.model, effort: $0.effort, iq: $0.iq) }
    }

    /// 复刻网页端补算：推荐分组为空时，用同一响应的 comprehensive_points + 实时效率指标补出候选。
    /// 各分组的入选条件与排序规则不同（由接口 rule 字段给出），公共部分（identity 归一、去重、
    /// 补足 2 条、写回/插入分组）收敛在这里。候选只取 GPT 型号：菜单栏与 Codex 展示都只认 GPT，
    /// 且线上 comprehensive_points 目前也只有 gpt-*，与网页结果一致。
    private static func supplement(
        _ insights: [InsightGroup],
        groupKey: String,
        title: String,
        insertAfterKey: String?,
        comprehensive: [ComprehensivePoint],
        efficiency: [EfficiencyPoint],
        isEligible: (ComprehensivePoint, EfficiencyPoint) -> Bool,
        areInIncreasingOrder: (InsightItem, InsightItem) -> Bool
    ) -> [InsightGroup] {
        let normalizedID: (String, String) -> String = { model, effort in
            "\(model.lowercased())/\(effort.lowercased())"
        }
        let matches: (String, String) -> Bool = { key, target in
            key.replacingOccurrences(of: "_", with: "-") == target.replacingOccurrences(of: "_", with: "-")
        }
        let targetIndex = insights.firstIndex { matches($0.key, groupKey) }
        let existingItems = targetIndex.map { insights[$0].items } ?? []
        var items = existingItems.filter { $0.model.lowercased().hasPrefix("gpt-") }
        var seen = Set(items.map { normalizedID($0.model, $0.effort) })

        let efficiencyByID = Dictionary(
            efficiency.map { (normalizedID($0.model, $0.effort), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let candidates = comprehensive.compactMap { point -> InsightItem? in
            let id = normalizedID(point.model, point.effort)
            guard point.model.lowercased().hasPrefix("gpt-"),
                  !seen.contains(id),
                  let metric = efficiencyByID[id],
                  isEligible(point, metric) else { return nil }
            return InsightItem(
                model: point.model,
                effort: point.effort,
                iq: point.iq,
                passed: metric.passed,
                samples: metric.validTasks,
                averageCostUSD: metric.averagePriceUSD,
                averageDurationMinutes: metric.averageMinutes,
                combinedCostIndex: metric.combinedCostIndex,
                rule: nil,
                trend48h: nil
            )
        }
        .sorted(by: areInIncreasingOrder)

        for candidate in candidates where items.count < 2 {
            let id = normalizedID(candidate.model, candidate.effort)
            guard seen.insert(id).inserted else { continue }
            items.append(candidate)
        }
        guard !items.isEmpty else { return insights }

        let original = targetIndex.map { insights[$0] }
        let group = InsightGroup(
            key: original?.key ?? groupKey,
            title: original?.title ?? title,
            rule: original?.rule,
            items: Array(items.prefix(2))
        )
        if let targetIndex {
            var result = insights
            result[targetIndex] = group
            return result
        }
        // 分组整个缺失（服务端返回空组、被 parseInsights 过滤掉）：按服务端固有顺序插回去。
        var result = insights
        let anchor = insertAfterKey.flatMap { key in result.firstIndex { matches($0.key, key) } }
        result.insert(group, at: anchor.map { $0 + 1 } ?? 0)
        return result
    }

    /// 日常开发补算 —— 接口 rule：原始 IQ ≥90，在同一候选池中以平均耗时与综合成本为基准，去重后取 2 个。
    /// 排序优先平均耗时，其次综合成本指数，最后综合 IQ；因此当前数据会得到 Sol medium。
    static func supplementDailyDevelopment(
        insights: [InsightGroup],
        comprehensive: [ComprehensivePoint],
        efficiency: [EfficiencyPoint]
    ) -> [InsightGroup] {
        supplement(
            insights,
            groupKey: "daily_development",
            title: "日常开发",
            insertAfterKey: nil,
            comprehensive: comprehensive,
            efficiency: efficiency,
            isEligible: { point, metric in point.iq >= 90 && metric.averageMinutes != nil },
            areInIncreasingOrder: { left, right in
                let leftMinutes = left.averageDurationMinutes ?? .infinity
                let rightMinutes = right.averageDurationMinutes ?? .infinity
                if leftMinutes != rightMinutes { return leftMinutes < rightMinutes }
                let leftCost = left.combinedCostIndex ?? .infinity
                let rightCost = right.combinedCostIndex ?? .infinity
                if leftCost != rightCost { return leftCost < rightCost }
                return left.iq > right.iq
            }
        )
    }

    /// 难题攻坚补算 —— 接口 rule：所有有实测数据的档位中按 IQ 从高到低取 2 个，
    /// IQ 相同时按模型顺序与综合成本排序。不设 IQ 门槛，只要求该档位有实测指标。
    /// 服务端该组常年返回空数组（会被 parseInsights 过滤掉），补算后插回日常开发之后，保持服务端固有顺序。
    static func supplementHardProblems(
        insights: [InsightGroup],
        comprehensive: [ComprehensivePoint],
        efficiency: [EfficiencyPoint]
    ) -> [InsightGroup] {
        supplement(
            insights,
            groupKey: "hard_problems",
            title: "难题攻坚",
            insertAfterKey: "daily_development",
            comprehensive: comprehensive,
            efficiency: efficiency,
            isEligible: { _, _ in true },
            areInIncreasingOrder: { left, right in
                if left.iq != right.iq { return left.iq > right.iq }
                if left.model != right.model { return left.model < right.model }
                return (left.combinedCostIndex ?? .infinity) < (right.combinedCostIndex ?? .infinity)
            }
        )
    }

    // MARK: - intelligence-efficiency-metrics → 智力效率（权威指标源）

    /// 解析 https://codexradar.com/api/intelligence-efficiency-metrics：兼容 schema 2/3，
    /// points identity = model + effort；无效正数（iq ≤ 0）防御性过滤，全空则不可用。
    static func parseEfficiency(json data: Data) throws -> [EfficiencyPoint] {
        guard let resp = try? JSONDecoder().decode(EfficiencyResponse.self, from: data),
              (resp.schema == 2 || resp.schema == 3) else {
            throw RadarParserError.efficiencyUnavailable
        }
        let points = resp.points.filter { $0.iq > 0 }.map { p in
            EfficiencyPoint(
                model: p.model, effort: p.effort, iq: p.iq,
                passed: p.passed, validTasks: p.validTasks,
                averagePriceUSD: p.averagePriceUSD,
                averageMinutes: p.averageMinutes,
                combinedCostIndex: p.combinedCostIndex
            )
        }
        guard !points.isEmpty else { throw RadarParserError.efficiencyUnavailable }
        return points
    }

    /// 解析 intelligence-efficiency-metrics 的 source_updated_at → Date（schema 不匹配或不可用返回 nil，不采信坏响应的时间戳）。
    static func parseEfficiencyTimestamp(json data: Data) -> Date? {
        guard let resp = try? JSONDecoder().decode(EfficiencyResponse.self, from: data),
              (resp.schema == 2 || resp.schema == 3),
              let iso = resp.sourceUpdatedAt else { return nil }
        return parseISO(iso)
    }

    // MARK: - 网站权威指标 → Codex 展示列表

    /// 用 efficiency points 构建 Codex 列表（网站 IQ/价格/时长/成本指数为准）：
    /// 一律按 IQ 降序，推荐项不再置顶——推荐结论已由弹窗顶部的场景推荐区承担（见 ScenarioPicksView），
    /// 榜单只负责"按能力排序"这一件事；命中推荐的条目仍写入 recommendedIn，由行内 chip 标出。
    /// score 只是 IQ 视觉比例（iq/maxIq），不是能力总分，绝不用 combined_cost_index 升序当全局排序。
    static func buildCodexFromEfficiency(points: [EfficiencyPoint], insights: [InsightGroup]) -> [ScoredModel] {
        let maxIq = points.map(\.iq).max() ?? 1

        // identity(model+effort) → 被哪些推荐分组选中（分组标题，保持服务端顺序）
        var recommendedIn: [String: [String]] = [:]
        for group in insights {
            for item in group.items {
                recommendedIn[item.id, default: []].append(group.title)
            }
        }

        func scored(_ p: EfficiencyPoint) -> ScoredModel {
            ScoredModel(
                result: ModelResult(
                    name: p.model, depth: p.effort,
                    iq: p.iq,
                    passed: p.passed ?? 0, tasks: p.validTasks ?? 0,
                    cost: p.averagePriceUSD ?? 0,
                    timeMinutes: Int((p.averageMinutes ?? 0).rounded()),
                    family: .codex,
                    isReference: false
                ),
                score: maxIq > 0 ? p.iq / maxIq : 0,
                recommendedIn: recommendedIn[p.id] ?? [],
                costIndex: p.combinedCostIndex
            )
        }

        return points.sorted { $0.iq > $1.iq }.map(scored)
    }

    /// insights-only 降级（efficiency 失败）：从推荐条目自身指标构建去重 Codex 列表，
    /// 保持分组/条目首次出现顺序，合并同一 identity 的 recommendedIn。仍为网站权威数据。
    static func buildCodexFromInsights(insights: [InsightGroup]) -> [ScoredModel] {
        var order: [String] = []
        var firstItem: [String: InsightItem] = [:]
        var recommendedIn: [String: [String]] = [:]
        for group in insights {
            for item in group.items {
                if firstItem[item.id] == nil {
                    order.append(item.id)
                    firstItem[item.id] = item
                }
                recommendedIn[item.id, default: []].append(group.title)
            }
        }
        let maxIq = firstItem.values.map(\.iq).max() ?? 1
        return order.compactMap { id -> ScoredModel? in
            guard let item = firstItem[id] else { return nil }
            return ScoredModel(
                result: ModelResult(
                    name: item.model, depth: item.effort,
                    iq: item.iq,
                    passed: item.passed ?? 0, tasks: item.samples ?? 0,
                    cost: item.averageCostUSD ?? 0,
                    timeMinutes: Int((item.averageDurationMinutes ?? 0).rounded()),
                    family: .codex,
                    isReference: false
                ),
                score: maxIq > 0 ? item.iq / maxIq : 0,
                recommendedIn: recommendedIn[id] ?? [],
                costIndex: item.combinedCostIndex
            )
        }
    }

    /// 把站长推荐信息合并到一份已有的 Codex 列表上（identity = model + effort）：
    /// 命中的条目写入 recommendedIn（分组 title，服务端顺序），顺序完全保持传入不变
    /// （榜单排序由调用方决定，推荐结论交给顶部的场景推荐区）。
    /// 供 efficiency 不可用、列表回退到 current.json 本地估算时仍能标出站长推荐。
    static func applyRecommendations(_ models: [ScoredModel], insights: [InsightGroup]) -> [ScoredModel] {
        var recommendedIn: [String: [String]] = [:]
        for group in insights {
            for item in group.items {
                recommendedIn[item.id, default: []].append(group.title)
            }
        }
        guard !recommendedIn.isEmpty else { return models }

        return models.map { model in
            var copy = model
            copy.recommendedIn = recommendedIn[model.id] ?? []
            return copy
        }
    }

    /// Claude 参考列表：按源 IQ 降序，score 只是 IQ 视觉比例（iq/maxIq），非权威推荐。
    static func buildClaudeByIQ(_ models: [ModelResult]) -> [ScoredModel] {
        let valid = models.filter { $0.iq > 0 }
        let maxIq = valid.map(\.iq).max() ?? 1
        return valid.sorted { $0.iq > $1.iq }.map {
            ScoredModel(result: $0, score: $0.iq / maxIq)
        }
    }

    // MARK: - Anthropic 竞品条目 → 并入 Claude Code 分区

    /// codexradar 的 `claude-*` 竞品条目并入 Claude Code 分区，不再整体隐藏（此前它们既不进
    /// Codex 榜单也不进 Claude 组，导致 codexradar 独有的 opus-5 完全看不到）。
    ///
    /// 冲突规则：**claudecoderadar 为主源**，同一 `模型名 + 档位` 已有雷达数据时丢弃 codexradar 版本
    /// （雷达侧样本量 7~10 任务，竞品列常只有 1~5 任务）；codexradar 只补雷达没有的档位。
    /// 名字去掉 `claude-` 前缀与雷达侧对齐（`claude-opus-5` → `opus-5`），否则同一模型会拆成两行。
    /// 合并后按 IQ 降序重排、按合并后的 maxIq 重算 score（进度条比例）。
    /// RadarService 目前固定传入空的 `claude` 列表（不再请求 claudecoderadar.com），
    /// 上述冲突规则暂不会触发，`claude-*` 竞品条目直接全部落入 Claude Code 分区。
    ///
    /// 返回值：搬空 `claude-*` 之后的 Codex 列表 + 合并后的 Claude 列表。
    static func mergeAnthropicIntoClaude(
        codex: [ScoredModel],
        claude: [ScoredModel]
    ) -> (codex: [ScoredModel], claude: [ScoredModel]) {
        let moved = codex.filter { ModelVendor.isAnthropicCompetitor(modelName: $0.result.name) }
        guard !moved.isEmpty else { return (codex, claude) }
        let remainingCodex = codex.filter { !ModelVendor.isAnthropicCompetitor(modelName: $0.result.name) }

        let existingIDs = Set(claude.map(\.id))
        let supplements: [ScoredModel] = moved.compactMap { model in
            guard model.result.iq > 0 else { return nil }
            let old = model.result
            let renamed = ModelResult(
                name: String(old.name.dropFirst("claude-".count)),
                depth: old.depth,
                iq: old.iq,
                passed: old.passed, tasks: old.tasks,
                cost: old.cost, timeMinutes: old.timeMinutes,
                family: .claude,
                isReference: old.isReference,
                metricSource: .codexRadar
            )
            let supplement = ScoredModel(
                result: renamed, score: model.score,
                recommendedIn: model.recommendedIn, costIndex: model.costIndex
            )
            guard !existingIDs.contains(supplement.id) else { return nil }
            return supplement
        }
        guard !supplements.isEmpty else { return (remainingCodex, claude) }

        let mergedClaude = (claude + supplements).sorted { $0.result.iq > $1.result.iq }
        let maxIq = mergedClaude.map(\.result.iq).max() ?? 1
        return (remainingCodex, mergedClaude.map { model in
            ScoredModel(
                result: model.result,
                score: maxIq > 0 ? model.result.iq / maxIq : 0,
                recommendedIn: model.recommendedIn,
                costIndex: model.costIndex
            )
        })
    }

    // MARK: - current.json → Codex（主源）

    /// 从 current.json 构建 Codex 候选：model_iq.latest（主列）+ model_iq.comparisons 的每个值各一条。
    /// comparisons 动态遍历，不写死 key；耗时统一取 wall_seconds（并行墙钟）。
    static func parseCodex(json data: Data) throws -> [ModelResult] {
        guard let resp = try? JSONDecoder().decode(CurrentResponse.self, from: data),
              let latest = resp.modelIQ.latest else {
            throw RadarParserError.codexUnavailable
        }
        var configs: [ModelIQConfig] = [latest]
        if let comparisons = resp.modelIQ.comparisons {
            configs.append(contentsOf: comparisons.values.map(\.latest))
        }
        let results = configs.map { c in
            ModelResult(
                name: c.model, depth: c.reasoningEffort,
                iq: c.score,
                passed: c.passed, tasks: c.tasks,
                cost: c.costUSD,
                timeMinutes: Int((c.wallSeconds / 60).rounded()),
                family: .codex,
                isReference: false
            )
        }
        guard !results.isEmpty else { throw RadarParserError.codexUnavailable }
        return results
    }

    // MARK: - claude-code-radar.json → Claude（best-effort）

    /// best-effort：解析 claude-code-radar.json 的 iq.models[]，每条取各序列的最后一个非 null 值。
    /// time[] 单位为小时，换算成分钟；valid 作为任务总数分母。
    /// 调用方用 try? 包裹：抓取/解析失败或 0 条有效都降级处理，不影响 Codex。
    static func parseClaude(json data: Data) throws -> [ModelResult] {
        guard let resp = try? JSONDecoder().decode(ClaudeRadarResponse.self, from: data) else {
            throw RadarParserError.claudeUnavailable
        }
        var results: [ModelResult] = []
        for series in resp.iq.models {
            guard let iq = latest(series.iq), iq > 0,
                  let pass = latest(series.pass),
                  let valid = latest(series.valid), valid > 0,
                  let cost = latest(series.cost), cost > 0,
                  let hours = latest(series.time), hours > 0 else { continue }
            let (name, depth) = parseClaudeLabel(series.name)
            results.append(ModelResult(
                name: name, depth: depth,
                iq: iq,
                passed: Int(pass.rounded()), tasks: Int(valid.rounded()),
                cost: cost,
                timeMinutes: Int((hours * 60).rounded()),
                family: .claude,
                isReference: true,
                metricSource: .claudeRadar
            ))
        }
        guard !results.isEmpty else { throw RadarParserError.claudeUnavailable }
        return results
    }

    /// 序列的最后一个非 null 值（当日缺测时数组尾部可能为 null）。
    private static func latest(_ values: [Double?]) -> Double? {
        values.last(where: { $0 != nil }) ?? nil
    }

    /// 从标签解析模型名 + 思考档："Opus 4.8 xhigh" → ("opus-4.8","xhigh")；"Haiku 4.5" → ("haiku-4.5","")。
    private static func parseClaudeLabel(_ label: String) -> (String, String) {
        var tokens = label.split(separator: " ").map(String.init)
        let knownDepths: Set<String> = ["low", "medium", "high", "xhigh", "max"]
        let depth: String
        if tokens.count > 1, let last = tokens.last, knownDepths.contains(last.lowercased()) {
            depth = tokens.removeLast()
        } else {
            depth = ""
        }
        let name = tokens.joined(separator: "-").lowercased()
        return (name, depth)
    }

    // MARK: - 时间戳

    /// 解码 current.json 的 quota_radar.updated_at → Date。
    static func parseTimestamp(json data: Data) -> Date? {
        guard let resp = try? JSONDecoder().decode(CurrentResponse.self, from: data),
              let iso = resp.modelIQ.quotaRadar?.updatedAt else { return nil }
        return parseISO(iso)
    }

    /// 解析 ISO8601（兼容带/不带小数秒）。
    static func parseISO(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    /// 实时相对时间："X 小时 X 分钟" / "X 分钟"。
    static func relativeLabel(from updatedAt: Date, to now: Date = Date()) -> String {
        let mins = max(0, Int((now.timeIntervalSince(updatedAt) / 60).rounded(.down)))
        let h = mins / 60, m = mins % 60
        return h > 0 ? "\(h) 小时 \(m) 分钟" : "\(m) 分钟"
    }
}
