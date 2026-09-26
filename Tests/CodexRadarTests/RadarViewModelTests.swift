// 覆盖 RadarViewModel 的纯逻辑：厂商筛选在刷新后失效时的回退（不依赖网络请求）。
import XCTest
@testable import CodexRadar

final class RadarViewModelTests: XCTestCase {

    private func codexSnapshot(vendors names: [String], source: CodexDataSource = .website) -> RadarSnapshot {
        // tasks=20 让非 gpt-* 型号（如 grok/deepseek）不会被展示层质量过滤剔除（见 CodexDisplayQuality），
        // 保持这里只测试厂商筛选逻辑本身，与质量过滤互不干扰。
        let results = names.map {
            ModelResult(name: $0, depth: "medium", iq: 90, passed: 6, tasks: 20,
                        cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        }
        let scored = results.map { ScoredModel(result: $0, score: 0.5) }
        return RadarSnapshot(all: scored, updatedAt: Date(), codexSource: source)
    }

    // MARK: - 不用更不完整的快照覆盖上一次的好快照

    func testShouldReplace_acceptsFirstSnapshot() {
        XCTAssertTrue(RadarViewModel.shouldReplace(nil, with: codexSnapshot(vendors: ["gpt-5.5"], source: .recommendationsOnly)))
    }

    func testShouldReplace_rejectsRecommendationsOnlyOverWebsite() {
        let good = codexSnapshot(vendors: ["gpt-5.5"], source: .website)
        let degraded = codexSnapshot(vendors: ["gpt-5.5"], source: .recommendationsOnly)
        XCTAssertFalse(RadarViewModel.shouldReplace(good, with: degraded))
    }

    func testShouldReplace_rejectsLocalEstimateOverWebsite() {
        let good = codexSnapshot(vendors: ["gpt-5.5"], source: .website)
        let degraded = codexSnapshot(vendors: ["gpt-5.5"], source: .localEstimate)
        XCTAssertFalse(RadarViewModel.shouldReplace(good, with: degraded))
    }

    func testShouldReplace_acceptsSameOrBetterSource() {
        let localEstimate = codexSnapshot(vendors: ["gpt-5.5"], source: .localEstimate)
        // 同档刷新照常覆盖（否则数据永远停在第一次拉取）
        XCTAssertTrue(RadarViewModel.shouldReplace(localEstimate, with: codexSnapshot(vendors: ["gpt-5.5"], source: .localEstimate)))
        // 上游恢复后升档必须覆盖
        XCTAssertTrue(RadarViewModel.shouldReplace(localEstimate, with: codexSnapshot(vendors: ["gpt-5.5"], source: .website)))
    }

    func testReconciledFilter_keepsSelection_whenSectionStillPresent() {
        let snapshot = codexSnapshot(vendors: ["gpt-5.5", "grok-4.6"])
        XCTAssertEqual(RadarViewModel.reconciledFilter(.vendor(.openai), in: snapshot), .vendor(.openai))
        XCTAssertEqual(RadarViewModel.reconciledFilter(.vendor(.xai), in: snapshot), .vendor(.xai))
    }

    func testReconciledFilter_fallsBackToAll_whenSectionNoLongerPresent() {
        let snapshot = codexSnapshot(vendors: ["grok-4.6"])   // 刷新后 openai 消失
        XCTAssertNil(RadarViewModel.reconciledFilter(.vendor(.openai), in: snapshot))
        // Claude 组抓不到内容时同样不该留在筛选里
        XCTAssertNil(RadarViewModel.reconciledFilter(.claude, in: snapshot))
    }

    func testReconciledFilter_staysNil_whenNoSelectionMade() {
        XCTAssertNil(RadarViewModel.reconciledFilter(nil, in: codexSnapshot(vendors: ["gpt-5.5"])))
    }

    // MARK: - 榜单模式：默认「模型推荐」

    @MainActor
    func testListMode_defaultsToRecommendation_whenNoStoredPreference() async {
        let originalListMode = UserDefaults.standard.object(forKey: RadarViewModel.listModeKey)
        defer {
            if let originalListMode {
                UserDefaults.standard.set(originalListMode, forKey: RadarViewModel.listModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RadarViewModel.listModeKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: RadarViewModel.listModeKey)
        let vm = RadarViewModel()
        XCTAssertEqual(vm.listMode, .recommendation)
    }

    // MARK: - 模型推荐分组：全量数据计算，不受展示层质量过滤 / 只看前沿开关影响

    func testRecommendationGroups_useFullDataIgnoringDisplayQualityFilter() {
        // tasks=5 < CodexDisplayQuality.minTasks(20)：完整榜单展示层会把这一档过滤掉，
        // 但「模型推荐」判定必须仍看到全部档位，否则 95% 门槛会算错。
        // 用 grok-4.6（非 gpt-* 前缀）而非 gpt-*：CodexDisplayQuality.filtered 对 gpt-* 型号有
        // 质量过滤豁免（isGPTModel 恒真），gpt-* 低样本档位不会被过滤掉，撑不起本测试要验证的前提。
        let lowQuality = ModelResult(name: "grok-4.6", depth: "medium", iq: 90, passed: 2, tasks: 5,
                                      cost: 5, timeMinutes: 10, family: .codex, isReference: false)
        let highQuality = ModelResult(name: "grok-4.6", depth: "high", iq: 100, passed: 8, tasks: 30,
                                       cost: 40, timeMinutes: 60, family: .codex, isReference: false)
        let scored = [ScoredModel(result: highQuality, score: 0.5), ScoredModel(result: lowQuality, score: 0.5)]
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date(), codexSource: .website)

        // 前提成立：完整榜单展示层确实会把低样本量档位过滤掉。
        XCTAssertEqual(snapshot.codexGroupsByVendor.first { $0.vendor == .xai }?.models.count, 1)

        // 推荐分组必须仍看到两档；90/100 = 90% < 95%，medium 落选，推荐 high。
        let groups = snapshot.recommendationGroups(for: .vendor(.xai))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.tiers.count, 2, "推荐判定必须用全量数据，不能被展示层过滤缩水")
        guard let outcome = groups.first?.outcome, case .recommended(let picked, _, _) = outcome else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(picked.result.depth, "high")
    }

    // MARK: - 模型推荐可靠性：codexSource 非网站权威源时，codexRadar 指标不能冒充工程推荐；
    // claudeRadar 指标不受影响（由 claudeStatus 独立管控，与 Codex 侧抓取状态无关）。

    private func recommendationSnapshot(codexSource: CodexDataSource) -> RadarSnapshot {
        let codexTiers = [
            ScoredModel(result: ModelResult(name: "gpt-6-astra", depth: "medium", iq: 90, passed: 6, tasks: 20,
                                             cost: 5, timeMinutes: 30, family: .codex, isReference: false), score: 0.5),
            ScoredModel(result: ModelResult(name: "gpt-6-astra", depth: "high", iq: 100, passed: 8, tasks: 30,
                                             cost: 10, timeMinutes: 60, family: .codex, isReference: false), score: 0.5),
        ]
        // Claude 分区混两个源：claude-opus-5 来自 claudecoderadar（本身独立），
        // claude-sonnet-5 是从 codexradar 竞品列并入的（与 codexSource 同一次抓取）。
        let claudeTiers = [
            ScoredModel(result: ModelResult(name: "claude-opus-5", depth: "medium", iq: 90, passed: 6, tasks: 20,
                                             cost: 20, timeMinutes: 30, family: .claude, isReference: false,
                                             metricSource: .claudeRadar), score: 0.5),
            ScoredModel(result: ModelResult(name: "claude-opus-5", depth: "high", iq: 100, passed: 8, tasks: 30,
                                             cost: 40, timeMinutes: 60, family: .claude, isReference: false,
                                             metricSource: .claudeRadar), score: 0.5),
            ScoredModel(result: ModelResult(name: "claude-sonnet-5", depth: "medium", iq: 85, passed: 5, tasks: 20,
                                             cost: 3, timeMinutes: 20, family: .claude, isReference: false,
                                             metricSource: .codexRadar), score: 0.5),
            ScoredModel(result: ModelResult(name: "claude-sonnet-5", depth: "high", iq: 95, passed: 7, tasks: 25,
                                             cost: 6, timeMinutes: 40, family: .claude, isReference: false,
                                             metricSource: .codexRadar), score: 0.5),
        ]
        return RadarSnapshot(all: codexTiers + claudeTiers, updatedAt: Date(), codexSource: codexSource)
    }

    func testRecommendationGroups_codexSourceWebsite_producesReliableRecommendation() {
        let snapshot = recommendationSnapshot(codexSource: .website)
        let vendorGroups = snapshot.recommendationGroups(for: .vendor(.openai))
        guard case .recommended = vendorGroups.first?.outcome else {
            return XCTFail("网站权威源应给出可靠推荐")
        }
    }

    func testRecommendationGroups_codexSourceLocalEstimate_downgradesCodexRadarOnly() {
        let snapshot = recommendationSnapshot(codexSource: .localEstimate)

        let vendorGroups = snapshot.recommendationGroups(for: .vendor(.openai))
        guard case .unavailable(.unreliableCodexSource) = vendorGroups.first?.outcome else {
            return XCTFail("本地估算不能冒充工程推荐")
        }
        XCTAssertEqual(vendorGroups.first?.tiers.count, 2, "展开列表仍保留全部档位，只是折叠行不再声称推荐")

        let claudeGroups = snapshot.recommendationGroups(for: .claude)
        let opus = claudeGroups.first { $0.modelName == "claude-opus-5" }
        let sonnet = claudeGroups.first { $0.modelName == "claude-sonnet-5" }
        guard case .recommended = opus?.outcome else {
            return XCTFail("claudeRadar 同源指标不受 Codex 侧抓取状态影响，应仍可靠")
        }
        guard case .unavailable(.unreliableCodexSource) = sonnet?.outcome else {
            return XCTFail("并入 Claude 分区的 codexRadar 竞品条目与 codexSource 同源，同样要降级")
        }
    }

    func testRecommendationGroups_codexSourceRecommendationsOnly_downgradesCodexRadarOnly() {
        let snapshot = recommendationSnapshot(codexSource: .recommendationsOnly)
        let vendorGroups = snapshot.recommendationGroups(for: .vendor(.openai))
        guard case .unavailable(.unreliableCodexSource) = vendorGroups.first?.outcome else {
            return XCTFail("仅剩站长推荐条目时的综合 IQ 不能冒充工程推荐")
        }
    }

    // MARK: - 「模型推荐」DeepSeek 展示层限额：与「完整榜单」的 DeepSeekDisplayLimit 保持同样条数

    func testRecommendationGroups_deepSeekLimitedToThree_matchingFullBoardCount() {
        // 6 个不同 DeepSeek 模型、各一档，无一带站长推荐：完整榜单（codexGroupsByVendor）
        // 会砍到 3 条，「模型推荐」（recommendationGroups）此前不套用该限额会显示全部 6 条。
        let results = (0..<6).map { i in
            ModelResult(name: "deepseek-v\(i)", depth: "high", iq: 90, passed: 7, tasks: 20,
                        cost: 5, timeMinutes: 20, family: .codex, isReference: false)
        }
        let scored = results.map { ScoredModel(result: $0, score: 0.5) }
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date(), codexSource: .website)

        let fullBoardCount = snapshot.codexGroupsByVendor.first { $0.vendor == .deepseek }?.models.count
        XCTAssertEqual(fullBoardCount, 3, "前提：完整榜单本就把 DeepSeek 砍到 3 条")

        let groups = snapshot.recommendationGroups(for: .vendor(.deepseek))
        XCTAssertEqual(groups.count, 3, "模型推荐应与完整榜单展示同样多的 DeepSeek 条数")
    }

    func testRecommendationGroups_deepSeekLimit_doesNotChangeRecommendationOutcomeOfSurvivors() {
        // 限额只砍展示的组数，不能顺带改掉保留下来那些组的推荐判定依据（仍是全量档位算的）。
        let survivorTiers = [
            ModelResult(name: "deepseek-v0", depth: "medium", iq: 90, passed: 6, tasks: 20, cost: 10, timeMinutes: 30, family: .codex, isReference: false),
            ModelResult(name: "deepseek-v0", depth: "high", iq: 100, passed: 8, tasks: 30, cost: 20, timeMinutes: 60, family: .codex, isReference: false),
        ]
        let others = (1..<5).map { i in
            ModelResult(name: "deepseek-v\(i)", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 5, timeMinutes: 20, family: .codex, isReference: false)
        }
        let scored = (survivorTiers + others).map { ScoredModel(result: $0, score: 0.5) }
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date(), codexSource: .website)

        let groups = snapshot.recommendationGroups(for: .vendor(.deepseek))
        let survivor = groups.first { $0.modelName == "deepseek-v0" }
        XCTAssertEqual(survivor?.tiers.count, 2, "推荐判定仍基于全量档位，不受展示层限额影响")
        guard case .recommended(let picked, _, _) = survivor?.outcome else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(picked.result.depth, "high")
    }

    // MARK: - 分区顺序：筛选行与榜单共用 availableSections

    func testAvailableSections_followDisplayOrderAndSkipEmptyOnes() {
        // 展示顺序恒为 OpenAI → Claude Code → Grok → DeepSeek，与传入顺序无关
        let snapshot = codexSnapshot(vendors: ["deepseek-v4", "grok-4.6", "gpt-5.5"])
        XCTAssertEqual(snapshot.availableSections, [.vendor(.openai), .vendor(.xai), .vendor(.deepseek)])
        // 白名单之外的厂商（gemini）不成为分区
        let withGemini = codexSnapshot(vendors: ["gpt-5.5", "gemini-3.7-flash"])
        XCTAssertEqual(withGemini.availableSections, [.vendor(.openai)])
    }

    func testAvailableSections_includeClaudeWhenPresentOrUnavailable() {
        let claudeRow = ScoredModel(result: ModelResult(name: "opus-4.8", depth: "high", iq: 100, passed: 6,
                                                        tasks: 12, cost: 30, timeMinutes: 40,
                                                        family: .claude, isReference: true), score: 0.9)
        var snapshot = codexSnapshot(vendors: ["gpt-5.5"])
        snapshot = RadarSnapshot(all: snapshot.all + [claudeRow], updatedAt: Date(), codexSource: .website)
        XCTAssertEqual(snapshot.availableSections, [.vendor(.openai), .claude])

        // 抓取失败时该组仍要出现——它会显示「数据提取失败」提示行
        var unavailable = codexSnapshot(vendors: ["gpt-5.5"])
        unavailable.claudeStatus = .unavailable
        XCTAssertEqual(unavailable.availableSections, [.vendor(.openai), .claude])
    }
}
