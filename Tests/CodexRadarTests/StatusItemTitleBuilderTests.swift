// 覆盖 StatusItemTitleBuilder.make：无数据兜底、菜单栏只跟 GPT 候选、隐藏 IQ、IQ 阈值配色，
// 以及 Radar Bench 的榜首 / 临时领先者 / 进度三态与 tooltip 说明。
import XCTest
import AppKit
@testable import CodexRadar

final class StatusItemTitleBuilderTests: XCTestCase {

    private func scoredModel(name: String, depth: String, iq: Double, family: ModelFamily) -> ScoredModel {
        ScoredModel(
            result: ModelResult(
                name: name, depth: depth, iq: iq, passed: 7, tasks: 12,
                cost: 10, timeMinutes: 30, family: family, isReference: family == .claude
            ),
            score: 0.5
        )
    }

    func testMake_noSnapshot_returnsDash() {
        let title = StatusItemTitleBuilder.make(snapshot: nil)
        XCTAssertEqual(title.string, "—")
    }

    func testMake_noCodexCandidate_returnsDash() {
        let claudeOnly = RadarSnapshot(
            all: [scoredModel(name: "opus-4.8", depth: "max", iq: 100, family: .claude)],
            updatedAt: Date()
        )
        let title = StatusItemTitleBuilder.make(snapshot: claudeOnly)
        XCTAssertEqual(title.string, "—")
    }

    func testMake_nonGPTCodexOnly_returnsDash() {
        let snapshot = RadarSnapshot(
            all: [scoredModel(name: "codex-mini", depth: "high", iq: 105, family: .codex)],
            updatedAt: Date()
        )
        let title = StatusItemTitleBuilder.make(snapshot: snapshot)
        XCTAssertEqual(title.string, "—")
    }

    func testMake_picksCodexChampionEvenWhenClaudeScoresHigher() {
        // menuBarBest 按业务规则只跟 GPT 候选，即便综合分排第一的是 Claude。
        let snapshot = RadarSnapshot(
            all: [
                scoredModel(name: "opus-4.8", depth: "max", iq: 100, family: .claude),
                scoredModel(name: "gpt-5.5", depth: "xhigh", iq: 87.5, family: .codex),
            ],
            updatedAt: Date()
        )
        let title = StatusItemTitleBuilder.make(snapshot: snapshot)
        XCTAssertTrue(title.string.contains("5.5·xhigh"))
        XCTAssertFalse(title.string.lowercased().contains("opus"))
    }

    func testMake_showsCompactNameWithoutIQSuffix() {
        let snapshot = RadarSnapshot(
            all: [scoredModel(name: "gpt-5.5", depth: "medium", iq: 87.5, family: .codex)],
            updatedAt: Date()
        )
        let title = StatusItemTitleBuilder.make(snapshot: snapshot)
        XCTAssertEqual(title.string, "● 5.5·medium")
    }

    func testMake_colorThresholds() {
        let cases: [(iq: Double, expected: NSColor)] = [
            (100, NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)),
            (95, NSColor(srgbRed: 1.000, green: 0.839, blue: 0.039, alpha: 1)),
            (85, NSColor(srgbRed: 1.000, green: 0.624, blue: 0.039, alpha: 1)),
            (70, NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1)),
        ]
        for c in cases {
            let snapshot = RadarSnapshot(
                all: [scoredModel(name: "gpt-5.5", depth: "medium", iq: c.iq, family: .codex)],
                updatedAt: Date()
            )
            let title = StatusItemTitleBuilder.make(snapshot: snapshot)
            let color = title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
            XCTAssertEqual(color, c.expected, "iq=\(c.iq)")
        }
    }

    // MARK: - Radar Bench：菜单栏只在整批读取完整时给出榜首，且不套用旧 IQ 阈值色

    private func benchSnapshot(
        readable count: Int, partialCoverageAt: Int? = nil, allProvisional: Bool = false, failedAt: Int? = nil
    ) throws -> RadarSnapshot {
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        var entries: [String: RadarBenchEntry] = [:]
        for (index, selection) in BenchFixtures.selections.prefix(count).enumerated() {
            let partial = allProvisional || index == partialCoverageAt
            let data = BenchFixtures.summaryData(
                selection, score: BenchFixtures.defaultScore(selection),
                coverage: partial ? 40 : 64, status: partial ? "provisional" : "complete")
            entries[selection.id] = RadarBenchEntry(
                observation: try RadarBenchParser.parseObservation(json: data, binding: binding, selection: selection),
                fetchedAt: BenchFixtures.t0,
                lastError: index == failedAt ? "HTTP 500" : nil)
        }
        return try XCTUnwrap(RadarBenchParser.makeSnapshot(binding: binding, entries: entries, now: BenchFixtures.t0))
    }

    func testMake_benchCompleteBatch_showsChampionInNeutralColor() throws {
        let snapshot = try benchSnapshot(readable: 34)
        let title = StatusItemTitleBuilder.make(snapshot: snapshot)

        XCTAssertEqual(title.string, "● 6.1-sol·low")
        let color = title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
        // 榜首分数 120/150：旧阈值下是绿色；新量纲不套用旧 100/90/80 阈值。
        XCTAssertNotEqual(color, NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1))
    }

    func testMake_benchPartialBatch_showsProvisionalLeaderNotChampion() throws {
        let snapshot = try benchSnapshot(readable: 12)
        XCTAssertNil(snapshot.menuBarBest)
        let title = StatusItemTitleBuilder.make(snapshot: snapshot)
        XCTAssertEqual(title.string, "◐ 6.1-sol·low 12/34")

        // 中性色，不套用旧 IQ 阈值（分数 120 在旧阈值下会是绿色）。
        let color = title.attribute(.foregroundColor, at: title.length - 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, NSColor.secondaryLabelColor)

        let detail = try XCTUnwrap(StatusItemTitleBuilder.detail(snapshot: snapshot, now: BenchFixtures.t0))
        XCTAssertTrue(detail.contains("已读取完整档中最高"))
        XCTAssertTrue(detail.contains("不是全榜冠军"))
        XCTAssertTrue(detail.contains("12/34"))
        XCTAssertTrue(detail.contains("最近成功读取"))
        XCTAssertFalse(detail.contains("全榜榜首"))
    }

    func testMake_benchProvisionalLeaderSkipsIncompleteTier() throws {
        // 分数最高的第 0 档覆盖未完整：不能当领先者，改取已读取完整档中最高的下一档。
        let snapshot = try benchSnapshot(readable: 12, partialCoverageAt: 0)
        XCTAssertEqual(StatusItemTitleBuilder.make(snapshot: snapshot).string, "◐ 6.1-sol·medium 11/34")
    }

    func testMake_benchOnlyIncompleteTiers_staysProgressOnly() throws {
        let snapshot = try benchSnapshot(readable: 12, allProvisional: true)
        XCTAssertEqual(StatusItemTitleBuilder.make(snapshot: snapshot).string, "○ 0/34")
        let detail = try XCTUnwrap(StatusItemTitleBuilder.detail(snapshot: snapshot, now: BenchFixtures.t0))
        XCTAssertTrue(detail.contains("暂无可显示的型号"))
    }

    func testMake_benchAllReadButSomeProvisional_showsProvisionalLeader() throws {
        let snapshot = try benchSnapshot(readable: 34, partialCoverageAt: 7)
        XCTAssertNil(snapshot.menuBarBest, "有档位覆盖未完整，最高分可能还会变")
        XCTAssertEqual(StatusItemTitleBuilder.make(snapshot: snapshot).string, "◐ 6.1-sol·low 33/34")
    }

    func testMake_benchFailedTier_staysProvisionalAndTooltipExposesFailure() throws {
        // 34 档都有观测，但第 3 档最近一次刷新失败：不声明榜首，tooltip 暴露失败。
        let snapshot = try benchSnapshot(readable: 34, failedAt: 3)
        XCTAssertNil(snapshot.menuBarBest)
        XCTAssertEqual(StatusItemTitleBuilder.make(snapshot: snapshot).string, "◐ 6.1-sol·low 34/34")
        let detail = try XCTUnwrap(StatusItemTitleBuilder.detail(snapshot: snapshot, now: BenchFixtures.t0))
        XCTAssertTrue(detail.contains("1 个档位最近一次刷新失败"))
        XCTAssertTrue(detail.contains("不是全榜冠军"))
    }

    func testMake_benchStaleData_tooltipWarns() throws {
        let snapshot = try benchSnapshot(readable: 12)
        let later = BenchFixtures.t0.addingTimeInterval(RadarBenchPolicy.staleAfter + 60)
        let detail = try XCTUnwrap(StatusItemTitleBuilder.detail(snapshot: snapshot, now: later))
        XCTAssertTrue(detail.contains("可能过时"))
    }

    func testMake_benchFullBatchAfterPartial_becomesChampion() throws {
        let partial = try benchSnapshot(readable: 12)
        XCTAssertTrue(StatusItemTitleBuilder.make(snapshot: partial).string.hasPrefix("◐"))

        let full = try benchSnapshot(readable: 34)
        XCTAssertEqual(StatusItemTitleBuilder.make(snapshot: full).string, "● 6.1-sol·low")
        XCTAssertNil(full.provisionalMenuBarBest)
        let detail = try XCTUnwrap(StatusItemTitleBuilder.detail(snapshot: full, now: BenchFixtures.t0))
        XCTAssertTrue(detail.contains("全榜榜首"))
        XCTAssertFalse(detail.contains("不是全榜冠军"))
    }

    /// 局部批次里菜单栏显示的是临时领先者（menuBarBest 为 nil）：展示层可达性保护必须用快照的统一展示 id，
    /// 否则「只看前沿」会把菜单栏上看到的型号从完整榜单 / 模型推荐里藏掉。
    func testMenuBarDisplayedID_protectsProvisionalLeaderFromFrontierFilters() throws {
        let snapshot = try benchSnapshot(readable: 12)
        let leader = try XCTUnwrap(snapshot.provisionalMenuBarBest)
        XCTAssertNil(snapshot.menuBarBest)
        XCTAssertEqual(snapshot.menuBarDisplayedID, leader.id)

        // 同组里一个更便宜、更快、分数不低的档位压制领先者。
        let rival = ScoredModel(
            result: ModelResult(name: leader.result.name, depth: "rival", iq: leader.iq + 1, passed: 7, tasks: 336,
                                cost: 0.01, timeMinutes: 1, family: .codex, isReference: false),
            score: leader.score)
        let verdicts = CostEfficiency.verdicts(in: [leader, rival])
        XCTAssertTrue(verdicts[leader.id]?.isDominated ?? false, "前提：领先者被压制")

        // 完整榜单。
        XCTAssertFalse(FrontierFilter.isVisible(leader, verdicts: verdicts, protectedID: snapshot.menuBarBest?.id))
        XCTAssertTrue(FrontierFilter.isVisible(leader, verdicts: verdicts, protectedID: snapshot.menuBarDisplayedID))

        // 模型推荐：整组与展开列表。
        let group = ModelRecommendationGroup(modelName: leader.result.name, metricSource: .codexRadar, tiers: [leader, rival])
        XCTAssertTrue(ModelRecommendationFrontierFilter.isGroupVisible(
            group, verdicts: verdicts, menuBarID: snapshot.menuBarDisplayedID))
        let tiers = ModelRecommendationFrontierFilter.visibleTiers(
            in: group, verdicts: verdicts, menuBarID: snapshot.menuBarDisplayedID, forceShowAll: false)
        XCTAssertTrue(tiers.contains { $0.id == leader.id })
    }

    // 整批完整后展示 id 即严格榜首。
    func testMenuBarDisplayedID_fullBatchEqualsChampion() throws {
        let full = try benchSnapshot(readable: 34)
        XCTAssertEqual(full.menuBarDisplayedID, full.menuBarBest?.id)
        XCTAssertNotNil(full.menuBarDisplayedID)
    }

    func testDetail_legacySnapshot_isNil() {
        let snapshot = RadarSnapshot(
            all: [scoredModel(name: "gpt-5.5", depth: "medium", iq: 87.5, family: .codex)],
            updatedAt: Date()
        )
        XCTAssertNil(StatusItemTitleBuilder.detail(snapshot: snapshot))
    }
}
