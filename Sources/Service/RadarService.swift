// 拉取并解析数据：
// - radar-insights（站长推荐，权威源）+ intelligence-efficiency-metrics（智力效率，权威指标源）为 Codex 主数据；
// - current.json 只保留为完整失败回退（本地估算），主源可用时其失败不致命；
// - Claude Code 分区不再单独请求 claudecoderadar.com，完全来自 intelligence-efficiency-metrics 里的
//   claude-* 竞品条目（见 RadarParser.mergeAnthropicIntoClaude），跟 Codex 数据同一次抓取。
import Foundation

enum RadarServiceError: LocalizedError {
    case http(Int)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "服务器返回 \(code)"
        case .network(let msg): return msg
        case .decode(let msg): return msg
        }
    }
}

struct RadarService {
    let jsonURL = URL(string: "https://codexradar.com/current.json")!
    // 与 codexradar.com 网页使用同源实时接口，避免旧子域/静态快照导致推荐不一致。
    let insightsURL = URL(string: "https://codexradar.com/api/radar-insights")!
    let efficiencyURL = URL(string: "https://codexradar.com/api/intelligence-efficiency-metrics")!

    func fetch() async throws -> RadarSnapshot {
        // 并发拉取三源：insights + efficiency 是 Codex 权威主源；current.json 仅回退。
        async let insightsData = dataRetryingOnce(from: insightsURL, timeout: 10)
        async let efficiencyData = dataRetryingOnce(from: efficiencyURL, timeout: 10)
        async let jsonData = try? data(from: jsonURL, timeout: 10)

        let insightsRaw = await insightsData
        let efficiencyRaw = await efficiencyData
        let json = await jsonData

        // 主路径：efficiency points 构建 Codex 列表，insights 提供推荐分组与菜单栏选型。
        let parsedInsights: [InsightGroup] = insightsRaw.flatMap { try? RadarParser.parseInsights(json: $0) } ?? []
        let efficiency: [EfficiencyPoint] = efficiencyRaw.flatMap { try? RadarParser.parseEfficiency(json: $0) } ?? []
        let comprehensive = insightsRaw.map(RadarParser.parseComprehensivePoints(json:)) ?? []
        // 网页端会在 daily_development / hard_problems 为空时用 comprehensive_points + metrics 补算；
        // 客户端按接口给出的 rule 复刻同一套规则，两组分别补算后保持服务端固有顺序。
        let insights = RadarParser.supplementHardProblems(
            insights: RadarParser.supplementDailyDevelopment(
                insights: parsedInsights,
                comprehensive: comprehensive,
                efficiency: efficiency
            ),
            comprehensive: comprehensive,
            efficiency: efficiency
        )

        let codex: [ScoredModel]
        let insightGroups: [InsightGroup]
        let codexSource: CodexDataSource
        var localBestID: String? = nil

        // current.json 本地估算结果（efficiency-only 时供菜单栏 identity 回退，全失败时作完整回退）。
        let localScored: [ScoredModel]? = json
            .flatMap { try? RadarParser.parseCodex(json: $0) }
            .flatMap { try? RadarParser.scoreAndSort($0) }

        if !efficiency.isEmpty {
            // 主路径：efficiency 指标 + insights 推荐；insights 失败时列表保持网站排序，
            // 菜单栏用本地冠军 identity 匹配网站列表回退（本地公式不改变网站排序、不伪装推荐）。
            codex = RadarParser.buildCodexFromEfficiency(points: efficiency, insights: insights)
            insightGroups = insights
            codexSource = .website
            if insights.isEmpty {
                localBestID = localScored?.first?.id
            }
        } else if let scored = localScored {
            // efficiency 失败：推荐条目本身只有寥寥几条（网站近期常返回空推荐分组），只拿它建列表会把
            // 榜单塌缩成两三行；改用 current.json 本地估算的完整候选列表，并把站长推荐合并到匹配条目上
            // （推荐 chip 与菜单栏选型仍归站长推荐）。UI 标注「本地估算」。
            codex = RadarParser.applyRecommendations(scored, insights: insights)
            insightGroups = insights
            codexSource = .localEstimate
            localBestID = scored.first?.id
        } else if !insights.isEmpty {
            // efficiency 与 current.json 都不可用：最后兜底，用推荐条目自身指标构建去重列表（仍为网站数据）。
            // 标为 .recommendationsOnly，让 VM 能识别出这是最不完整的一档、不拿它覆盖上一次的好快照。
            codex = RadarParser.buildCodexFromInsights(insights: insights)
            insightGroups = insights
            codexSource = .recommendationsOnly
        } else {
            throw RadarServiceError.decode("radar-insights / intelligence-efficiency / current.json 均不可用")
        }

        // Claude Code 分区完全来自 codexradar 的 claude-* 竞品条目：不再请求 claudecoderadar.com，
        // mergeAnthropicIntoClaude 的 claude 参数固定传空列表（函数本身逻辑不变，只是雷达数据源永远为空）。
        // 这批条目跟 Codex 数据同一次抓取，取不到时该分区判为不可用。
        let (codexWithoutAnthropic, claude) = RadarParser.mergeAnthropicIntoClaude(
            codex: codex, claude: []
        )
        let claudeStatus: ClaudeStatus = claude.isEmpty ? .unavailable : .ok

        // 多源时间戳：insights/efficiency 的 source_updated_at → current.json → 当前时间。
        let updatedAt = insightsRaw.flatMap { RadarParser.parseInsightsTimestamp(json: $0) }
            ?? efficiencyRaw.flatMap { RadarParser.parseEfficiencyTimestamp(json: $0) }
            ?? json.flatMap { RadarParser.parseTimestamp(json: $0) }
            ?? Date()

        return RadarSnapshot(
            all: codexWithoutAnthropic + claude,
            updatedAt: updatedAt,
            claudeStatus: claudeStatus,
            insights: insightGroups,
            codexSource: codexSource,
            localBestID: localBestID
        )
    }

    /// 权威源（insights / efficiency）的瞬时失败会让整段榜单降级，代价远大于一次重试：
    /// 失败后短暂退避再试一次，两次都失败才按不可用处理。
    private func dataRetryingOnce(from url: URL, timeout: TimeInterval) async -> Data? {
        if let first = try? await data(from: url, timeout: timeout) { return first }
        try? await Task.sleep(nanoseconds: 400_000_000)
        return try? await data(from: url, timeout: timeout)
    }

    private func data(from url: URL, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RadarServiceError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RadarServiceError.http(http.statusCode)
        }
        return data
    }
}
