// 覆盖 StatusItemTitleBuilder.make：无数据兜底、菜单栏只跟 Codex 冠军、IQ 阈值配色。
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

    func testMake_picksCodexChampionEvenWhenClaudeScoresHigher() {
        // menuBarBest 按业务规则只跟 Codex 族，即便综合分排第一的是 Claude。
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

    // 注：审核稿的测试缺口描述写的是「不显示 IQ」，但当前 StatusItemTitleBuilder.make 的实现
    // 会在紧凑名后附加 " IQ <值>"。这里按现状断言，差异已在本次修复说明里向用户标出，未擅自改动显示逻辑。
    func testMake_currentOutputIncludesCompactNameAndIQSuffix() {
        let snapshot = RadarSnapshot(
            all: [scoredModel(name: "gpt-5.5", depth: "medium", iq: 87.5, family: .codex)],
            updatedAt: Date()
        )
        let title = StatusItemTitleBuilder.make(snapshot: snapshot)
        XCTAssertEqual(title.string, "● 5.5·medium IQ 87.5")
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
}
