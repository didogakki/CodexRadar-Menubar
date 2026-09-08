// 覆盖 RadarService.fetch 的集成路径：current.json 成功 + Claude 源失败时应仍返回 Codex 组，并标记 Claude unavailable。
import XCTest
@testable import CodexRadar

/// 拦截 URLSession.shared 的请求，按 URL 返回预设的响应或错误，免去给 RadarService 引入依赖注入。
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let data: Data
        let statusCode: Int
    }

    static var stubs: [String: Stub] = [:]
    static var errors: [String: Error] = [:]

    static func reset() {
        stubs = [:]
        errors = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return stubs[url.absoluteString] != nil || errors[url.absoluteString] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if let error = Self.errors[url.absoluteString] {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let stub = Self.stubs[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RadarServiceTests: XCTestCase {

    private let codexJSON = """
    {
      "model_iq": {
        "latest": {
          "score": 50.0, "passed": 4, "tasks": 12,
          "wall_seconds": 1483, "model": "gpt-5.5", "reasoning_effort": "xhigh",
          "cost_usd": 41.405896
        },
        "quota_radar": { "updated_at": "2026-06-26T05:44:34Z" }
      }
    }
    """

    private let insightsJSON = """
    {
      "schema": 1,
      "source_updated_at": "2026-07-26T10:00:00Z",
      "recommendations": [
        {"key": "daily_development", "title": "日常开发", "items": [
          {"model": "gpt-5.5", "effort": "medium", "iq": 87.0, "combined_cost_index": 0.27}
        ]}
      ]
    }
    """

    private let efficiencyJSON = """
    {
      "schema": 2,
      "source_updated_at": "2026-07-26T09:00:00Z",
      "points": [
        {"model": "gpt-5.5", "effort": "medium", "iq": 87.0, "passed": 7, "valid_tasks": 12,
         "average_price_usd": 23.9, "average_minutes": 85.0, "combined_cost_index": 0.27},
        {"model": "gpt-5.4", "effort": "xhigh", "iq": 101.0, "passed": 8, "valid_tasks": 12,
         "average_price_usd": 23.4, "average_minutes": 246.0, "combined_cost_index": 0.23}
      ]
    }
    """

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        super.tearDown()
    }

    /// 给全部四个源设置默认失败，逐个测试再按需覆盖，避免真实网络请求。
    private func failAll(_ service: RadarService) {
        for url in [service.insightsURL, service.efficiencyURL, service.jsonURL, service.claudeURL] {
            StubURLProtocol.errors[url.absoluteString] = URLError(.timedOut)
        }
    }

    func testFetch_primarySourcesSucceed_currentJSONFails_stillReturnsWebsiteData() async throws {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.insightsURL.absoluteString] = nil
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.stubs[service.insightsURL.absoluteString] = .init(data: Data(insightsJSON.utf8), statusCode: 200)
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(efficiencyJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertEqual(snapshot.codexSource, .website, "expected .website source when insights + efficiency succeed")
        // 榜单按 IQ 降序（推荐项不置顶）；菜单栏仍跟随 daily_development 第一项
        XCTAssertEqual(snapshot.codexGroup.map(\.id), ["gpt-5.4/xhigh", "gpt-5.5/medium"])
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
        XCTAssertEqual(snapshot.insights.map(\.key), ["daily_development"])
        // 时间戳取 insights 的 source_updated_at
        XCTAssertEqual(snapshot.updatedAt, RadarParser.parseISO("2026-07-26T10:00:00Z"))
    }

    func testFetch_emptyDailyGroupUsesWebsiteSupplementAndRecommendsSolMedium() async throws {
        let service = RadarService()
        failAll(service)
        let liveInsights = """
        {
          "schema": 1,
          "source_updated_at": "2026-08-29T07:42:09Z",
          "comprehensive_points": [
            {"model":"gpt-5.6-sol","effort":"medium","iq":92.44},
            {"model":"gpt-5.6-sol","effort":"ultra","iq":102.92},
            {"model":"gpt-5.5","effort":"high","iq":92.37}
          ],
          "recommendations": [
            {"key":"daily_development","title":"日常开发","items":[]},
            {"key":"hard_problems","title":"难题攻坚","items":[
              {"model":"gpt-5.6-sol","effort":"ultra","iq":102.92}
            ]}
          ]
        }
        """
        let liveMetrics = """
        {"schema":3,"source_updated_at":"2026-08-29T07:55:22Z","points":[
          {"model":"gpt-5.6-sol","effort":"medium","iq":95.09,"passed":204,"total":336,
           "average_price_usd":3.105691,"average_minutes":16.77,"combined_cost_index":1505.18},
          {"model":"gpt-5.6-sol","effort":"ultra","iq":100.89,"passed":226,"total":336,
           "average_price_usd":24.691531,"average_minutes":51.96,"combined_cost_index":378162.861},
          {"model":"gpt-5.5","effort":"high","iq":91.07,"passed":204,"total":336,
           "average_price_usd":3.687197,"average_minutes":16.98,"combined_cost_index":1856.189}
        ]}
        """
        StubURLProtocol.errors[service.insightsURL.absoluteString] = nil
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.stubs[service.insightsURL.absoluteString] = .init(data: Data(liveInsights.utf8), statusCode: 200)
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(liveMetrics.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertEqual(snapshot.insights.first?.items.map(\.id), ["gpt-5.6-sol/medium", "gpt-5.5/high"])
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.6-sol/medium")
    }

    func testFetch_primarySourcesFail_fallsBackToCurrentJSONLocalEstimate() async throws {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.jsonURL.absoluteString] = nil
        StubURLProtocol.stubs[service.jsonURL.absoluteString] = .init(data: Data(codexJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertEqual(snapshot.codexSource, .localEstimate, "expected .localEstimate fallback when primary sources fail")
        XCTAssertFalse(snapshot.codexGroup.isEmpty)
        XCTAssertTrue(snapshot.insights.isEmpty)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/xhigh")
        XCTAssertEqual(snapshot.updatedAt, RadarParser.parseISO("2026-06-26T05:44:34Z"))
    }

    func testFetch_efficiencySucceeds_claudeFails_returnsCodexAndMarksClaudeUnavailable() async throws {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.insightsURL.absoluteString] = nil
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.stubs[service.insightsURL.absoluteString] = .init(data: Data(insightsJSON.utf8), statusCode: 200)
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(efficiencyJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertFalse(snapshot.codexGroup.isEmpty)
        XCTAssertTrue(snapshot.claudeGroup.isEmpty)
        switch snapshot.claudeStatus {
        case .unavailable: break
        case .ok: XCTFail("expected claudeStatus to be .unavailable when Claude fetch fails")
        }
    }

    func testFetch_allCodexSourcesFail_throws() async throws {
        let service = RadarService()
        failAll(service)

        do {
            _ = try await service.fetch()
            XCTFail("expected fetch() to throw when all Codex sources fail")
        } catch {
            // insights/efficiency/current.json 全部失败必须致命，不能静默返回空快照。
        }
    }

    // MARK: - 部分成功降级

    func testFetch_insightsOnly_currentFails_marksRecommendationsOnlyFallback() async throws {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.insightsURL.absoluteString] = nil
        StubURLProtocol.stubs[service.insightsURL.absoluteString] = .init(data: Data(insightsJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertEqual(snapshot.codexSource, .recommendationsOnly, "efficiency 与 current.json 都不可用时应标为最小兜底档")
        XCTAssertEqual(snapshot.insights.map(\.key), ["daily_development"])
        // 从 insight items 构建的列表，菜单栏跟 daily 首项
        XCTAssertEqual(snapshot.codexGroup.map(\.id), ["gpt-5.5/medium"])
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
        XCTAssertEqual(snapshot.codexGroup.first?.recommendedIn, ["日常开发"])
    }

    func testFetch_efficiencyOnly_currentAvailable_keepsWebsiteOrderMenuBarMatchesLocalChampion() async throws {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.errors[service.jsonURL.absoluteString] = nil
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(efficiencyJSON.utf8), statusCode: 200)
        // current.json 唯一配置 = gpt-5.5/medium → 本地冠军 identity
        let currentJSON = """
        {
          "model_iq": {
            "latest": {
              "score": 87.0, "passed": 7, "tasks": 12,
              "wall_seconds": 5100, "model": "gpt-5.5", "reasoning_effort": "medium",
              "cost_usd": 23.9
            }
          }
        }
        """
        StubURLProtocol.stubs[service.jsonURL.absoluteString] = .init(data: Data(currentJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertEqual(snapshot.codexSource, .website, "efficiency-only 仍应为 .website")
        // 列表保持网站排序（无推荐 → 按 IQ 降序），本地公式不改变排序
        XCTAssertEqual(snapshot.codexGroup.map(\.id), ["gpt-5.4/xhigh", "gpt-5.5/medium"])
        XCTAssertTrue(snapshot.codexGroup.allSatisfy { $0.recommendedIn.isEmpty })
        // 菜单栏匹配本地冠军 identity，而非网站列表第一项
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
    }

    func testFetch_efficiencyOnly_currentUnavailable_menuBarFallsBackToFirstWebsiteItem() async throws {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(efficiencyJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        XCTAssertEqual(snapshot.codexGroup.map(\.id), ["gpt-5.4/xhigh", "gpt-5.5/medium"])
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.4/xhigh")
    }

    // MARK: - 多厂商端到端：真实 schema 3 数据，原始数据不丢模型，展示层只保留白名单厂商

    /// 复刻线上 2026-09-06 前后 intelligence-efficiency-metrics 的真实返回：
    /// schema 3，混合 OpenAI/xAI/DeepSeek/Anthropic 命名模型，端到端验证 snapshot.all/codexGroup
    /// 权威数据不丢模型、不重复；展示层（codexGroupsByVendor）只保留白名单厂商 OpenAI/Grok/DeepSeek，
    /// Anthropic/Claude 命名的竞品条目整体从 Codex 展示中剔除。
    func testFetch_liveSchema3MultiVendorEfficiency_populatesAllVendorGroupsWithoutDroppingOrDuplicating() async throws {
        let service = RadarService()
        failAll(service)
        let multiVendorMetrics = """
        {"schema":3,"source_updated_at":"2026-09-06T08:00:00Z","points":[
          {"model":"gpt-6-astra","effort":"high","iq":112.4,"passed":9,"total":12,
           "average_price_usd":31.2,"average_minutes":90.0,"combined_cost_index":0.31},
          {"model":"gpt-5.6-sol","effort":"medium","iq":95.09,"passed":204,"total":336,
           "average_price_usd":3.105691,"average_minutes":16.77,"combined_cost_index":1505.18},
          {"model":"grok-4.6","effort":"high","iq":98.2,"passed":8,"total":20,
           "average_price_usd":18.4,"average_minutes":60.0,"combined_cost_index":0.29},
          {"model":"deepseek-v4-turbo","effort":"high","iq":90.1,"passed":7,"total":20,
           "average_price_usd":5.2,"average_minutes":70.0,"combined_cost_index":0.12},
          {"model":"claude-opus-5","effort":"high","iq":108.5,"passed":9,"total":12,
           "average_price_usd":60.0,"average_minutes":200.0,"combined_cost_index":0.55},
          {"model":"claude-sonnet-5","effort":"medium","iq":97.3,"passed":8,"total":12,
           "average_price_usd":20.0,"average_minutes":80.0,"combined_cost_index":0.20}
        ]}
        """
        let claudeReferenceJSON = """
        {"iq":{"models":[
          {"name":"Opus 5","iq":[105.0],"pass":[9.0],"valid":[12.0],"cost":[58.0],"time":[3.2]}
        ]}}
        """
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.errors[service.claudeURL.absoluteString] = nil
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(multiVendorMetrics.utf8), statusCode: 200)
        StubURLProtocol.stubs[service.claudeURL.absoluteString] = .init(data: Data(claudeReferenceJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        // 非 Anthropic 的 Codex 侧模型必须都在，不因厂商未知/非 GPT 被丢弃；
        // claude-* 条目已由解析层搬进 Claude Code 分区，不再留在 codexGroup。
        XCTAssertEqual(
            Set(snapshot.codexGroup.map(\.result.name)),
            Set(["gpt-6-astra", "gpt-5.6-sol", "grok-4.6", "deepseek-v4-turbo"])
        )
        // 展示层：白名单固定为 OpenAI/Grok/DeepSeek 三组，顺序固定；Anthropic/Claude 命名条目
        // 整体不展示（不再有 .anthropic 分组，也不落入"其他"）。
        XCTAssertEqual(snapshot.codexGroupsByVendor.map(\.vendor), [.openai, .xai, .deepseek])
        XCTAssertEqual(
            snapshot.codexGroupsByVendor.first { $0.vendor == .openai }?.models.map(\.result.name).sorted(),
            ["gpt-5.6-sol", "gpt-6-astra"]
        )
        XCTAssertEqual(snapshot.codexGroupsByVendor.first { $0.vendor == .xai }?.models.map(\.result.name), ["grok-4.6"])
        XCTAssertEqual(snapshot.codexGroupsByVendor.first { $0.vendor == .deepseek }?.models.map(\.result.name), ["deepseek-v4-turbo"])
        XCTAssertNil(
            snapshot.codexGroupsByVendor.first { $0.models.map(\.result.name).contains(where: { $0.hasPrefix("claude-") }) }
        )
        // Codex 侧的 claude-* 条目并入 Claude Code 分区：去掉 claude- 前缀与雷达侧对齐，按 IQ 降序，
        // 雷达已有的 identity 不被覆盖（这里雷达是 opus-5 无档位、竞品列是 opus-5/high，两者共存）。
        XCTAssertEqual(
            snapshot.claudeGroup.map(\.id),
            ["opus-5/high", "opus-5/", "sonnet-5/medium"]
        )
        // 来源标记保留，供性价比判定分桶：雷达条目 .claudeRadar，竞品列条目 .codexRadar。
        XCTAssertEqual(
            snapshot.claudeGroup.first { $0.id == "opus-5/" }?.result.metricSource, .claudeRadar
        )
        XCTAssertEqual(
            snapshot.claudeGroup.first { $0.id == "opus-5/high" }?.result.metricSource, .codexRadar
        )
        switch snapshot.claudeStatus {
        case .ok: break
        case .unavailable: XCTFail("expected claudeStatus to be .ok when Claude reference fetch succeeds")
        }
        // 菜单栏仍只推荐 GPT 型号，即便 Grok/Claude 分数更高。
        XCTAssertTrue(snapshot.menuBarBest?.result.isGPTModel ?? false)
    }

    // MARK: - 回归：efficiency 不可用时榜单不得塌缩成两三行

    /// 复刻线上 2026-09-06 的故障现场：intelligence-efficiency-metrics 不可用，而 radar-insights
    /// 只返回极少数推荐条目（daily_development / hard_problems 为空）。旧实现直接拿推荐条目建列表，
    /// 弹窗里 OpenAI 组只剩两行；现在应回退到 current.json 的完整候选列表（标注「本地估算」），
    /// 并把站长推荐合并到匹配条目上、提到最前。
    func testFetch_efficiencyFails_insightsSparse_usesFullLocalListInsteadOfCollapsingToRecommendations() async throws {
        let service = RadarService()
        failAll(service)
        let sparseInsights = """
        {
          "schema": 1,
          "source_updated_at": "2026-09-06T07:19:00Z",
          "recommendations": [
            {"key":"daily_development","title":"日常开发","items":[]},
            {"key":"hard_problems","title":"难题攻坚","items":[]},
            {"key":"background_automation","title":"后台自动化","items":[
              {"model":"gpt-5.6-luna","effort":"high","iq":80.02}
            ]},
            {"key":"lobster_tasks","title":"跑龙虾类任务","items":[
              {"model":"gpt-5.6-terra","effort":"low","iq":61.59},
              {"model":"gpt-5.6-terra","effort":"medium","iq":67.75}
            ]}
          ]
        }
        """
        let currentJSON = """
        {
          "model_iq": {
            "latest": {
              "score": 106.7, "passed": 239, "tasks": 336,
              "wall_seconds": 2035, "model": "gpt-5.6-sol", "reasoning_effort": "max",
              "cost_usd": 7.97
            },
            "comparisons": {
              "gpt_56_sol_medium": {"latest": {
                "score": 94.2, "passed": 211, "tasks": 336,
                "wall_seconds": 965, "model": "gpt-5.6-sol", "reasoning_effort": "medium",
                "cost_usd": 2.94}},
              "gpt_56_luna_high": {"latest": {
                "score": 76.34, "passed": 171, "tasks": 336,
                "wall_seconds": 1060, "model": "gpt-5.6-luna", "reasoning_effort": "high",
                "cost_usd": 0.21}},
              "gpt_56_terra_high": {"latest": {
                "score": 77.68, "passed": 174, "tasks": 336,
                "wall_seconds": 824, "model": "gpt-5.6-terra", "reasoning_effort": "high",
                "cost_usd": 1.08}},
              "gpt_55_high": {"latest": {
                "score": 90.18, "passed": 202, "tasks": 336,
                "wall_seconds": 998, "model": "gpt-5.5", "reasoning_effort": "high",
                "cost_usd": 3.77}}
            },
            "quota_radar": {"updated_at": "2026-09-06T07:00:00Z"}
          }
        }
        """
        StubURLProtocol.errors[service.insightsURL.absoluteString] = nil
        StubURLProtocol.errors[service.jsonURL.absoluteString] = nil
        StubURLProtocol.stubs[service.insightsURL.absoluteString] = .init(data: Data(sparseInsights.utf8), statusCode: 200)
        StubURLProtocol.stubs[service.jsonURL.absoluteString] = .init(data: Data(currentJSON.utf8), statusCode: 200)

        let snapshot = try await service.fetch()

        // 回退到本地估算，UI 会明确标注，不再冒充网站权威指标。
        XCTAssertEqual(snapshot.codexSource, .localEstimate, "efficiency 不可用时应回退 current.json 本地估算列表")
        // 核心回归点：OpenAI 展示组必须是完整候选列表，而不是推荐条目的两行。
        let openai = snapshot.codexGroupsByVendor.first { $0.vendor == .openai }
        XCTAssertEqual(openai?.models.count, 5)
        XCTAssertEqual(
            Set(snapshot.codexGroup.map(\.id)),
            Set(["gpt-5.6-sol/max", "gpt-5.6-sol/medium", "gpt-5.6-luna/high", "gpt-5.6-terra/high", "gpt-5.5/high"])
        )
        // 站长推荐仍然生效：命中的条目带推荐 chip，并排在列表最前。
        XCTAssertEqual(snapshot.codexGroup.first?.id, "gpt-5.6-luna/high")
        XCTAssertEqual(snapshot.codexGroup.first?.recommendedIn, ["后台自动化"])
        XCTAssertEqual(snapshot.insights.map(\.key), ["background_automation", "lobster_tasks"])
    }

    // MARK: - 回归：权威源掉档时不得覆盖上一次的好快照

    /// 先拿到完整的网站榜单，随后 efficiency 与 current.json 同时不可用（只剩两三条推荐条目）：
    /// VM 必须保留上一次的好快照，只把头部标成「未更新」，不能把完整榜单换成残缺列表。
    @MainActor
    func testViewModelRefresh_keepsGoodSnapshot_whenSourcesDegradeToRecommendationsOnly() async {
        let service = RadarService()
        failAll(service)
        StubURLProtocol.errors[service.insightsURL.absoluteString] = nil
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.stubs[service.insightsURL.absoluteString] = .init(data: Data(insightsJSON.utf8), statusCode: 200)
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = .init(data: Data(efficiencyJSON.utf8), statusCode: 200)

        let vm = RadarViewModel()
        await vm.refresh()

        XCTAssertEqual(vm.snapshot?.codexSource, .website)
        let goodIDs = vm.snapshot?.codexGroup.map(\.id)
        XCTAssertEqual(goodIDs, ["gpt-5.4/xhigh", "gpt-5.5/medium"])
        XCTAssertNil(vm.lastError)

        // efficiency 掉线，current.json 本来就是失败态 → service 只能给出 .recommendationsOnly
        StubURLProtocol.stubs[service.efficiencyURL.absoluteString] = nil
        StubURLProtocol.errors[service.efficiencyURL.absoluteString] = URLError(.timedOut)
        await vm.refresh()

        XCTAssertEqual(vm.snapshot?.codexSource, .website, "不得用只剩推荐条目的快照覆盖完整榜单")
        XCTAssertEqual(vm.snapshot?.codexGroup.map(\.id), goodIDs)
        XCTAssertEqual(vm.lastError, RadarViewModel.staleNotice)
        XCTAssertFalse(vm.isLoading)
    }

}
