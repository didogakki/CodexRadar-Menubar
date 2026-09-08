// 覆盖 StatusItemTitleBuilder.make：无数据兜底、菜单栏只跟 GPT 候选、隐藏 IQ、IQ 阈值配色。
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
}
