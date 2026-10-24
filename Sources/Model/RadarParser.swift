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
                metricSource: .codexRadar,
                bench: old.bench
            )
            let supplement = ScoredModel(
                result: renamed, score: model.score,
                recommendedIn: model.recommendedIn, costIndex: model.costIndex,
                benchRead: model.benchRead
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
                costIndex: model.costIndex,
                benchRead: model.benchRead
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

// MARK: - Radar Bench（radar-bench-binding.json / radar-bench-score?view=summary）

enum RadarBenchError: LocalizedError {
    case invalidBinding(String)
    case invalidObservation(String)

    var errorDescription: String? {
        switch self {
        case .invalidBinding(let reason): return "基准绑定无效：\(reason)"
        case .invalidObservation(let reason): return "成绩响应无效：\(reason)"
        }
    }
}

/// 解码并校验 Radar Bench 绑定与逐档成绩，再把读取状态组装成快照。
/// 所有校验都是「宁可拒绝也不误读」：身份（benchmark / catalog / task_set_sha256 / 计分版本 / 模型 / 档位）
/// 必须与绑定逐项一致，分数必须落在 0...score_max，覆盖与状态必须自洽。
enum RadarBenchParser {

    // MARK: 绑定

    static func parseBinding(json data: Data) throws -> RadarBenchBinding {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data), root.objectValue != nil else {
            throw RadarBenchError.invalidBinding("不是 JSON 对象")
        }
        guard root["enabled"]?.boolValue == true, root["production_read_verified"]?.boolValue == true else {
            throw RadarBenchError.invalidBinding("未启用或未通过生产读取验证")
        }
        func text(_ key: String) throws -> String {
            guard let value = root[key]?.stringValue, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw RadarBenchError.invalidBinding("缺少 \(key)")
            }
            return value
        }
        let benchmark = try text("benchmark")
        let catalog = try text("catalog_version")
        let sha = try text("task_set_sha256")
        let scoreVersion = try text("score_version")
        guard isSHA256(sha) else { throw RadarBenchError.invalidBinding("task_set_sha256 不是 64 位十六进制") }
        guard let scoreMax = root["score_max"]?.doubleValue, scoreMax > 0 else {
            throw RadarBenchError.invalidBinding("score_max 无效")
        }
        guard let totalTasks = root["total_tasks"]?.intValue, totalTasks > 0 else {
            throw RadarBenchError.invalidBinding("total_tasks 无效")
        }
        if let counts = root["source_counts"]?.objectValue {
            let values = counts.values.compactMap(\.intValue)
            guard values.count == counts.count, values.reduce(0, +) == totalTasks else {
                throw RadarBenchError.invalidBinding("source_counts 与 total_tasks 不一致")
            }
        }
        guard let items = root["model_efforts"]?.arrayValue else {
            throw RadarBenchError.invalidBinding("缺少 model_efforts")
        }
        var seen = Set<String>()
        var selections: [BenchSelection] = []
        for item in items {
            guard let model = item["model"]?.stringValue, !model.isEmpty,
                  let effort = item["effort"]?.stringValue, !effort.isEmpty else { continue }
            let selection = BenchSelection(model: model, effort: effort)
            if seen.insert(selection.id).inserted { selections.append(selection) }
        }
        guard !selections.isEmpty else { throw RadarBenchError.invalidBinding("没有可读取的模型档位") }
        guard selections.count <= RadarBenchPolicy.maxSelections else {
            throw RadarBenchError.invalidBinding("模型档位数量异常（\(selections.count)）")
        }
        return RadarBenchBinding(
            benchmark: benchmark, catalogVersion: catalog, taskSetSHA256: sha,
            scoreVersion: scoreVersion, scoreMax: scoreMax, totalTasks: totalTasks, selections: selections
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    // MARK: 逐档成绩

    static func parseObservation(
        json data: Data, binding: RadarBenchBinding, selection: BenchSelection
    ) throws -> RadarBenchObservation {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw RadarBenchError.invalidObservation("不是合法 JSON")
        }
        return try parseObservation(root, binding: binding, selection: selection)
    }

    static func parseObservation(
        _ root: JSONValue, binding: RadarBenchBinding, selection: BenchSelection
    ) throws -> RadarBenchObservation {
        func fail(_ reason: String) -> RadarBenchError { .invalidObservation(reason) }
        guard root.objectValue != nil else { throw fail("不是 JSON 对象") }

        func text(_ key: String) throws -> String {
            guard let value = root[key]?.stringValue, !value.isEmpty else { throw fail("缺少 \(key)") }
            return value
        }
        let schema = try text("schema")
        guard schema.hasPrefix("radar-bench-public-summary-") else { throw fail("schema 不受支持：\(schema)") }

        // 身份：必须与绑定及所请求的档位逐项一致，防止错位 / 旧基准 / 别的档位的响应混进来。
        let benchmark = try text("benchmark")
        let catalog = try text("catalog_version")
        let sha = try text("task_set_sha256")
        let scoreVersion = try text("score_version")
        guard benchmark == binding.benchmark else { throw fail("benchmark 与绑定不一致") }
        guard catalog == binding.catalogVersion else { throw fail("catalog_version 与绑定不一致") }
        guard sha == binding.taskSetSHA256 else { throw fail("task_set_sha256 与绑定不一致") }
        guard scoreVersion == binding.scoreVersion else { throw fail("score_version 与绑定不一致") }
        guard let scoreMax = root["score_max"]?.doubleValue, scoreMax == binding.scoreMax else {
            throw fail("score_max 与绑定不一致")
        }
        let model = try text("model")
        let effort = try text("effort")
        guard model == selection.model, effort == selection.effort else { throw fail("模型/档位与请求不一致") }

        guard let required = root["required_tasks"]?.intValue, required == binding.totalTasks else {
            throw fail("required_tasks 与绑定不一致")
        }
        guard let coverage = root["coverage"]?.intValue, (0...required).contains(coverage) else {
            throw fail("coverage 超出范围")
        }
        guard let graded = root["graded_runs_count"]?.intValue, graded >= 0 else {
            throw fail("graded_runs_count 无效")
        }

        // score：null / 缺失 = 无成绩；数值必须落在 0...score_max（0 是真实 0 分）。
        var score: Double?
        if let value = root["score"], !value.isNull {
            guard let number = value.doubleValue, (0...scoreMax).contains(number) else {
                throw fail("score 超出 0...\(scoreMax)")
            }
            score = number
        }
        let status = try text("score_status")
        if status == "complete" {
            guard coverage == required, score != nil else { throw fail("complete 状态与覆盖/分数不一致") }
        }
        if score != nil, coverage == 0 { throw fail("有分数但覆盖为 0") }

        // 统计：缺失 / 不可用时费用与耗时一律视为未知（nil），不当 0。
        let statistics = root["statistics"]
        let sampleCount = statistics?["sample_count"]?.intValue
        var elapsed: RadarBenchMetric?
        var cost: RadarBenchMetric?
        let statisticsState = root["statistics_state"]?.stringValue ?? statistics?["statistics_state"]?.stringValue
        if statisticsState == "available", let metrics = statistics?["metrics"] {
            elapsed = try parseMetric(metrics["elapsed_ms"], sampleCount: sampleCount, name: "elapsed_ms")
            cost = try parseMetric(metrics["api_equivalent_usd"], sampleCount: sampleCount, name: "api_equivalent_usd")
        }

        let detail = root["detail_metrics"]
        return RadarBenchObservation(
            selection: selection, schema: schema, benchmark: benchmark, catalogVersion: catalog,
            taskSetSHA256: sha, scoreVersion: scoreVersion, scoreMax: scoreMax,
            score: score, scoreStatus: status, coverage: coverage, requiredTasks: required,
            gradedRunsCount: graded, sampleCount: sampleCount,
            costBasis: statistics?["cost_basis"]?.stringValue,
            elapsed: elapsed, apiEquivalentUSD: cost,
            latestGradedAt: detail?["latest_graded_at"]?.stringValue.flatMap(parseSourceDate),
            sourceAsOf: detail?["as_of"]?.stringValue.flatMap(parseSourceDate),
            raw: root
        )
    }

    private static func parseMetric(_ value: JSONValue?, sampleCount: Int?, name: String) throws -> RadarBenchMetric? {
        guard let value, value.objectValue != nil else { return nil }
        guard let known = value["known_samples"]?.intValue, known >= 0,
              let missing = value["missing_samples"]?.intValue, missing >= 0 else {
            throw RadarBenchError.invalidObservation("\(name) 样本计数无效")
        }
        if let sampleCount, known + missing != sampleCount {
            throw RadarBenchError.invalidObservation("\(name) 样本数与 sample_count 不一致")
        }
        var knownTotal: Double?
        if known > 0 {
            guard let total = value["known_total"]?.doubleValue, total >= 0 else {
                throw RadarBenchError.invalidObservation("\(name) known_total 无效")
            }
            knownTotal = total
        }
        return RadarBenchMetric(
            knownTotal: knownTotal, knownSamples: known, missingSamples: missing,
            missingReason: value["missing_reason"]?.stringValue
        )
    }

    /// 来源侧时间戳（带微秒小数秒，如 2026-10-18T00:59:23.459695Z）；解析失败返回 nil，不拿别的时间顶替。
    static func parseSourceDate(_ iso: String) -> Date? {
        if let date = RadarParser.parseISO(iso) { return date }
        let trimmed = iso.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return trimmed == iso ? nil : RadarParser.parseISO(trimmed)
    }

    // MARK: 快照

    /// 把绑定 + 逐档读取状态组装成快照。年龄超过 24h（或时间在未来）的观测被剔除，不展示、不参与推荐。
    /// 没有任何有效观测时返回 nil（调用方保持「无数据」）。成功读取过的行永远不会被后来的失败读取替换。
    static func makeSnapshot(
        binding: RadarBenchBinding, entries: [String: RadarBenchEntry], now: Date
    ) -> RadarSnapshot? {
        var live: [String: RadarBenchEntry] = [:]
        for selection in binding.selections {
            guard var entry = entries[selection.id] else { continue }
            if entry.observation != nil {
                let age = entry.fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
                if age > RadarBenchPolicy.maxCacheAge || age < -300 {
                    entry.observation = nil
                    entry.fetchedAt = nil
                }
            }
            if entry.observation != nil || entry.lastError != nil { live[selection.id] = entry }
        }
        let context = RadarBenchContext(binding: binding, entries: live)

        let ranked: [(index: Int, model: ScoredModel)] = binding.selections.enumerated().compactMap { index, selection in
            guard let entry = live[selection.id], let obs = entry.observation, let fetchedAt = entry.fetchedAt else {
                return nil
            }
            let result = ModelResult(
                name: selection.model, depth: selection.effort,
                iq: obs.score ?? 0, passed: 0, tasks: obs.coverage,
                cost: obs.apiEquivalentUSD?.knownMean ?? 0,
                timeMinutes: Int(((obs.elapsed?.knownMean ?? 0) / 60_000).rounded()),
                family: .codex, isReference: false, bench: obs
            )
            let stale = entry.lastError != nil || now.timeIntervalSince(fetchedAt) > RadarBenchPolicy.staleAfter
            let model = ScoredModel(
                result: result,
                score: obs.score.map { min(max($0 / obs.scoreMax, 0), 1) } ?? 0,
                benchRead: BenchReadInfo(fetchedAt: fetchedAt, isStale: stale, lastError: entry.lastError)
            )
            return (index, model)
        }
        guard !ranked.isEmpty else { return nil }

        // 分数降序（缺失分数排最后），同分保持绑定顺序。
        let sorted = ranked.sorted { lhs, rhs in
            switch (lhs.model.result.bench?.score, rhs.model.result.bench?.score) {
            case let (l?, r?): return l != r ? l > r : lhs.index < rhs.index
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.index < rhs.index
            }
        }.map(\.model)

        // 绑定里若出现 claude-* 竞品，沿用既有并入 Claude Code 分区的路径；目前绑定只有 gpt-*，该分区为空并被隐藏。
        let (codex, claude) = RadarParser.mergeAnthropicIntoClaude(codex: sorted, claude: [])
        return RadarSnapshot(
            all: codex + claude,
            updatedAt: context.latestReadAt ?? now,
            claudeStatus: .ok,
            codexSource: .website,
            benchmark: context
        )
    }
}
