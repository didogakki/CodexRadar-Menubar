// 覆盖 RadarParser：HTML 对比表解析的正常/异常路径 + 综合分公式 + 时间戳解码。
import XCTest
@testable import CodexRadar

final class RadarParserTests: XCTestCase {

    // MARK: - HTML 对比表 fixture（取自网站真实结构的精简版，6 列：4 Codex + 2 Opus 参考）

    private struct Column { let key: String; let label: String }

    private let columns: [Column] = [
        Column(key: "gpt_55_xhigh", label: "5.5-xhigh"),
        Column(key: "gpt_55_high", label: "5.5-high"),
        Column(key: "gpt_55_medium", label: "5.5-medium"),
        Column(key: "gpt_54_xhigh", label: "5.4-xhigh"),
        Column(key: "claude-opus-48_max", label: "Opus 4.8 max"),
        Column(key: "claude-opus-48_high", label: "Opus 4.8 high"),
    ]

    private let passedValues: [String: String] = [
        "gpt_55_xhigh": "7/12", "gpt_55_high": "7/12", "gpt_55_medium": "7/12",
        "gpt_54_xhigh": "8/12", "claude-opus-48_max": "6/12", "claude-opus-48_high": "8/12",
    ]
    private let iqValues: [String: String] = [
        "gpt_55_xhigh": "87.5", "gpt_55_high": "87.5", "gpt_55_medium": "87.5",
        "gpt_54_xhigh": "100.0", "claude-opus-48_max": "75.0", "claude-opus-48_high": "100.0",
    ]
    private let costValues: [String: String] = [
        "gpt_55_xhigh": "$43.3", "gpt_55_high": "$29.4", "gpt_55_medium": "$23.9",
        "gpt_54_xhigh": "$23.4", "claude-opus-48_max": "$115.1", "claude-opus-48_high": "$63.0",
    ]
    private let timeValues: [String: String] = [
        "gpt_55_xhigh": "3.4h", "gpt_55_high": "1.8h", "gpt_55_medium": "1.4h",
        "gpt_54_xhigh": "4.1h", "claude-opus-48_max": "6.4h", "claude-opus-48_high": "3.5h",
    ]

    /// 拼出 model-iq-compare 表的 HTML 片段；可对某行的某列覆盖取值、整列省略、或整行省略，用来模拟脏数据。
    private func compareTableHTML(
        overridePassed: [String: String] = [:],
        overrideIQ: [String: String] = [:],
        overrideCost: [String: String] = [:],
        overrideTime: [String: String] = [:],
        omitColumnsInRow: [String: Set<String>] = [:],
        omitRows: Set<String> = []
    ) -> String {
        let headerSpans = columns
            .map { #"<span class="model-iq-column-\#($0.key)">\#($0.label)</span>"# }
            .joined()

        func rowHTML(label: String, values: [String: String]) -> String {
            let omit = omitColumnsInRow[label] ?? []
            let cells = columns
                .filter { !omit.contains($0.key) }
                .map { #"<strong class="model-iq-value-comparison model-iq-column-\#($0.key)">\#(values[$0.key] ?? "")</strong>"# }
                .joined()
            return #"<div class="model-iq-compare-row" style="--model-iq-column-count:6"><span>\#(label)</span>\#(cells)</div>"#
        }

        var rows: [String] = []
        if !omitRows.contains("通过数") { rows.append(rowHTML(label: "通过数", values: passedValues.merging(overridePassed) { _, new in new })) }
        if !omitRows.contains("IQ") { rows.append(rowHTML(label: "IQ", values: iqValues.merging(overrideIQ) { _, new in new })) }
        if !omitRows.contains("费用") { rows.append(rowHTML(label: "费用", values: costValues.merging(overrideCost) { _, new in new })) }
        if !omitRows.contains("耗时") { rows.append(rowHTML(label: "耗时", values: timeValues.merging(overrideTime) { _, new in new })) }

        return """
        <div class="model-iq-compare-table" aria-label="当天模型 IQ 对比">
          <div class="model-iq-compare-row model-iq-compare-head" style="--model-iq-column-count:6"><span>项目</span>\(headerSpans)</div>
          \(rows.joined(separator: "\n"))
        </div>
        <p class="model-iq-note model-iq-reference-note">备注：Opus 4.8 为 CC Max 20x。</p>
        """
    }

    // MARK: - parseModels：happy path

    func testParseModels_happyPath_parsesAllSixColumns() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML())
        XCTAssertEqual(results.count, 6)

        let xhigh = try XCTUnwrap(results.first { $0.family == .codex && $0.depth == "xhigh" && $0.name == "gpt-5.5" })
        XCTAssertEqual(xhigh.iq, 87.5)
        XCTAssertEqual(xhigh.passed, 7)
        XCTAssertEqual(xhigh.tasks, 12)
        XCTAssertEqual(xhigh.cost, 43.3, accuracy: 1e-9)
        XCTAssertEqual(xhigh.timeMinutes, 204) // 3.4h
        XCTAssertFalse(xhigh.isReference)

        let opusMax = try XCTUnwrap(results.first { $0.family == .claude && $0.depth == "max" })
        XCTAssertEqual(opusMax.name, "opus-4.8")
        XCTAssertEqual(opusMax.iq, 75.0)
        XCTAssertEqual(opusMax.passed, 6)
        XCTAssertEqual(opusMax.cost, 115.1, accuracy: 1e-9)
        XCTAssertEqual(opusMax.timeMinutes, 384) // 6.4h
        XCTAssertTrue(opusMax.isReference)
    }

    // MARK: - 缺行 / 缺列

    func testParseModels_missingRow_throwsRowMissing() {
        XCTAssertThrowsError(try RadarParser.parseModels(html: compareTableHTML(omitRows: ["耗时"]))) { error in
            guard let err = error as? RadarParserError, case .rowMissing(let label) = err else {
                return XCTFail("expected .rowMissing, got \(error)")
            }
            XCTAssertEqual(label, "耗时")
        }
    }

    func testParseModels_columnMissingInOneRow_skipsOnlyThatColumn() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            omitColumnsInRow: ["费用": ["claude-opus-48_max"]]
        ))
        XCTAssertEqual(results.count, 5)
        XCTAssertFalse(results.contains { $0.family == .claude && $0.depth == "max" })
        XCTAssertTrue(results.contains { $0.family == .claude && $0.depth == "high" })
    }

    // MARK: - 费用 / 耗时 / IQ 为 "—" 或 "N/A"：跳过该列且不产生 NaN/Inf

    func testParseModels_costDash_skipsColumnAndKeepsScoresFinite() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideCost: ["claude-opus-48_max": "—"]
        ))
        XCTAssertEqual(results.count, 5)
        XCTAssertFalse(results.contains { $0.family == .claude && $0.depth == "max" })

        let scored = try RadarParser.scoreAndSort(results)
        XCTAssertEqual(scored.count, 5)
        for m in scored {
            XCTAssertTrue(m.score.isFinite)
        }
    }

    func testParseModels_timeNA_skipsColumn() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideTime: ["gpt_54_xhigh": "N/A"]
        ))
        XCTAssertEqual(results.count, 5)
        XCTAssertFalse(results.contains { $0.name == "gpt-5.4" })
    }

    func testParseModels_iqEmpty_skipsColumn() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideIQ: ["gpt_55_medium": ""]
        ))
        XCTAssertEqual(results.count, 5)
        XCTAssertFalse(results.contains { $0.depth == "medium" && $0.family == .codex })
    }

    func testParseModels_allColumnsInvalid_throwsEmpty() {
        let allDash = Dictionary(uniqueKeysWithValues: columns.map { ($0.key, "—") })
        XCTAssertThrowsError(try RadarParser.parseModels(html: compareTableHTML(overrideCost: allDash))) { error in
            guard let err = error as? RadarParserError, case .empty = err else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
    }

    // MARK: - 耗时：中文格式（"小时"/"分"/"分钟"）

    func testParseModels_chineseDuration_hoursAndMinutes_parsesCorrectly() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideTime: ["gpt_55_xhigh": "1小时3分"]
        ))
        let xhigh = try XCTUnwrap(results.first { $0.name == "gpt-5.5" && $0.depth == "xhigh" })
        XCTAssertEqual(xhigh.timeMinutes, 63) // 1小时3分 = 63 分钟，旧实现的纯数字兜底会误判成 13
    }

    func testParseModels_chineseDuration_minutesOnly_parsesCorrectly() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideTime: ["gpt_55_xhigh": "28分钟"]
        ))
        let xhigh = try XCTUnwrap(results.first { $0.name == "gpt-5.5" && $0.depth == "xhigh" })
        XCTAssertEqual(xhigh.timeMinutes, 28)
    }

    func testParseModels_chineseDuration_hoursOnly_parsesCorrectly() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideTime: ["gpt_55_xhigh": "2小时"]
        ))
        let xhigh = try XCTUnwrap(results.first { $0.name == "gpt-5.5" && $0.depth == "xhigh" })
        XCTAssertEqual(xhigh.timeMinutes, 120)
    }

    // MARK: - 数值前后带空格 / 换行：解析容错现状

    func testParseModels_valuesWithSurroundingSpaces_stillParse() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overridePassed: ["gpt_55_xhigh": " 7 / 12 "],
            overrideIQ: ["gpt_55_xhigh": "  87.5  "],
            overrideCost: ["gpt_55_xhigh": "  $43.3  "],
            overrideTime: ["gpt_55_xhigh": "  3.4h  "]
        ))
        let xhigh = try XCTUnwrap(results.first { $0.name == "gpt-5.5" && $0.depth == "xhigh" })
        XCTAssertEqual(xhigh.iq, 87.5)
        XCTAssertEqual(xhigh.cost, 43.3, accuracy: 1e-9)
        XCTAssertEqual(xhigh.passed, 7)
        XCTAssertEqual(xhigh.timeMinutes, 204)
    }

    // 注：parseIQ 用 .trimmingCharacters(in: .whitespaces) 只去空格不去换行，换行包裹的值会解析失败、
    // 整列被跳过（guard let iq = parseIQ(...) 不通过）。这是按现状记录的解析缺口，不在本次审核问题范围内，
    // 未擅自修改 parseIQ 的实现。
    func testParseModels_iqValueWrappedInNewline_currentlySkipsThatColumn() throws {
        let results = try RadarParser.parseModels(html: compareTableHTML(
            overrideIQ: ["gpt_55_xhigh": "\n87.5\n"]
        ))
        XCTAssertEqual(results.count, 5)
        XCTAssertFalse(results.contains { $0.name == "gpt-5.5" && $0.depth == "xhigh" })
        // 同名同档但不受影响的列仍应保留（5.4-xhigh 没被改动）。
        XCTAssertTrue(results.contains { $0.name == "gpt-5.4" && $0.depth == "xhigh" })
    }

    // MARK: - 数据单元格带额外 class / 属性：列 key 之外的 class 不应影响解析

    func testParseModels_extraClassAndAttributeOnDataCell_stillParses() throws {
        let html = """
        <div class="model-iq-compare-table">
          <div class="model-iq-compare-row model-iq-compare-head"><span>项目</span><span class="model-iq-column-gpt_55_xhigh">5.5-xhigh</span></div>
          <div class="model-iq-compare-row"><span>通过数</span><strong class="model-iq-value-comparison model-iq-column-gpt_55_xhigh highlighted" data-extra="x">7/12</strong></div>
          <div class="model-iq-compare-row"><span>IQ</span><strong class="model-iq-value-comparison model-iq-column-gpt_55_xhigh highlighted">87.5</strong></div>
          <div class="model-iq-compare-row"><span>费用</span><strong class="model-iq-value-comparison model-iq-column-gpt_55_xhigh highlighted">$43.3</strong></div>
          <div class="model-iq-compare-row"><span>耗时</span><strong class="model-iq-value-comparison model-iq-column-gpt_55_xhigh highlighted">3.4h</strong></div>
        </div>
        <p class="model-iq-note model-iq-reference-note">备注</p>
        """
        let results = try RadarParser.parseModels(html: html)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].iq, 87.5)
        XCTAssertEqual(results[0].cost, 43.3, accuracy: 1e-9)
        XCTAssertEqual(results[0].timeMinutes, 204)
    }

    // MARK: - scoreAndSort：公式快照 + 只用有效正数算 min/max

    func testScoreAndSort_formulaSnapshot() throws {
        let a = ModelResult(name: "a", depth: "x", iq: 100, passed: 8, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        let b = ModelResult(name: "b", depth: "x", iq: 80, passed: 6, tasks: 12, cost: 40, timeMinutes: 60, family: .codex, isReference: false)

        let scored = try RadarParser.scoreAndSort([a, b])

        XCTAssertEqual(scored.map(\.result.name), ["a", "b"])
        XCTAssertEqual(scored[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(scored[1].score, 0.6420846103055999, accuracy: 1e-9)
        XCTAssertEqual(scored[0].scoreLabel, "1.00")
        XCTAssertEqual(scored[1].scoreLabel, "0.64")
    }

    func testScoreAndSort_ignoresNonPositiveValuesWhenComputingMinMax() throws {
        let a = ModelResult(name: "a", depth: "x", iq: 100, passed: 8, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        let b = ModelResult(name: "b", depth: "x", iq: 80, passed: 6, tasks: 12, cost: 40, timeMinutes: 60, family: .codex, isReference: false)
        let broken = ModelResult(name: "broken", depth: "x", iq: 90, passed: 7, tasks: 12, cost: 0, timeMinutes: 40, family: .codex, isReference: false)

        let scored = try RadarParser.scoreAndSort([a, b, broken])

        XCTAssertEqual(scored.map(\.result.name), ["a", "b"])
        XCTAssertEqual(scored[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(scored[1].score, 0.6420846103055999, accuracy: 1e-9)
    }

    // MARK: - scoreAndSort：passed > 8 封顶，避免综合分超过 1（真实数据已出现 passed: 9）

    func testScore_passedAbove8_sameAsPassedEqual8() {
        let s8 = RadarParser.score(iq: 100, passed: 8, cost: 20, timeMinutes: 30, maxIq: 100, minCost: 20, minTime: 30)
        let s9 = RadarParser.score(iq: 100, passed: 9, cost: 20, timeMinutes: 30, maxIq: 100, minCost: 20, minTime: 30)
        XCTAssertEqual(s8, s9, accuracy: 1e-9)
    }

    func testScoreAndSort_passedAbove8_doesNotExceedFullScore() throws {
        let a = ModelResult(name: "a", depth: "x", iq: 100, passed: 9, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        let scored = try RadarParser.scoreAndSort([a])
        XCTAssertEqual(scored[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(scored[0].barFraction, 1.0, accuracy: 1e-9)
    }

    func testScoreAndSort_allInvalid_throwsEmpty() {
        let broken = ModelResult(name: "broken", depth: "x", iq: 0, passed: 7, tasks: 12, cost: 10, timeMinutes: 40, family: .codex, isReference: false)
        XCTAssertThrowsError(try RadarParser.scoreAndSort([broken])) { error in
            guard let err = error as? RadarParserError, case .empty = err else {
                return XCTFail("expected .empty, got \(error)")
            }
        }
    }

    // MARK: - 时间戳：成功 / 格式变化 / 失败

    func testParseTimestamp_success() throws {
        let json = #"{"model_iq":{"quota_radar":{"updated_at":"2026-06-24T04:58:05Z"}}}"#
        let date = try XCTUnwrap(RadarParser.parseTimestamp(json: Data(json.utf8)))
        XCTAssertEqual(date, RadarParser.parseISO("2026-06-24T04:58:05Z"))
    }

    func testParseTimestamp_withFractionalSeconds_success() {
        let json = #"{"model_iq":{"quota_radar":{"updated_at":"2026-06-24T04:58:05.123Z"}}}"#
        XCTAssertNotNil(RadarParser.parseTimestamp(json: Data(json.utf8)))
    }

    func testParseTimestamp_malformedJSON_returnsNil() {
        XCTAssertNil(RadarParser.parseTimestamp(json: Data("not json".utf8)))
    }

    func testParseTimestamp_missingField_returnsNil() {
        let json = #"{"model_iq":{"quota_radar":{}}}"#
        XCTAssertNil(RadarParser.parseTimestamp(json: Data(json.utf8)))
    }

    func testParseTimestamp_badDateFormat_returnsNil() {
        let json = #"{"model_iq":{"quota_radar":{"updated_at":"not-a-date"}}}"#
        XCTAssertNil(RadarParser.parseTimestamp(json: Data(json.utf8)))
    }

    // MARK: - current.json → Codex（主源）

    /// model_iq.latest + 任意数量 comparisons（动态 key），含 wall_seconds→分钟取整。
    private let codexJSON = """
    {
      "model_iq": {
        "latest": {
          "score": 50.0, "passed": 4, "tasks": 12,
          "wall_seconds": 1483, "model": "gpt-5.5", "reasoning_effort": "xhigh",
          "cost_usd": 41.405896
        },
        "comparisons": {
          "gpt_55_high": { "latest": {
            "score": 100.0, "passed": 8, "tasks": 12,
            "wall_seconds": 1370, "model": "gpt-5.5", "reasoning_effort": "high",
            "cost_usd": 29.331065
          }},
          "gpt_55_medium": { "latest": {
            "score": 112.5, "passed": 9, "tasks": 12,
            "wall_seconds": 1647, "model": "gpt-5.5", "reasoning_effort": "medium",
            "cost_usd": 20.136328
          }}
        },
        "quota_radar": { "updated_at": "2026-06-26T05:44:34Z" }
      }
    }
    """

    func testParseCodex_buildsLatestPlusComparisons() throws {
        let results = try RadarParser.parseCodex(json: Data(codexJSON.utf8))
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.family == .codex && !$0.isReference })

        let xhigh = try XCTUnwrap(results.first { $0.depth == "xhigh" })
        XCTAssertEqual(xhigh.name, "gpt-5.5")
        XCTAssertEqual(xhigh.iq, 50.0)
        XCTAssertEqual(xhigh.passed, 4)
        XCTAssertEqual(xhigh.tasks, 12)
        XCTAssertEqual(xhigh.cost, 41.405896, accuracy: 1e-9)
        XCTAssertEqual(xhigh.timeMinutes, 25) // 1483/60 = 24.72 → 25

        // comparisons 动态遍历，不写死 key。
        let high = try XCTUnwrap(results.first { $0.depth == "high" })
        XCTAssertEqual(high.timeMinutes, 23) // 1370/60 = 22.83 → 23
        let medium = try XCTUnwrap(results.first { $0.depth == "medium" })
        XCTAssertEqual(medium.iq, 112.5)
        XCTAssertEqual(medium.timeMinutes, 27) // 1647/60 = 27.45 → 27
    }

    func testParseCodex_noComparisons_returnsOnlyLatest() throws {
        let json = """
        {"model_iq":{"latest":{"score":50.0,"passed":4,"tasks":12,"wall_seconds":1483,"model":"gpt-5.5","reasoning_effort":"xhigh","cost_usd":41.4}}}
        """
        let results = try RadarParser.parseCodex(json: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].depth, "xhigh")
    }

    func testParseCodex_missingLatest_throwsCodexUnavailable() {
        let json = #"{"model_iq":{"quota_radar":{"updated_at":"2026-06-26T05:44:34Z"}}}"#
        XCTAssertThrowsError(try RadarParser.parseCodex(json: Data(json.utf8))) { error in
            guard let err = error as? RadarParserError, case .codexUnavailable = err else {
                return XCTFail("expected .codexUnavailable, got \(error)")
            }
        }
    }

    func testParseCodex_malformedJSON_throwsCodexUnavailable() {
        XCTAssertThrowsError(try RadarParser.parseCodex(json: Data("not json".utf8))) { error in
            guard let err = error as? RadarParserError, case .codexUnavailable = err else {
                return XCTFail("expected .codexUnavailable, got \(error)")
            }
        }
    }

    // MARK: - current.json → comparisons 单条异常容错（不应连带影响 latest 与其它 comparison）

    func testParseCodex_comparisonMissingLatestKey_skipsEntryKeepsLatestAndOthers() throws {
        let json = """
        {
          "model_iq": {
            "latest": {
              "score": 50.0, "passed": 4, "tasks": 12,
              "wall_seconds": 1483, "model": "gpt-5.5", "reasoning_effort": "xhigh",
              "cost_usd": 41.405896
            },
            "comparisons": {
              "gpt_55_high": { "latest": {
                "score": 100.0, "passed": 8, "tasks": 12,
                "wall_seconds": 1370, "model": "gpt-5.5", "reasoning_effort": "high",
                "cost_usd": 29.331065
              }},
              "gpt_new": { "label": "上游临时新增、缺 latest 字段的坏配置" }
            }
          }
        }
        """
        let results = try RadarParser.parseCodex(json: Data(json.utf8))
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.depth == "xhigh" })
        XCTAssertTrue(results.contains { $0.depth == "high" })
    }

    func testParseCodex_comparisonMissingRequiredField_skipsOnlyThatEntry() throws {
        let json = """
        {
          "model_iq": {
            "latest": {
              "score": 50.0, "passed": 4, "tasks": 12,
              "wall_seconds": 1483, "model": "gpt-5.5", "reasoning_effort": "xhigh",
              "cost_usd": 41.405896
            },
            "comparisons": {
              "gpt_55_high": { "latest": {
                "score": 100.0, "passed": 8, "tasks": 12,
                "wall_seconds": 1370, "model": "gpt-5.5", "reasoning_effort": "high"
              }}
            }
          }
        }
        """
        let results = try RadarParser.parseCodex(json: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].depth, "xhigh")
    }

    // MARK: - HTML → Claude（best-effort）

    func testParseClaude_extractsOnlyClaudeColumns() throws {
        let claude = try RadarParser.parseClaude(html: compareTableHTML())
        XCTAssertEqual(claude.count, 2)
        XCTAssertTrue(claude.allSatisfy { $0.family == .claude && $0.isReference })
        XCTAssertTrue(claude.allSatisfy { $0.name == "opus-4.8" })
        XCTAssertFalse(claude.contains { $0.name.hasPrefix("gpt-") })
    }

    func testParseClaude_tableNotFound_throws() {
        XCTAssertThrowsError(try RadarParser.parseClaude(html: "<div>no table here</div>"))
    }

    // MARK: - scoreAndSort：按 family 各自归一化

    func testScoreAndSort_normalizesPerFamilyIndependently() throws {
        // Codex 组 maxIq=100；Claude 组只有 1 个且 iq=50，按本组归一应得满分（不被 Codex 的 100 拖低）。
        let codexA = ModelResult(name: "ca", depth: "x", iq: 100, passed: 8, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        let codexB = ModelResult(name: "cb", depth: "x", iq: 80, passed: 6, tasks: 12, cost: 40, timeMinutes: 60, family: .codex, isReference: false)
        let claude = ModelResult(name: "opus-4.8", depth: "high", iq: 50, passed: 8, tasks: 12, cost: 99, timeMinutes: 99, family: .claude, isReference: true)

        let scored = try RadarParser.scoreAndSort([codexA, codexB, claude])
        XCTAssertEqual(scored.count, 3)

        let c = try XCTUnwrap(scored.first { $0.result.family == .claude })
        XCTAssertEqual(c.score, 1.0, accuracy: 1e-9) // 组内唯一：各归一项=1，passed=8 → 1.0

        let a = try XCTUnwrap(scored.first { $0.result.name == "ca" })
        XCTAssertEqual(a.score, 1.0, accuracy: 1e-9)
        let b = try XCTUnwrap(scored.first { $0.result.name == "cb" })
        XCTAssertEqual(b.score, 0.6420846103055999, accuracy: 1e-9) // 与跨族归一前一致
    }

    func testScoreAndSort_emptyClaudeGroup_stillScoresCodex() throws {
        let codexA = ModelResult(name: "a", depth: "x", iq: 100, passed: 8, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        let scored = try RadarParser.scoreAndSort([codexA])
        XCTAssertEqual(scored.count, 1)
        XCTAssertEqual(scored[0].score, 1.0, accuracy: 1e-9)
    }
}
