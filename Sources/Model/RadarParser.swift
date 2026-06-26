// current.json → Codex（主源）+ HTML 对比表 → Claude（best-effort）+ 综合分 + 排序分组 + 时间戳。
//
// Codex 评分数据来自 current.json 的 model_iq.latest / model_iq.comparisons；
// Claude/Opus 参考列仍从网站首页 HTML 的 model-iq-compare 对比表 best-effort 抓取；
// 时间戳来自 current.json 的 quota_radar.updated_at。综合分按 family 各自归一化。
import Foundation

enum RadarParserError: LocalizedError {
    case tableNotFound
    case rowMissing(String)
    case empty
    case codexUnavailable

    var errorDescription: String? {
        switch self {
        case .tableNotFound: return "未找到对比表"
        case .rowMissing(let r): return "对比表缺少「\(r)」行"
        case .empty: return "对比表无可用模型"
        case .codexUnavailable: return "current.json 无可用 Codex 数据"
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

    // MARK: - HTML 对比表 → Claude（best-effort）

    /// best-effort：只从 HTML 对比表取 Claude/Opus 参考列（family == .claude）。
    /// 调用方用 try? 包裹：抓取/解析失败或 0 个 Claude 都降级处理，不影响 Codex。
    static func parseClaude(html: String) throws -> [ModelResult] {
        try parseModels(html: html).filter { $0.family == .claude }
    }

    // MARK: - HTML 对比表

    /// 解析网站首页 HTML 的 model-iq-compare 表，返回 6 条原始记录。
    static func parseModels(html: String) throws -> [ModelResult] {
        // 1) 框定表格区域：表头 div → 参考备注（避开 <style> 里的同名 class）。
        let headAnchor = "model-iq-compare-row model-iq-compare-head"
        guard let headRange = html.range(of: headAnchor) else { throw RadarParserError.tableNotFound }
        let endIndex = html.range(of: "model-iq-reference-note", range: headRange.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
        let region = String(html[headRange.lowerBound..<endIndex])

        // 2) 表头列序：<span class="model-iq-column-KEY">LABEL</span>。
        let header = regexGroups(#"<span class="model-iq-column-([\w\-]+)">([^<]*)</span>"#, in: region)
        guard !header.isEmpty else { throw RadarParserError.tableNotFound }
        let columns: [(key: String, label: String)] = header.map { ($0[0], $0[1]) }

        // 3) 各数据行：行内首个 <span> 是标签，<strong> 是按列的值。
        let byMetric = parseMetricRows(region: region)
        func row(_ label: String) throws -> [String: String] {
            guard let dict = byMetric[label] else { throw RadarParserError.rowMissing(label) }
            return dict
        }
        let iqRow     = try row("IQ")
        let passedRow = try row("通过数")
        let costRow   = try row("费用")
        let timeRow   = try row("耗时")

        // 4) 组装：IQ/费用/耗时必须解析成功且为正数，否则跳过该列（避免静默 0 流入除法/pow）。
        var results: [ModelResult] = []
        for col in columns {
            guard let iqRaw = iqRow[col.key],
                  let passRaw = passedRow[col.key],
                  let costRaw = costRow[col.key],
                  let timeRaw = timeRow[col.key] else { continue }
            guard let iq = parseIQ(iqRaw), iq > 0,
                  let cost = parseCost(costRaw), cost > 0,
                  let timeMinutes = parseMinutes(timeRaw), timeMinutes > 0 else { continue }
            let (passed, tasks) = parsePassed(passRaw)
            let isClaude = col.key.contains("claude") || col.key.contains("opus")
            let (name, depth) = parseNameDepth(label: col.label, claude: isClaude)
            results.append(ModelResult(
                name: name, depth: depth,
                iq: iq,
                passed: passed, tasks: tasks,
                cost: cost,
                timeMinutes: timeMinutes,
                family: isClaude ? .claude : .codex,
                isReference: isClaude
            ))
        }
        guard !results.isEmpty else { throw RadarParserError.empty }
        return results
    }

    /// 把每个数据行解析为 {列key: 值}，并以行标签（通过数/费用/耗时…）为键。
    private static func parseMetricRows(region: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        let rows = regexGroups(#"<div class="model-iq-compare-row[^"]*"[^>]*>([\s\S]*?)</div>"#, in: region)
        for row in rows {
            let inner = row[0]
            // 行标签：首个 <span>…</span>（数据行的标签 span 无 class）。
            guard let label = regexGroups(#"<span[^>]*>([^<]*)</span>"#, in: inner).first?.first else { continue }
            let cells = regexGroups(#"<strong class="[^"]*model-iq-column-([\w\-]+)[^"]*"[^>]*>([^<]*)</strong>"#, in: inner)
            guard !cells.isEmpty else { continue }   // 跳过表头行（无 strong）
            var dict: [String: String] = [:]
            for c in cells { dict[c[0]] = c[1] }
            out[label] = dict
        }
        return out
    }

    // MARK: - 字段解析

    /// "7/12" → (7, 12)。
    private static func parsePassed(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 12)
    }

    /// "$43.3" → 43.3；解析失败（如 "—" / "N/A" / 空值）返回 nil。
    private static func parseCost(_ s: String) -> Double? {
        Double(s.filter { $0.isNumber || $0 == "." })
    }

    /// "87.5" → 87.5；解析失败（如 "—" / "N/A" / 空值）返回 nil。
    private static func parseIQ(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    /// "3.4h" / "1h25m" / "28m" / "1小时3分" / "28分钟" → 分钟；解析失败（如 "—" / "N/A" / 空值）返回 nil。
    private static func parseMinutes(_ s: String) -> Int? {
        let lower = s.lowercased()
        var minutes = 0.0
        var matched = false
        if let h = regexGroups(#"([\d.]+)\s*(?:h|小时)"#, in: lower).first?.first, let hv = Double(h) {
            minutes += hv * 60
            matched = true
        }
        if let m = regexGroups(#"(\d+)\s*(?:m|分钟|分)"#, in: lower).first?.first, let mv = Double(m) {
            minutes += mv
            matched = true
        }
        if !matched {  // 兜底：纯数字按分钟
            let digits = s.filter { $0.isNumber }
            guard !digits.isEmpty, let n = Double(digits) else { return nil }
            minutes = n
        }
        return Int(minutes.rounded())
    }

    /// 从表头标签解析模型名 + 思考档。
    /// Codex "5.5-xhigh" → ("gpt-5.5","xhigh")；Claude "Opus 4.8 max" → ("opus-4.8","max")。
    private static func parseNameDepth(label: String, claude: Bool) -> (String, String) {
        if claude {
            let tokens = label.split(separator: " ").map(String.init)
            let depth = tokens.last ?? ""
            let brand = (tokens.first ?? "opus").lowercased()
            let version = tokens.first(where: { $0.contains(".") }) ?? ""
            return ("\(brand)-\(version)", depth)
        } else {
            let parts = label.split(separator: "-").map(String.init)
            let version = parts.first ?? label
            let depth = parts.count > 1 ? parts[1] : ""
            return ("gpt-\(version)", depth)
        }
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

    // MARK: - 正则工具

    /// 返回每个匹配的捕获组（不含整体匹配），按出现顺序。
    private static func regexGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            (1..<m.numberOfRanges).compactMap { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }
}
