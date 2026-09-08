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
