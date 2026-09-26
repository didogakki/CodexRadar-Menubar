// 覆盖 RadarParser：current.json / claude-code-radar.json 解析的正常/异常路径 + 综合分公式 + 时间戳解码。
import XCTest
@testable import CodexRadar

final class RadarParserTests: XCTestCase {

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

    // MARK: - claude-code-radar.json → Claude（best-effort）

    /// iq.models[] 每个模型带历史序列数组，尾部可能为 null；time 单位为小时。
    private let claudeJSON = """
    {
      "iq": {
        "models": [
          {
            "key": "m8",
            "name": "Opus 4.8 xhigh",
            "score": 75,
            "iq": [80.0, 87.5, null],
            "pass": [6, 7, null],
            "valid": [12, 12, null],
            "cost": [100.0, 115.1, null],
            "time": [5.0, 6.4, null],
            "latest_at": "2026-07-09T10:07:39+08:00"
          },
          {
            "name": "Haiku 4.5",
            "iq": [50.0],
            "pass": [4],
            "valid": [12],
            "cost": [8.2],
            "time": [1.5]
          }
        ]
      }
    }
    """

    func testParseClaude_takesLatestNonNullAndConvertsHoursToMinutes() throws {
        let results = try RadarParser.parseClaude(json: Data(claudeJSON.utf8))
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.family == .claude && $0.isReference })

        let opus = try XCTUnwrap(results.first { $0.name == "opus-4.8" })
        XCTAssertEqual(opus.depth, "xhigh")
        XCTAssertEqual(opus.iq, 87.5)          // 跳过尾部 null，取最后一个非 null
        XCTAssertEqual(opus.passed, 7)
        XCTAssertEqual(opus.tasks, 12)          // valid 作为分母
        XCTAssertEqual(opus.cost, 115.1, accuracy: 1e-9)
        XCTAssertEqual(opus.timeMinutes, 384)   // 6.4h → 384 分钟

        let haiku = try XCTUnwrap(results.first { $0.name == "haiku-4.5" })
        XCTAssertEqual(haiku.depth, "")         // 无思考档后缀
        XCTAssertEqual(haiku.timeMinutes, 90)   // 1.5h
    }

    func testParseClaude_labelVariants_parseNameAndDepth() throws {
        let json = """
        {"iq":{"models":[
          {"name":"Sonnet 5 max","iq":[70],"pass":[6],"valid":[12],"cost":[20],"time":[2]},
          {"name":"Fable 5 high","iq":[90],"pass":[8],"valid":[12],"cost":[30],"time":[3]}
        ]}}
        """
        let results = try RadarParser.parseClaude(json: Data(json.utf8))
        XCTAssertEqual(results.count, 2)
        let sonnet = try XCTUnwrap(results.first { $0.name == "sonnet-5" })
        XCTAssertEqual(sonnet.depth, "max")
        let fable = try XCTUnwrap(results.first { $0.name == "fable-5" })
        XCTAssertEqual(fable.depth, "high")
    }

    func testParseClaude_legacyLabelField_stillDecodes() throws {
        let json = """
        {"iq":{"models":[
          {"label":"Opus 4.8 xhigh","iq":[87.5],"pass":[7],"valid":[12],"cost":[115.1],"time":[6.4]}
        ]}}
        """
        let results = try RadarParser.parseClaude(json: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "opus-4.8")
        XCTAssertEqual(results[0].depth, "xhigh")
    }

    func testParseClaude_skipsModelWithMissingOrInvalidValues() throws {
        let json = """
        {"iq":{"models":[
          {"name":"Opus 4.8 xhigh","iq":[87.5],"pass":[7],"valid":[12],"cost":[115.1],"time":[6.4]},
          {"name":"Broken A","iq":[null],"pass":[7],"valid":[12],"cost":[10],"time":[2]},
          {"name":"Broken B","iq":[80],"pass":[7],"valid":[12],"cost":[0],"time":[2]}
        ]}}
        """
        let results = try RadarParser.parseClaude(json: Data(json.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "opus-4.8")
    }

    func testParseClaude_malformedJSON_throwsClaudeUnavailable() {
        XCTAssertThrowsError(try RadarParser.parseClaude(json: Data("not json".utf8))) { error in
            guard let err = error as? RadarParserError, case .claudeUnavailable = err else {
                return XCTFail("expected .claudeUnavailable, got \(error)")
            }
        }
    }

    func testParseClaude_emptyModels_throwsClaudeUnavailable() {
        let json = #"{"iq":{"models":[]}}"#
        XCTAssertThrowsError(try RadarParser.parseClaude(json: Data(json.utf8))) { error in
            guard let err = error as? RadarParserError, case .claudeUnavailable = err else {
                return XCTFail("expected .claudeUnavailable, got \(error)")
            }
        }
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

    // MARK: - radar-insights → 站长推荐

    private let insightsJSON = """
    {
      "schema": 1,
      "source_updated_at": "2026-07-26T10:00:00Z",
      "recommendations": [
        {
          "key": "daily_development",
          "title": "日常开发",
          "rule": "iq>=85 && cheap",
          "items": [
            {"model": "gpt-5.5", "effort": "medium", "iq": 87.0, "passed": 7, "samples": 12,
             "average_cost_usd": 23.9, "average_duration_minutes": 85.0,
             "combined_cost_index": 0.27, "rule": "value", "trend_48h": "up"}
          ]
        },
        {
          "key": "hard_tasks",
          "title": "攻坚难题",
          "items": [
            {"model": "gpt-5.4", "effort": "xhigh", "iq": 101.0}
          ]
        }
      ]
    }
    """

    func testParseInsights_keepsServerOrderAndFields() throws {
        let groups = try RadarParser.parseInsights(json: Data(insightsJSON.utf8))
        XCTAssertEqual(groups.map(\.key), ["daily_development", "hard_tasks"])
        XCTAssertEqual(groups.map(\.title), ["日常开发", "攻坚难题"])
        XCTAssertEqual(groups[0].rule, "iq>=85 && cheap")

        let item = try XCTUnwrap(groups[0].items.first)
        XCTAssertEqual(item.model, "gpt-5.5")
        XCTAssertEqual(item.effort, "medium")
        XCTAssertEqual(item.iq, 87.0)
        XCTAssertEqual(item.passed, 7)
        XCTAssertEqual(item.samples, 12)
        XCTAssertEqual(try XCTUnwrap(item.averageCostUSD), 23.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(item.averageDurationMinutes), 85.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(item.combinedCostIndex), 0.27, accuracy: 1e-9)
        XCTAssertEqual(item.trend48h, "up")

        // 可选字段缺失的条目也能解析
        XCTAssertEqual(groups[1].items.first?.model, "gpt-5.4")
        XCTAssertNil(groups[1].items.first?.combinedCostIndex)
    }

    func testParseInsights_fractionalPassedFromRollingAggregation_keepsRecommendation() throws {
        let json = """
        {"schema": 1, "recommendations": [
          {"key": "daily_development", "title": "日常开发", "items": [
            {"model": "gpt-5.6-sol", "effort": "medium", "iq": 90.37,
             "passed": 51.20978228625188, "samples": 85.0}
          ]}
        ]}
        """
        let groups = try RadarParser.parseInsights(json: Data(json.utf8))
        let item = try XCTUnwrap(groups.first?.items.first)
        XCTAssertEqual(item.id, "gpt-5.6-sol/medium")
        XCTAssertEqual(item.passed, 51)
        XCTAssertEqual(item.samples, 85)
    }

    func testParseInsights_wrongSchema_throws() {
        let json = #"{"schema": 2, "recommendations": [{"key":"k","title":"t","items":[{"model":"m","effort":"e","iq":90}]}]}"#
        XCTAssertThrowsError(try RadarParser.parseInsights(json: Data(json.utf8))) { error in
            guard let err = error as? RadarParserError, case .insightsUnavailable = err else {
                return XCTFail("expected .insightsUnavailable, got \(error)")
            }
        }
    }

    func testParseInsights_emptyRecommendations_throws() {
        let json = #"{"schema": 1, "recommendations": []}"#
        XCTAssertThrowsError(try RadarParser.parseInsights(json: Data(json.utf8)))
    }

    func testParseInsights_badItemSkipped_groupWithOnlyBadItemsDropped() throws {
        let json = """
        {"schema": 1, "recommendations": [
          {"key": "a", "title": "A", "items": [
            {"model": "gpt-5.5", "effort": "high", "iq": 93},
            {"effort": "缺 model 字段的坏条目", "iq": 90},
            {"model": "gpt-x", "effort": "low", "iq": 0}
          ]},
          {"key": "b", "title": "B", "items": [{"iq": 50}]}
        ]}
        """
        let groups = try RadarParser.parseInsights(json: Data(json.utf8))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, "a")
        XCTAssertEqual(groups[0].items.map(\.id), ["gpt-5.5/high"])
    }

    func testParseInsightsTimestamp() {
        XCTAssertEqual(
            RadarParser.parseInsightsTimestamp(json: Data(insightsJSON.utf8)),
            RadarParser.parseISO("2026-07-26T10:00:00Z")
        )
        XCTAssertNil(RadarParser.parseInsightsTimestamp(json: Data("not json".utf8)))
    }

    // MARK: - intelligence-efficiency.json → 智力效率

    private let efficiencyJSON = """
    {
      "schema": 2,
      "source_updated_at": "2026-07-26T09:00:00Z",
      "points": [
        {"model": "gpt-5.5", "effort": "medium", "iq": 87.0, "passed": 7, "valid_tasks": 12,
         "average_price_usd": 23.9, "average_minutes": 85.0, "combined_cost_index": 0.27},
        {"model": "gpt-5.4", "effort": "xhigh", "iq": 101.0, "passed": 8, "valid_tasks": 12,
         "average_price_usd": 23.4, "average_minutes": 246.0, "combined_cost_index": 0.23},
        {"model": "broken", "effort": "x", "iq": 0},
        {"effort": "缺 model"}
      ]
    }
    """

    func testParseEfficiency_integerValuedJSONDoubles_keepPoints() throws {
        let json = """
        {"schema": 2, "points": [
          {"model": "gpt-5.6-sol", "effort": "medium", "iq": 87.95,
           "passed": 197.0, "valid_tasks": 336.0,
           "average_price_usd": 3.471393, "average_minutes": 17.24,
           "combined_cost_index": 0.4319}
        ]}
        """
        let points = try RadarParser.parseEfficiency(json: Data(json.utf8))
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point.id, "gpt-5.6-sol/medium")
        XCTAssertEqual(point.passed, 197)
        XCTAssertEqual(point.validTasks, 336)
    }

    func testParseEfficiency_fieldsAndInvalidFiltering() throws {
        let points = try RadarParser.parseEfficiency(json: Data(efficiencyJSON.utf8))
        XCTAssertEqual(points.map(\.id), ["gpt-5.5/medium", "gpt-5.4/xhigh"])
        let p = points[0]
        XCTAssertEqual(p.iq, 87.0)
        XCTAssertEqual(p.passed, 7)
        XCTAssertEqual(p.validTasks, 12)
        XCTAssertEqual(try XCTUnwrap(p.averagePriceUSD), 23.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p.averageMinutes), 85.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(p.combinedCostIndex), 0.27, accuracy: 1e-9)
    }

    func testParseEfficiency_wrongSchema_throws() {
        let json = #"{"schema": 1, "points": [{"model":"m","effort":"e","iq":90}]}"#
        XCTAssertThrowsError(try RadarParser.parseEfficiency(json: Data(json.utf8))) { error in
            guard let err = error as? RadarParserError, case .efficiencyUnavailable = err else {
                return XCTFail("expected .efficiencyUnavailable, got \(error)")
            }
        }
    }

    func testParseEfficiency_emptyOrAllInvalid_throws() {
        XCTAssertThrowsError(try RadarParser.parseEfficiency(json: Data(#"{"schema":2,"points":[]}"#.utf8)))
        XCTAssertThrowsError(try RadarParser.parseEfficiency(json: Data(#"{"schema":2,"points":[{"model":"m","effort":"e","iq":0}]}"#.utf8)))
    }

    func testParseEfficiencyTimestamp() {
        XCTAssertEqual(
            RadarParser.parseEfficiencyTimestamp(json: Data(efficiencyJSON.utf8)),
            RadarParser.parseISO("2026-07-26T09:00:00Z")
        )
    }

    func testParseEfficiency_schema3UsesTotalAsValidTasks() throws {
        let json = """
        {"schema":3,"source_updated_at":"2026-08-29T07:55:22Z","points":[
          {"model":"gpt-5.6-sol","effort":"medium","iq":95.09,"passed":204,"total":336,
           "average_price_usd":3.105691,"average_minutes":16.77,"combined_cost_index":1505.18}
        ]}
        """
        let points = try RadarParser.parseEfficiency(json: Data(json.utf8))
        XCTAssertEqual(points.first?.validTasks, 336)
        XCTAssertEqual(points.first?.averageMinutes, 16.77)
    }

    func testSupplementDailyDevelopment_matchesWebsiteAndPicksSolMedium() {
        let comprehensive = [
            ComprehensivePoint(model: "gpt-5.6-sol", effort: "low", iq: 83.65),
            ComprehensivePoint(model: "gpt-5.6-sol", effort: "medium", iq: 92.44),
            ComprehensivePoint(model: "gpt-5.6-sol", effort: "ultra", iq: 102.92),
            ComprehensivePoint(model: "gpt-5.5", effort: "high", iq: 92.37),
        ]
        let efficiency = [
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "low", iq: 80.8, passed: 181, validTasks: 336,
                            averagePriceUSD: 1.80, averageMinutes: 10.86, combinedCostIndex: 232.2),
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "medium", iq: 95.09, passed: 204, validTasks: 336,
                            averagePriceUSD: 3.11, averageMinutes: 16.77, combinedCostIndex: 1505.18),
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "ultra", iq: 100.89, passed: 226, validTasks: 336,
                            averagePriceUSD: 24.69, averageMinutes: 51.96, combinedCostIndex: 378162.86),
            EfficiencyPoint(model: "gpt-5.5", effort: "high", iq: 91.07, passed: 204, validTasks: 336,
                            averagePriceUSD: 3.69, averageMinutes: 16.98, combinedCostIndex: 1856.19),
        ]
        let hardOnly = [
            InsightGroup(key: "hard_problems", title: "难题攻坚", rule: nil, items: [
                InsightItem(model: "gpt-5.6-sol", effort: "ultra", iq: 102.92, passed: nil, samples: nil,
                            averageCostUSD: 24.69, averageDurationMinutes: 51.96,
                            combinedCostIndex: 378162.86, rule: nil, trend48h: nil),
            ]),
        ]

        let supplemented = RadarParser.supplementDailyDevelopment(
            insights: hardOnly,
            comprehensive: comprehensive,
            efficiency: efficiency
        )
        XCTAssertEqual(supplemented.first?.key, "daily_development")
        XCTAssertEqual(supplemented.first?.items.map(\.id), ["gpt-5.6-sol/medium", "gpt-5.5/high"])

        let codex = RadarParser.buildCodexFromEfficiency(points: efficiency, insights: supplemented)
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), insights: supplemented, codexSource: .website)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.6-sol/medium")
    }

    // MARK: - supplementHardProblems（接口 rule：有实测数据的档位中按 IQ 从高到低取 2 个）

    /// 复刻线上 2026-09-06 的真实返回：hard_problems 返回空数组（会被 parseInsights 过滤掉），
    /// 补算后应取综合 IQ 最高的两档 sol/ultra + sol/max，并插在日常开发之后、保持服务端固有顺序。
    func testSupplementHardProblems_picksTopTwoByIQAndKeepsServerOrder() {
        let comprehensive = [
            ComprehensivePoint(model: "gpt-5.6-sol", effort: "medium", iq: 93.86),
            ComprehensivePoint(model: "gpt-5.6-sol", effort: "max", iq: 104.40),
            ComprehensivePoint(model: "gpt-5.6-sol", effort: "ultra", iq: 105.07),
            ComprehensivePoint(model: "gpt-5.6-terra", effort: "ultra", iq: 99.96),
        ]
        let efficiency = [
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "medium", iq: 94.2, passed: 211, validTasks: 336,
                            averagePriceUSD: 2.94, averageMinutes: 16.09, combinedCostIndex: 1255.31),
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "max", iq: 106.7, passed: 239, validTasks: 336,
                            averagePriceUSD: 7.97, averageMinutes: 33.92, combinedCostIndex: 33190.10),
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "ultra", iq: 100.89, passed: 226, validTasks: 336,
                            averagePriceUSD: 24.46, averageMinutes: 53.03, combinedCostIndex: 398662.56),
            EfficiencyPoint(model: "gpt-5.6-terra", effort: "ultra", iq: 100.0, passed: 224, validTasks: 336,
                            averagePriceUSD: 9.84, averageMinutes: 42.10, combinedCostIndex: 79263.88),
        ]
        // 服务端实际返回：daily/hard 为空被过滤，只剩后台自动化与跑龙虾
        let serverGroups = [
            InsightGroup(key: "background_automation", title: "后台自动化", rule: nil, items: [
                InsightItem(model: "gpt-5.6-luna", effort: "high", iq: 80.02, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil,
                            combinedCostIndex: nil, rule: nil, trend48h: nil),
            ]),
        ]

        let daily = RadarParser.supplementDailyDevelopment(
            insights: serverGroups, comprehensive: comprehensive, efficiency: efficiency)
        let supplemented = RadarParser.supplementHardProblems(
            insights: daily, comprehensive: comprehensive, efficiency: efficiency)

        XCTAssertEqual(supplemented.map(\.key), ["daily_development", "hard_problems", "background_automation"])
        let hard = supplemented.first { $0.key == "hard_problems" }
        XCTAssertEqual(hard?.title, "难题攻坚")
        // 综合 IQ 最高的两档；注意排序依据是 comprehensive_points 的综合 IQ（ultra 105.07 > max 104.40），
        // 不是 efficiency 的单点 IQ（那里 max 106.7 反而更高）。
        XCTAssertEqual(hard?.items.map(\.id), ["gpt-5.6-sol/ultra", "gpt-5.6-sol/max"])

        // 补算结果要真的落到榜单行上，变成「难题攻坚」推荐标记。
        let codex = RadarParser.buildCodexFromEfficiency(points: efficiency, insights: supplemented)
        XCTAssertEqual(codex.first { $0.id == "gpt-5.6-sol/ultra" }?.recommendedIn, ["难题攻坚"])
        // 各分组规则独立、候选池不互斥：sol/max 同时满足日常开发（IQ≥90 且够快）与难题攻坚，
        // 两个标记都要保留（服务端也是这个语义）。
        XCTAssertEqual(codex.first { $0.id == "gpt-5.6-sol/max" }?.recommendedIn, ["日常开发", "难题攻坚"])
    }

    /// 服务端自己给出 hard_problems 条目时不得被补算覆盖或重排。
    func testSupplementHardProblems_keepsServerProvidedItems() {
        let serverItem = InsightItem(model: "gpt-5.5", effort: "high", iq: 92.37, passed: nil, samples: nil,
                                     averageCostUSD: nil, averageDurationMinutes: nil,
                                     combinedCostIndex: nil, rule: nil, trend48h: nil)
        let groups = [InsightGroup(key: "hard_problems", title: "难题攻坚", rule: nil, items: [serverItem])]
        let comprehensive = [ComprehensivePoint(model: "gpt-5.6-sol", effort: "ultra", iq: 105.07)]
        let efficiency = [
            EfficiencyPoint(model: "gpt-5.6-sol", effort: "ultra", iq: 100.89, passed: 226, validTasks: 336,
                            averagePriceUSD: 24.46, averageMinutes: 53.03, combinedCostIndex: 398662.56),
        ]

        let supplemented = RadarParser.supplementHardProblems(
            insights: groups, comprehensive: comprehensive, efficiency: efficiency)

        // 服务端条目排第一，补算只负责把不足 2 条补齐
        XCTAssertEqual(supplemented.first { $0.key == "hard_problems" }?.items.map(\.id),
                       ["gpt-5.5/high", "gpt-5.6-sol/ultra"])
    }

    // MARK: - buildCodexFromEfficiency：推荐优先 + 剩余按 IQ 降序 + 成本指数不参与能力排序

    private func effPoint(_ model: String, _ effort: String, iq: Double, costIndex: Double? = nil) -> EfficiencyPoint {
        EfficiencyPoint(model: model, effort: effort, iq: iq, passed: 7, validTasks: 12,
                        averagePriceUSD: 20, averageMinutes: 60, combinedCostIndex: costIndex)
    }

    func testBuildCodex_pureIQDescending_recommendationsTaggedNotHoisted() {
        // cheap 的 costIndex 最低（最省）但 IQ 也最低：绝不能因 combined_cost_index 升序被排到最前。
        let points = [
            effPoint("gpt-5.5", "medium", iq: 87, costIndex: 0.27),
            effPoint("gpt-cheap", "low", iq: 60, costIndex: 0.01),
            effPoint("gpt-5.4", "xhigh", iq: 101, costIndex: 0.23),
            effPoint("gpt-5.5", "high", iq: 93, costIndex: 0.32),
        ]
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "gpt-5.5", effort: "medium", iq: 87, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: 0.27, rule: nil, trend48h: nil),
            ]),
            InsightGroup(key: "hard_tasks", title: "攻坚难题", rule: nil, items: [
                InsightItem(model: "gpt-5.4", effort: "xhigh", iq: 101, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: 0.23, rule: nil, trend48h: nil),
            ]),
        ]
        let codex = RadarParser.buildCodexFromEfficiency(points: points, insights: insights)

        // 一律按 IQ 降序：推荐项不再置顶（结论交给场景推荐区），低 IQ 廉价档仍排最后。
        XCTAssertEqual(codex.map(\.id), ["gpt-5.4/xhigh", "gpt-5.5/high", "gpt-5.5/medium", "gpt-cheap/low"])
        // 推荐标记照常写入，只是不影响顺序
        XCTAssertEqual(codex[0].recommendedIn, ["攻坚难题"])
        XCTAssertEqual(codex[1].recommendedIn, [])
        XCTAssertEqual(codex[2].recommendedIn, ["日常开发"])
        // 展示字段来自 efficiency 网站数据
        XCTAssertEqual(codex[2].iq, 87)
        XCTAssertEqual(try XCTUnwrap(codex[2].costIndex), 0.27, accuracy: 1e-9)
        // score 为 IQ 视觉比例（iq/maxIq），不是自创综合分
        XCTAssertEqual(codex[0].score, 1.0, accuracy: 1e-9)
        XCTAssertEqual(codex[2].score, 87.0 / 101.0, accuracy: 1e-9)
    }

    func testBuildCodex_recommendationNotMatchingAnyPoint_isSkipped() {
        let points = [effPoint("gpt-5.5", "medium", iq: 87)]
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "gpt-unknown", effort: "high", iq: 90, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil, rule: nil, trend48h: nil),
            ]),
        ]
        let codex = RadarParser.buildCodexFromEfficiency(points: points, insights: insights)
        XCTAssertEqual(codex.map(\.id), ["gpt-5.5/medium"])
        XCTAssertEqual(codex[0].recommendedIn, [])
    }

    // MARK: - buildClaudeByIQ：按源 IQ 降序，非权威推荐

    func testBuildClaudeByIQ_sortsByIQDesc() {
        let models = [
            ModelResult(name: "opus-4.8", depth: "max", iq: 99, passed: 6, tasks: 12, cost: 115, timeMinutes: 384, family: .claude, isReference: true),
            ModelResult(name: "opus-4.8", depth: "high", iq: 108, passed: 8, tasks: 12, cost: 63, timeMinutes: 210, family: .claude, isReference: true),
            ModelResult(name: "broken", depth: "", iq: 0, passed: 0, tasks: 0, cost: 0, timeMinutes: 0, family: .claude, isReference: true),
        ]
        let claude = RadarParser.buildClaudeByIQ(models)
        XCTAssertEqual(claude.map(\.id), ["opus-4.8/high", "opus-4.8/max"])
        XCTAssertEqual(claude[0].score, 1.0, accuracy: 1e-9)
    }

    // MARK: - 菜单栏：daily_development 第一项优先，回退本地冠军

    func testMenuBarBest_followsDailyDevelopmentFirstItem() {
        let points = [effPoint("gpt-5.4", "xhigh", iq: 101), effPoint("gpt-5.5", "medium", iq: 87)]
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "gpt-5.5", effort: "medium", iq: 87, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil, rule: nil, trend48h: nil),
            ]),
        ]
        let codex = RadarParser.buildCodexFromEfficiency(points: points, insights: insights)
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), insights: insights, codexSource: .website)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
    }

    func testMenuBarBest_dailyDevelopmentGPTBeatsFirstGPTCandidate() {
        let first = ScoredModel(
            result: ModelResult(name: "gpt-5.4", depth: "xhigh", iq: 101, passed: 8, tasks: 12,
                                cost: 23.4, timeMinutes: 246, family: .codex, isReference: false),
            score: 1
        )
        let dailyGPT = ScoredModel(
            result: ModelResult(name: "gpt-5.5", depth: "medium", iq: 87, passed: 7, tasks: 12,
                                cost: 23.9, timeMinutes: 85, family: .codex, isReference: false),
            score: 0.86
        )
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "gpt-5.5", effort: "medium", iq: 87, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil,
                            rule: nil, trend48h: nil),
            ]),
        ]
        let snapshot = RadarSnapshot(
            all: [first, dailyGPT],
            updatedAt: Date(),
            insights: insights,
            codexSource: .website
        )

        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
    }

    func testMenuBarBest_dailyDevelopmentSkipsNonGPTAndUsesFirstMatchingGPT() {
        let nonGPT = ModelResult(name: "codex-mini", depth: "high", iq: 110, passed: 9, tasks: 12, cost: 8, timeMinutes: 40, family: .codex, isReference: false)
        let points = [effPoint("gpt-5.5", "medium", iq: 87)]
        var codex = RadarParser.buildCodexFromEfficiency(points: points, insights: [])
        codex.insert(ScoredModel(result: nonGPT, score: 1), at: 0)
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "codex-mini", effort: "high", iq: 110, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil, rule: nil, trend48h: nil),
                InsightItem(model: "gpt-5.5", effort: "medium", iq: 87, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil, rule: nil, trend48h: nil),
            ]),
        ]
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), insights: insights, codexSource: .website)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
    }

    func testMenuBarBest_dailyDevelopmentMatchFails_fallsBackToFirstGPT() {
        let points = [effPoint("gpt-5.4", "xhigh", iq: 101)]
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "gpt-unknown", effort: "high", iq: 90, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil, rule: nil, trend48h: nil),
            ]),
        ]
        let codex = RadarParser.buildCodexFromEfficiency(points: points, insights: insights)
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), insights: insights, codexSource: .website)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.4/xhigh")
    }

    func testMenuBarBest_noInsights_fallsBackToFirstGPT() {
        let raw = ModelResult(name: "gpt-5.5", depth: "high", iq: 93, passed: 7, tasks: 12, cost: 29, timeMinutes: 107, family: .codex, isReference: false)
        let scored = (try? RadarParser.scoreAndSort([raw])) ?? []
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date(), codexSource: .localEstimate)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/high")
    }

    func testMenuBarBest_noInsights_localBestIDMatches_beatsFirstWebsiteItem() {
        let points = [effPoint("gpt-5.4", "xhigh", iq: 101), effPoint("gpt-5.5", "medium", iq: 87)]
        let codex = RadarParser.buildCodexFromEfficiency(points: points, insights: [])
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), codexSource: .website, localBestID: "gpt-5.5/medium")
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
    }

    func testMenuBarBest_nonGPTLocalChampionFallsBackToFirstGPT() {
        let nonGPT = ModelResult(name: "codex-mini", depth: "high", iq: 110, passed: 9, tasks: 12, cost: 8, timeMinutes: 40, family: .codex, isReference: false)
        let points = [effPoint("gpt-5.4", "xhigh", iq: 101)]
        var codex = RadarParser.buildCodexFromEfficiency(points: points, insights: [])
        codex.insert(ScoredModel(result: nonGPT, score: 1), at: 0)
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), codexSource: .website, localBestID: "codex-mini/high")
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.4/xhigh")
    }

    func testMenuBarBest_noGPTCandidate_returnsNil() {
        let nonGPT = ModelResult(name: "codex-mini", depth: "high", iq: 110, passed: 9, tasks: 12, cost: 8, timeMinutes: 40, family: .codex, isReference: false)
        let snapshot = RadarSnapshot(all: [ScoredModel(result: nonGPT, score: 1)], updatedAt: Date())
        XCTAssertNil(snapshot.menuBarBest)
    }

    func testMenuBarBest_localBestIDNotInList_fallsBackToFirstGPT() {
        let points = [effPoint("gpt-5.4", "xhigh", iq: 101)]
        let codex = RadarParser.buildCodexFromEfficiency(points: points, insights: [])
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), codexSource: .website, localBestID: "gpt-gone/low")
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.4/xhigh")
    }

    // MARK: - 厂商分组：按模型名前缀/关键字派生，未知归入"其他"，不丢弃模型；Anthropic/Claude 竞品条目单独识别（不归类）

    func testModelVendor_derivesFromKnownPrefixes() {
        XCTAssertEqual(ModelVendor.from(modelName: "gpt-6-astra"), .openai)
        XCTAssertEqual(ModelVendor.from(modelName: "gpt-5.6-sol"), .openai)
        XCTAssertEqual(ModelVendor.from(modelName: "grok-4.6"), .xai)
        XCTAssertEqual(ModelVendor.from(modelName: "deepseek"), .deepseek)
        XCTAssertEqual(ModelVendor.from(modelName: "deepseek-v3"), .deepseek)
        XCTAssertEqual(ModelVendor.from(modelName: "dsh-deepseek-v4"), .deepseek)
        XCTAssertEqual(ModelVendor.from(modelName: "gemini-2.5-pro"), .google)
        XCTAssertEqual(ModelVendor.from(modelName: "google-gemini-flash"), .google)
        XCTAssertEqual(ModelVendor.from(modelName: "glm-4.6"), .zhipu)
        XCTAssertEqual(ModelVendor.from(modelName: "zhipu-glm-4"), .zhipu)
        XCTAssertEqual(ModelVendor.from(modelName: "moonshot-v1"), .moonshot)
        XCTAssertEqual(ModelVendor.from(modelName: "kimi-k2"), .moonshot)
        XCTAssertEqual(ModelVendor.from(modelName: "hunyuan-turbo"), .tencent)
        XCTAssertEqual(ModelVendor.from(modelName: "tencent-hunyuan"), .tencent)
        XCTAssertEqual(ModelVendor.from(modelName: "mystery-model"), .other)
    }

    func testModelVendor_caseInsensitive() {
        XCTAssertEqual(ModelVendor.from(modelName: "GPT-5.5"), .openai)
        XCTAssertEqual(ModelVendor.from(modelName: "Grok-4.6"), .xai)
        XCTAssertEqual(ModelVendor.from(modelName: "GLM-4.6"), .zhipu)
    }

    func testModelVendor_isAnthropicCompetitor_matchesClaudePrefixCaseInsensitive() {
        XCTAssertTrue(ModelVendor.isAnthropicCompetitor(modelName: "claude-opus-4.8"))
        XCTAssertTrue(ModelVendor.isAnthropicCompetitor(modelName: "Claude-Sonnet-4.6"))
        XCTAssertFalse(ModelVendor.isAnthropicCompetitor(modelName: "gpt-5.5"))
        XCTAssertFalse(ModelVendor.isAnthropicCompetitor(modelName: "mystery-model"))
    }

    func testCodexGroupsByVendor_showsOnlyWhitelistedVendorsInFixedOrder() throws {
        let models = [
            ModelResult(name: "gpt-6-astra", depth: "high", iq: 100, passed: 8, tasks: 20, cost: 20, timeMinutes: 30, family: .codex, isReference: false),
            ModelResult(name: "grok-4.6", depth: "high", iq: 95, passed: 7, tasks: 20, cost: 18, timeMinutes: 25, family: .codex, isReference: false),
            ModelResult(name: "deepseek-v3", depth: "medium", iq: 90, passed: 6, tasks: 20, cost: 5, timeMinutes: 40, family: .codex, isReference: false),
            ModelResult(name: "claude-opus-4.8", depth: "high", iq: 105, passed: 8, tasks: 20, cost: 60, timeMinutes: 200, family: .codex, isReference: false),
            ModelResult(name: "mystery-model", depth: "high", iq: 80, passed: 5, tasks: 20, cost: 10, timeMinutes: 50, family: .codex, isReference: false),
            ModelResult(name: "gpt-5.6-sol", depth: "medium", iq: 88, passed: 6, tasks: 20, cost: 12, timeMinutes: 35, family: .codex, isReference: false),
        ]
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        let groups = snapshot.codexGroupsByVendor

        // 只展示白名单厂商（OpenAI/Grok/DeepSeek），且顺序固定；Anthropic 竞品与"其他"一律隐藏，
        // 但 snapshot.all/codexGroup 等权威数据不受影响（见下方 displayedIDs 之外的断言）。
        XCTAssertEqual(groups.map(\.vendor), [.openai, .xai, .deepseek])
        let displayedIDs = Set(groups.flatMap { $0.models.map(\.id) })
        for hiddenName in ["claude-opus-4.8", "mystery-model"] {
            let id = try XCTUnwrap(scored.first { $0.result.name == hiddenName }?.id)
            XCTAssertFalse(displayedIDs.contains(id))
        }
        XCTAssertEqual(Set(scored.map(\.result.name)), Set(["gpt-6-astra", "grok-4.6", "deepseek-v3", "claude-opus-4.8", "mystery-model", "gpt-5.6-sol"]))

        let openaiGroup = groups.first { $0.vendor == .openai }?.models ?? []
        XCTAssertEqual(
            openaiGroup.map(\.result.name),
            scored.filter { $0.result.name.hasPrefix("gpt-") }.map(\.result.name)
        )
    }

    func testCodexGroupsByVendor_emptyVendorsAreSkipped() throws {
        let models = [ModelResult(name: "gpt-5.5", depth: "high", iq: 90, passed: 7, tasks: 12, cost: 20, timeMinutes: 40, family: .codex, isReference: false)]
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        XCTAssertEqual(snapshot.codexGroupsByVendor.map(\.vendor), [.openai])
    }

    func testCodexGroupsByVendor_orderFollowsDisplayWhitelist_regardlessOfInsertionOrder() throws {
        // DeepSeek 排在 OpenAI 之前插入，展示顺序仍应固定为白名单顺序 OpenAI → DeepSeek。
        let models = [
            ModelResult(name: "deepseek-v4", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 5, timeMinutes: 40, family: .codex, isReference: false),
            ModelResult(name: "gpt-5.5", depth: "high", iq: 95, passed: 7, tasks: 20, cost: 20, timeMinutes: 30, family: .codex, isReference: false),
        ]
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        XCTAssertEqual(snapshot.codexGroupsByVendor.map(\.vendor), [.openai, .deepseek])
        XCTAssertEqual(ModelVendor.displayWhitelist, [.openai, .xai, .deepseek])
    }

    // MARK: - Claude Code 展示投影：剔除 fable-*（内部代号），不影响 claudeGroup 权威数据

    func testClaudeDisplayGroup_hidesFableSeries_keepsClaudeGroupIntact() {
        let results = [
            ModelResult(name: "opus-4.8", depth: "high", iq: 95, passed: 8, tasks: 12, cost: 60, timeMinutes: 200, family: .claude, isReference: true),
            ModelResult(name: "fable-5", depth: "high", iq: 99, passed: 8, tasks: 12, cost: 10, timeMinutes: 20, family: .claude, isReference: true),
        ]
        let claude = RadarParser.buildClaudeByIQ(results)
        let snapshot = RadarSnapshot(all: claude, updatedAt: Date())

        XCTAssertEqual(Set(snapshot.claudeGroup.map(\.result.name)), Set(["opus-4.8", "fable-5"]))
        XCTAssertEqual(snapshot.claudeDisplayGroup.map(\.result.name), ["opus-4.8"])
    }

    // MARK: - Anthropic 竞品条目并入 Claude Code 分区（雷达为主源，只补缺失档位）

    private func anthropicRow(_ name: String, _ depth: String, iq: Double) -> ScoredModel {
        ScoredModel(result: ModelResult(name: name, depth: depth, iq: iq, passed: 2, tasks: 3,
                                        cost: 1.7, timeMinutes: 11,
                                        family: .codex, isReference: false),
                    score: 0.5, costIndex: 214.7)
    }

    func testMergeAnthropicIntoClaude_movesRenamesAndKeepsRadarOnConflict() {
        let codex = [
            costRow("gpt-5.5", "medium", iq: 90, cost: 3, minutes: 16),
            anthropicRow("claude-opus-5", "low", iq: 100),      // 雷达没有 → 补入
            anthropicRow("claude-sonnet-5", "high", iq: 150),   // 雷达已有 → 丢弃
            anthropicRow("claude-opus-5", "high", iq: 0),       // IQ 0 → 丢弃
        ]
        let claude = RadarParser.buildClaudeByIQ([
            ModelResult(name: "sonnet-5", depth: "high", iq: 45, passed: 3, tasks: 10,
                        cost: 44.2, timeMinutes: 156, family: .claude, isReference: true,
                        metricSource: .claudeRadar),
        ])

        let merged = RadarParser.mergeAnthropicIntoClaude(codex: codex, claude: claude)

        XCTAssertEqual(merged.codex.map(\.result.name), ["gpt-5.5"])
        XCTAssertEqual(merged.claude.map(\.id), ["opus-5/low", "sonnet-5/high"])
        // 冲突档位保留雷达数值（45），不被竞品列的 150 覆盖。
        XCTAssertEqual(merged.claude.first { $0.id == "sonnet-5/high" }?.result.iq, 45)
        // score 按合并后的 maxIq 重算。
        XCTAssertEqual(merged.claude.first { $0.id == "opus-5/low" }?.score ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(merged.claude.first { $0.id == "sonnet-5/high" }?.score ?? 0, 0.45, accuracy: 0.0001)
        // costIndex 透传，不因搬迁丢失。
        XCTAssertEqual(merged.claude.first { $0.id == "opus-5/low" }?.costIndex, 214.7)
    }

    func testMergeAnthropicIntoClaude_noAnthropicEntries_leavesBothListsUntouched() {
        let codex = [costRow("gpt-5.5", "medium", iq: 90, cost: 3, minutes: 16)]
        let merged = RadarParser.mergeAnthropicIntoClaude(codex: codex, claude: [])

        XCTAssertEqual(merged.codex.map(\.id), codex.map(\.id))
        XCTAssertTrue(merged.claude.isEmpty)
    }

    func testCostEfficiency_doesNotCompareAcrossMetricSources() {
        // 两个源任务集不同：竞品列 $1.7 的档位不得压制雷达侧 $44 的档位。
        let cheapFromCodexRadar = anthropicRow("opus-5", "low", iq: 100)
        let pricyFromClaudeRadar = ScoredModel(
            result: ModelResult(name: "sonnet-5", depth: "max", iq: 120, passed: 8, tasks: 10,
                                cost: 125.1, timeMinutes: 504, family: .claude, isReference: true,
                                metricSource: .claudeRadar),
            score: 1.0
        )

        let verdicts = CostEfficiency.verdicts(in: [cheapFromCodexRadar, pricyFromClaudeRadar])

        XCTAssertFalse(verdicts[pricyFromClaudeRadar.id]?.isDominated ?? true)
        XCTAssertFalse(verdicts[cheapFromCodexRadar.id]?.isDominated ?? true)
    }

    // MARK: - 「只看前沿」展示过滤（隐藏被压制行；推荐项/菜单栏档位豁免）

    func testFrontierFilter_hidesDominatedKeepsFrontierAndUnjudged() {
        let frontier = costRow("gpt-5.6-luna", "max", iq: 100, cost: 0.5, minutes: 20)
        let dominated = costRow("gpt-5.6-sol", "ultra", iq: 100, cost: 24.5, minutes: 20)
        let noCost = costRow("gpt-5.5", "low", iq: 80, cost: 0, minutes: 20)
        let group = [frontier, dominated, noCost]
        let verdicts = CostEfficiency.verdicts(in: group)

        XCTAssertTrue(FrontierFilter.isVisible(frontier, verdicts: verdicts, protectedID: nil))
        XCTAssertFalse(FrontierFilter.isVisible(dominated, verdicts: verdicts, protectedID: nil))
        // 缺价格 → 没有判定 → 不算被压制，保留。
        XCTAssertTrue(FrontierFilter.isVisible(noCost, verdicts: verdicts, protectedID: nil))
    }

    func testFrontierFilter_exemptsRecommendedAndMenuBarPick() {
        let frontier = costRow("gpt-5.6-luna", "max", iq: 100, cost: 0.5, minutes: 20)
        var recommended = costRow("gpt-5.6-sol", "ultra", iq: 100, cost: 24.5, minutes: 20)
        recommended.recommendedIn = ["难题攻坚"]
        let menuBarPick = costRow("gpt-5.6-sol", "high", iq: 100, cost: 4.1, minutes: 20)
        let verdicts = CostEfficiency.verdicts(in: [frontier, recommended, menuBarPick])

        // 两者都被 $0.5 的档位压制，但一个是推荐项、一个是菜单栏档位，都不隐藏。
        XCTAssertTrue(verdicts[recommended.id]?.isDominated ?? false)
        XCTAssertTrue(verdicts[menuBarPick.id]?.isDominated ?? false)
        XCTAssertTrue(FrontierFilter.isVisible(recommended, verdicts: verdicts, protectedID: nil))
        XCTAssertTrue(FrontierFilter.isVisible(menuBarPick, verdicts: verdicts, protectedID: menuBarPick.id))
        // 同一行不再是菜单栏档位时就该隐藏了。
        XCTAssertFalse(FrontierFilter.isVisible(menuBarPick, verdicts: verdicts, protectedID: nil))
    }

    /// 判定必须基于全量组：若先过滤再判定，压制者被移走后被压制的行会翻身成前沿。
    func testFrontierFilter_verdictsMustComeFromFullGroup() {
        let cheap = costRow("gpt-5.6-luna", "max", iq: 100, cost: 0.5, minutes: 20)
        let pricey = costRow("gpt-5.6-sol", "ultra", iq: 100, cost: 24.5, minutes: 20)

        let fullGroupVerdicts = CostEfficiency.verdicts(in: [cheap, pricey])
        XCTAssertFalse(FrontierFilter.isVisible(pricey, verdicts: fullGroupVerdicts, protectedID: nil))

        // 反例：只拿幸存者重算，pricey 会被误判为前沿。
        let reRanked = CostEfficiency.verdicts(in: [pricey])
        XCTAssertTrue(FrontierFilter.isVisible(pricey, verdicts: reRanked, protectedID: nil))
    }

    // MARK: - 「模型推荐」折叠视图的整组/展开档位前沿过滤（ModelRecommendationFrontierFilter）
    //
    // 覆盖上一轮 frontier 修复遗留的两个 bug：
    // 1. 只用各组代表档算 verdicts 会漏掉「压制者本身不是任何组代表档」的情况；
    // 2. 保护名单只比较代表档 id，菜单栏档位落在组内非代表档时会把整组错误隐藏。

    func testModelRecommendationFrontierFilter_nonRepresentativeTierParticipatesAsSuppressor() {
        // 组 A：唯一档，本身构不成组内比较（singleComparableTier）。
        let repA = costRow("gpt-a", "medium", iq: 75, cost: 10, minutes: 20)
        let groupA = ModelRecommendationGroup(modelName: "gpt-a", metricSource: .codexRadar, tiers: [repA])
        guard case .singleComparableTier = groupA.outcome else { return XCTFail("expected .singleComparableTier") }

        // 组 B：low 档更便宜但 IQ 够不到 95% 门槛，代表档是 high；low 因此是组 B 的非代表档，
        // 却仍是能压制别的模型的真实候选。
        let low = costRow("gpt-b", "low", iq: 80, cost: 2, minutes: 20)
        let high = costRow("gpt-b", "high", iq: 95, cost: 30, minutes: 20)
        let groupB = ModelRecommendationGroup(modelName: "gpt-b", metricSource: .codexRadar, tiers: [low, high])
        guard case .recommended(let representativeB, _, _) = groupB.outcome, representativeB.id == high.id else {
            return XCTFail("expected group B 代表档为 high")
        }

        let fullTiersVerdicts = CostEfficiency.verdicts(in: (groupA.tiers + groupB.tiers))
        XCTAssertTrue(fullTiersVerdicts[repA.id]?.isDominated ?? false,
                       "非代表档 low（IQ 不更低、更便宜、不明显更慢）也应参与压制判定")
        XCTAssertFalse(ModelRecommendationFrontierFilter.isGroupVisible(groupA, verdicts: fullTiersVerdicts, menuBarID: nil))

        // 反例：只拿各组代表档算 verdicts（旧 bug）会漏掉 low 这个真正的压制者，
        // high 更贵、压不倒 repA，于是 repA 被误判为前沿。
        let representativeOnlyVerdicts = CostEfficiency.verdicts(in: [repA, representativeB])
        XCTAssertFalse(representativeOnlyVerdicts[repA.id]?.isDominated ?? false,
                        "仅用代表档算 verdicts 会漏掉非代表档压制者（旧 bug 的重现条件）")
    }

    func testModelRecommendationFrontierFilter_suppressedNewRecommendationStaysVisible() {
        let medium = costRow("gpt-c", "medium", iq: 90, cost: 6, minutes: 20)
        let high = costRow("gpt-c", "high", iq: 95, cost: 8, minutes: 20)
        let groupC = ModelRecommendationGroup(modelName: "gpt-c", metricSource: .codexRadar, tiers: [medium, high])
        guard case .recommended(let picked, _, _) = groupC.outcome, picked.id == high.id else {
            return XCTFail("expected 推荐 high")
        }

        // 外部一档把新推荐档 high 也压制了。
        let cheaperElsewhere = costRow("gpt-d", "max", iq: 100, cost: 1, minutes: 20)
        let verdicts = CostEfficiency.verdicts(in: groupC.tiers + [cheaperElsewhere])
        XCTAssertTrue(verdicts[high.id]?.isDominated ?? false)

        XCTAssertTrue(ModelRecommendationFrontierFilter.isGroupVisible(groupC, verdicts: verdicts, menuBarID: nil),
                       "新推荐档即使被压制也不能从折叠榜单里消失")
    }

    func testModelRecommendationFrontierFilter_nonRepresentativeMenuBarTierProtectsGroup() {
        let repD = costRow("gpt-e", "medium", iq: 75, cost: 10, minutes: 20)
        // 菜单栏当前档位是同模型的另一档，且这一档缺有效 IQ（不参与推荐判定的有效成绩集合），
        // 因此代表档仍是 repD（singleComparableTier），但菜单栏档位确实存在于组内。
        let menuBarTier = costRow("gpt-e", "high", iq: 0, cost: 50, minutes: 20)
        let groupD = ModelRecommendationGroup(modelName: "gpt-e", metricSource: .codexRadar, tiers: [repD, menuBarTier])
        guard case .singleComparableTier(let representativeD) = groupD.outcome, representativeD.id == repD.id else {
            return XCTFail("expected 代表档为 repD")
        }

        let suppressor = costRow("gpt-f", "low", iq: 80, cost: 2, minutes: 20)
        let verdicts = CostEfficiency.verdicts(in: groupD.tiers + [suppressor])
        XCTAssertTrue(verdicts[repD.id]?.isDominated ?? false)

        XCTAssertTrue(
            ModelRecommendationFrontierFilter.isGroupVisible(groupD, verdicts: verdicts, menuBarID: menuBarTier.id),
            "菜单栏当前档位落在组内非代表档时，整组也不能被隐藏"
        )
        XCTAssertFalse(
            ModelRecommendationFrontierFilter.isGroupVisible(groupD, verdicts: verdicts, menuBarID: "unrelated-id"),
            "菜单栏档位不在这组里时不该被保护"
        )
    }

    func testModelRecommendationFrontierFilter_expandedListKeepsProtectedHidesRest() {
        let low = costRow("gpt-g", "low", iq: 50, cost: 3, minutes: 10)
        let medium = costRow("gpt-g", "medium", iq: 55, cost: 4, minutes: 10)
        var high = costRow("gpt-g", "high", iq: 60, cost: 5, minutes: 10)
        high.recommendedIn = ["daily_development"]   // 旧站长推荐豁免
        let maxTier = costRow("gpt-g", "max", iq: 100, cost: 50, minutes: 10)
        let groupG = ModelRecommendationGroup(modelName: "gpt-g", metricSource: .codexRadar,
                                               tiers: [low, medium, high, maxTier])
        guard case .recommended(let picked, _, _) = groupG.outcome, picked.id == maxTier.id else {
            return XCTFail("expected 推荐 max（唯一进入 95% 门槛的候选）")
        }

        // 外部一档把组内全部四档都压制了：新推荐档、菜单栏档、旧站长推荐豁免档都受影响。
        let cheapElsewhere = costRow("gpt-h", "ultra", iq: 100, cost: 1, minutes: 10)
        let verdicts = CostEfficiency.verdicts(in: groupG.tiers + [cheapElsewhere])
        for tier in groupG.tiers {
            XCTAssertTrue(verdicts[tier.id]?.isDominated ?? false, "\(tier.id) 应被压制")
        }

        let filtered = ModelRecommendationFrontierFilter.visibleTiers(
            in: groupG, verdicts: verdicts, menuBarID: medium.id, forceShowAll: false
        )
        // 新推荐档（max）/ 菜单栏档（medium）/ 旧站长推荐豁免（high）保留；无保护的 low 被过滤。
        XCTAssertEqual(Set(filtered.map(\.id)), Set([maxTier.id, medium.id, high.id]))

        let all = ModelRecommendationFrontierFilter.visibleTiers(
            in: groupG, verdicts: verdicts, menuBarID: medium.id, forceShowAll: true
        )
        XCTAssertEqual(all.count, groupG.tiers.count, "「显示全部档位」按钮按下后应绕过过滤")
    }

    func testModelRecommendationFrontierFilter_doesNotAffectRecommendationOutcome() {
        let medium = costRow("gpt-i", "medium", iq: 90, cost: 6, minutes: 20)
        let high = costRow("gpt-i", "high", iq: 95, cost: 8, minutes: 20)
        let group = ModelRecommendationGroup(modelName: "gpt-i", metricSource: .codexRadar, tiers: [medium, high])
        let verdicts = CostEfficiency.verdicts(in: group.tiers)

        _ = ModelRecommendationFrontierFilter.isGroupVisible(group, verdicts: verdicts, menuBarID: nil)
        _ = ModelRecommendationFrontierFilter.visibleTiers(in: group, verdicts: verdicts, menuBarID: nil, forceShowAll: false)

        guard case .recommended(let picked, _, _) = group.outcome else {
            return XCTFail("过滤前后推荐结论都不应改变")
        }
        XCTAssertEqual(picked.id, high.id, "展示层过滤不改变推荐算法的判定结果")
    }

    // MARK: - 性价比判定（组内比较：IQ 不更低 + 更便宜 + 不明显更慢）

    private func costRow(_ name: String, _ depth: String, iq: Double, cost: Double, minutes: Int) -> ScoredModel {
        ScoredModel(result: ModelResult(name: name, depth: depth, iq: iq, passed: 7, tasks: 336,
                                        cost: cost, timeMinutes: minutes,
                                        family: .codex, isReference: false), score: 0.5)
    }

    /// 复刻线上最刺眼的一条：sol/ultra $24.46 与 luna/max $0.53 同为 IQ 100.9，
    /// luna 还更快，因此 sol/ultra 被压制且倍数 ×46。
    func testCostEfficiency_sameIQMuchPricier_isDominatedWithMultiple() throws {
        let sol = costRow("gpt-5.6-sol", "ultra", iq: 100.89, cost: 24.46, minutes: 53)
        let luna = costRow("gpt-5.6-luna", "max", iq: 100.89, cost: 0.53, minutes: 37)
        let verdicts = CostEfficiency.verdicts(in: [sol, luna])

        XCTAssertEqual(verdicts[sol.id]?.dominator?.id, luna.id)
        XCTAssertEqual(try XCTUnwrap(verdicts[sol.id]?.badgeMultiple), 24.46 / 0.53, accuracy: 1e-9)
        XCTAssertEqual(verdicts[sol.id]?.badgeLabel, "×46")
        // 参照本身在前沿
        XCTAssertFalse(try XCTUnwrap(verdicts[luna.id]).isDominated)
        XCTAssertNil(verdicts[luna.id]?.badgeLabel)
    }

    /// 更贵 + IQ 更低 + 更慢，同一模型内也照标不误。
    func testCostEfficiency_higherTierWorseAndPricier_isDominated() {
        let high = costRow("gpt-6-astra", "high", iq: 108.4, cost: 3.05, minutes: 13)
        let ultra = costRow("gpt-6-astra", "ultra", iq: 105.3, cost: 9.34, minutes: 14)
        let verdicts = CostEfficiency.verdicts(in: [high, ultra])

        XCTAssertEqual(verdicts[ultra.id]?.dominator?.id, high.id)
        XCTAssertEqual(verdicts[ultra.id]?.badgeLabel, "×3.1")
        XCTAssertFalse(verdicts[high.id]!.isDominated)
    }

    /// 便宜但明显更慢就不算压制：慢过 10% 容差即豁免。
    func testCostEfficiency_cheaperButMuchSlower_doesNotDominate() {
        let fast = costRow("gpt-6-astra", "low", iq: 97.4, cost: 1.99, minutes: 9)
        let slowCheap = costRow("gpt-5.6-luna", "max", iq: 100.9, cost: 0.53, minutes: 37)
        let verdicts = CostEfficiency.verdicts(in: [fast, slowCheap])

        // luna 更便宜、IQ 更高，但慢了 4 倍 → 不构成压制，astra/low 留在前沿
        XCTAssertFalse(verdicts[fast.id]!.isDominated)
    }

    /// 容差内的"快一点点"不该让贵一倍的档位逃脱：线上 deepseek 29 分 vs 30 分就是这种情况。
    func testCostEfficiency_slightlySlowerWithinToleranceStillDominates() {
        let cheap = costRow("dsh-deepseek-v4-flash-vision-exp", "max", iq: 99.38, cost: 0.28, minutes: 30)
        let pricey = costRow("deepseek-v4-pro", "high", iq: 88.24, cost: 0.58, minutes: 29)
        let verdicts = CostEfficiency.verdicts(in: [cheap, pricey])

        // 30 ≤ 29 × 1.1，视为不明显更慢
        XCTAssertEqual(verdicts[pricey.id]?.dominator?.id, cheap.id)
        XCTAssertEqual(verdicts[pricey.id]?.badgeLabel, "×2.1")
    }

    /// 被压制但没到 2 倍：仍判为被压制（价格会标橙），但不出角标。
    func testCostEfficiency_dominatedBelowThreshold_hasNoBadge() {
        let cheap = costRow("gpt-6-astra", "high", iq: 108.4, cost: 3.05, minutes: 13)
        let slight = costRow("gpt-6-astra", "xhigh", iq: 105.0, cost: 4.08, minutes: 18)
        let verdicts = CostEfficiency.verdicts(in: [cheap, slight])

        XCTAssertTrue(verdicts[slight.id]!.isDominated)
        XCTAssertNil(verdicts[slight.id]?.badgeMultiple)
        XCTAssertNil(verdicts[slight.id]?.badgeLabel)
    }

    /// 花费或耗时缺失的档位不参与判定：既不压制别人，也不出现在结果里（视图据此保持中性灰）。
    func testCostEfficiency_rowsMissingCostOrTimeAreExcluded() {
        let noCost = costRow("gpt-x", "high", iq: 120, cost: 0, minutes: 10)
        let noTime = costRow("gpt-y", "high", iq: 120, cost: 1, minutes: 0)
        let normal = costRow("gpt-5.5", "high", iq: 90, cost: 5, minutes: 20)
        let verdicts = CostEfficiency.verdicts(in: [noCost, noTime, normal])

        XCTAssertNil(verdicts[noCost.id])
        XCTAssertNil(verdicts[noTime.id])
        // 这两条不参与比较，所以 normal 仍在前沿
        XCTAssertFalse(verdicts[normal.id]!.isDominated)
    }

    /// 只在组内比较：跨组不互相压制（榜单里 OpenAI 与 DeepSeek 是两个独立分组）。
    func testCostEfficiency_comparesWithinGivenGroupOnly() {
        let openai = costRow("gpt-5.6-sol", "ultra", iq: 100.9, cost: 24.46, minutes: 53)
        let deepseek = costRow("dsh-deepseek-v4-flash-vision-exp", "max", iq: 99.4, cost: 0.28, minutes: 30)

        // 分别成组时谁也压不着谁
        XCTAssertFalse(CostEfficiency.verdicts(in: [openai])[openai.id]!.isDominated)
        XCTAssertFalse(CostEfficiency.verdicts(in: [deepseek])[deepseek.id]!.isDominated)
        // 硬塞进同一组才会出现跨厂商压制——调用方（GroupSectionView）只会传同组模型
        XCTAssertNil(CostEfficiency.verdicts(in: [openai, deepseek])[openai.id]?.dominator)
    }

    // MARK: - 场景推荐区：只取日常开发 / 难题攻坚，空组自动跳过

    private func picksSnapshot(_ groups: [InsightGroup]) -> RadarSnapshot {
        RadarSnapshot(all: [], updatedAt: Date(), insights: groups, codexSource: .website)
    }

    private func insightGroup(_ key: String, _ title: String, _ models: [(String, String)]) -> InsightGroup {
        InsightGroup(key: key, title: title, rule: nil, items: models.map { model, effort in
            InsightItem(model: model, effort: effort, iq: 100, passed: nil, samples: nil,
                        averageCostUSD: 3.0, averageDurationMinutes: 16, combinedCostIndex: nil,
                        rule: nil, trend48h: nil)
        })
    }

    func testScenarioPicks_takesOnlyDailyAndHardInFixedOrder() {
        let snapshot = picksSnapshot([
            insightGroup("hard_problems", "难题攻坚", [("gpt-5.6-sol", "ultra")]),
            insightGroup("background_automation", "后台自动化", [("gpt-5.6-luna", "high")]),
            insightGroup("daily_development", "日常开发", [("gpt-5.6-sol", "medium")]),
            insightGroup("lobster_tasks", "跑龙虾类任务", [("gpt-5.6-terra", "low")]),
        ])
        // 展示顺序由 displayKeys 决定，与服务端数组顺序无关；后台自动化 / 跑龙虾不进推荐区
        XCTAssertEqual(ScenarioPicksView.groups(in: snapshot).map(\.key), ["daily_development", "hard_problems"])
    }

    func testScenarioPicks_skipsMissingOrEmptyGroups() {
        let onlyDaily = picksSnapshot([insightGroup("daily_development", "日常开发", [("gpt-5.5", "high")])])
        XCTAssertEqual(ScenarioPicksView.groups(in: onlyDaily).map(\.key), ["daily_development"])

        let emptyHard = picksSnapshot([
            insightGroup("daily_development", "日常开发", [("gpt-5.5", "high")]),
            insightGroup("hard_problems", "难题攻坚", []),
        ])
        XCTAssertEqual(ScenarioPicksView.groups(in: emptyHard).map(\.key), ["daily_development"])

        XCTAssertTrue(ScenarioPicksView.groups(in: picksSnapshot([])).isEmpty)
    }

    // MARK: - 厂商概览：首屏索引区数据来自 codexGroupsByVendor，不写死模型名

    func testVendorGroup_overviewModelNames_dedupesAcrossEffortsAndStripsGPTPrefixOnly() throws {
        let models = [
            ModelResult(name: "gpt-6-astra", depth: "high", iq: 100, passed: 8, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false),
            ModelResult(name: "gpt-6-astra", depth: "medium", iq: 95, passed: 7, tasks: 12, cost: 15, timeMinutes: 20, family: .codex, isReference: false),
            ModelResult(name: "gpt-5.6-sol", depth: "high", iq: 90, passed: 7, tasks: 12, cost: 12, timeMinutes: 25, family: .codex, isReference: false),
            ModelResult(name: "grok-4.6", depth: "high", iq: 92, passed: 7, tasks: 20, cost: 18, timeMinutes: 25, family: .codex, isReference: false),
            ModelResult(name: "deepseek-v4-turbo", depth: "medium", iq: 88, passed: 6, tasks: 20, cost: 5, timeMinutes: 40, family: .codex, isReference: false),
            ModelResult(name: "claude-opus-4.8", depth: "high", iq: 105, passed: 8, tasks: 20, cost: 60, timeMinutes: 200, family: .codex, isReference: false),
        ]
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        let groups = Dictionary(uniqueKeysWithValues: snapshot.codexGroupsByVendor.map { ($0.vendor, $0) })

        // 同一模型多个档位只算一次；OpenAI 去掉 "gpt-" 前缀，其余厂商保留原名。
        // 组内顺序 = codexGroup 综合分降序（见 scoreAndSort）：5.6-sol 的低成本优势
        // 超过其 IQ 劣势，综合分略高于 6-astra 的 medium 档位，故排在前面。
        XCTAssertEqual(groups[.openai]?.overviewModelNames, ["5.6-sol", "6-astra"])
        XCTAssertEqual(groups[.deepseek]?.overviewModelNames, ["deepseek-v4-turbo"])
        // 非 OpenAI 厂商保留原名，不去前缀
        XCTAssertEqual(groups[.xai]?.overviewModelNames, ["grok-4.6"])
        // Claude 竞品条目被整体剔除，也不落入"其他"
        XCTAssertNil(groups[.other])
        XCTAssertFalse(groups.values.flatMap(\.overviewModelNames).contains("claude-opus-4.8"))
    }

    func testVendorGroup_overviewSummary_showsCountAndTruncatesWithPlusN() throws {
        let models = (0..<5).map { i in
            ModelResult(name: "gpt-5.\(i)", depth: "high", iq: 100 - Double(i), passed: 7, tasks: 12, cost: 20, timeMinutes: 30, family: .codex, isReference: false)
        }
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        let openai = try XCTUnwrap(snapshot.codexGroupsByVendor.first { $0.vendor == .openai })

        XCTAssertEqual(openai.overviewModelNames.count, 5)
        XCTAssertTrue(openai.overviewSummary.hasPrefix("5 · "))
        XCTAssertTrue(openai.overviewSummary.hasSuffix("+2"))
    }

    // MARK: - CodexDisplayQuality：展示层质量过滤（不影响 snapshot.all / menuBarBest），阈值边界测试

    func testCodexDisplayQuality_filtersBelowTaskThreshold_keepsAtThreshold() {
        let below = ScoredModel(result: ModelResult(name: "mystery-a", depth: "high", iq: 80, passed: 10, tasks: 19, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.8)
        let atThreshold = ScoredModel(result: ModelResult(name: "mystery-b", depth: "high", iq: 80, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.8)
        let result = CodexDisplayQuality.filtered([below, atThreshold], menuBarBestID: nil)
        XCTAssertEqual(result.map(\.id), [atThreshold.id])
    }

    func testCodexDisplayQuality_filtersBelowIQThreshold_keepsAtThreshold() {
        let below = ScoredModel(result: ModelResult(name: "mystery-a", depth: "high", iq: 49.999, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.5)
        let atThreshold = ScoredModel(result: ModelResult(name: "mystery-b", depth: "high", iq: 50, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.5)
        let result = CodexDisplayQuality.filtered([below, atThreshold], menuBarBestID: nil)
        XCTAssertEqual(result.map(\.id), [atThreshold.id])
    }

    func testCodexDisplayQuality_protectsGPTModels_recommendedItems_andMenuBarBest_fromTaskIQFilter() {
        let gptLowSample = ScoredModel(result: ModelResult(name: "gpt-5.5", depth: "low", iq: 10, passed: 1, tasks: 1, cost: 1, timeMinutes: 1, family: .codex, isReference: false), score: 0.1)
        let recommendedLowQuality = ScoredModel(result: ModelResult(name: "mystery-a", depth: "high", iq: 10, passed: 1, tasks: 1, cost: 1, timeMinutes: 1, family: .codex, isReference: false), score: 0.1, recommendedIn: ["日常开发"])
        let menuBarBestLowQuality = ScoredModel(result: ModelResult(name: "mystery-b", depth: "high", iq: 10, passed: 1, tasks: 1, cost: 1, timeMinutes: 1, family: .codex, isReference: false), score: 0.1)
        let result = CodexDisplayQuality.filtered(
            [gptLowSample, recommendedLowQuality, menuBarBestLowQuality],
            menuBarBestID: menuBarBestLowQuality.id
        )
        XCTAssertEqual(Set(result.map(\.id)), Set([gptLowSample.id, recommendedLowQuality.id, menuBarBestLowQuality.id]))
    }

    func testCodexDisplayQuality_filtersDepthsBelow60PercentOfModelMaxIQ_alwaysKeepsTopDepth() {
        let top = ScoredModel(result: ModelResult(name: "mystery", depth: "high", iq: 100, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 1)
        let atRatio = ScoredModel(result: ModelResult(name: "mystery", depth: "medium", iq: 60, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.6)
        let belowRatio = ScoredModel(result: ModelResult(name: "mystery", depth: "low", iq: 59.999, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.6)
        let result = CodexDisplayQuality.filtered([top, atRatio, belowRatio], menuBarBestID: nil)
        XCTAssertEqual(Set(result.map(\.id)), Set([top.id, atRatio.id]))
    }

    func testCodexDisplayQuality_recommendedAndMenuBarBest_alsoProtectedFromDepthRatioFilter() {
        let top = ScoredModel(result: ModelResult(name: "mystery", depth: "high", iq: 100, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 1)
        let recommendedLowDepth = ScoredModel(result: ModelResult(name: "mystery", depth: "low", iq: 1, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.01, recommendedIn: ["日常开发"])
        let result = CodexDisplayQuality.filtered([top, recommendedLowDepth], menuBarBestID: nil)
        XCTAssertEqual(Set(result.map(\.id)), Set([top.id, recommendedLowDepth.id]))
    }

    // MARK: - CodexSingleTierCondense：gpt-5.6-terra / gpt-5.6-luna 单档收敛（不影响其他模型）

    func testCodexSingleTierCondense_prefersMenuBarBest_evenIfNotHighestIQ() {
        let low = ScoredModel(result: ModelResult(name: "gpt-5.6-terra", depth: "medium", iq: 80, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.8)
        let high = ScoredModel(result: ModelResult(name: "gpt-5.6-terra", depth: "xhigh", iq: 99, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.99)
        let result = CodexSingleTierCondense.filtered([low, high], menuBarBestID: low.id)
        XCTAssertEqual(result.map(\.id), [low.id])
    }

    func testCodexSingleTierCondense_fallsBackToHighestIQ_whenNoMenuBarBestMatch() {
        let low = ScoredModel(result: ModelResult(name: "gpt-5.6-luna", depth: "medium", iq: 80, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.8)
        let high = ScoredModel(result: ModelResult(name: "gpt-5.6-luna", depth: "xhigh", iq: 99, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.99)
        let result = CodexSingleTierCondense.filtered([low, high], menuBarBestID: "gpt-5.5/medium")
        XCTAssertEqual(result.map(\.id), [high.id])
    }

    func testCodexSingleTierCondense_tieBreaksByLexicographicallySmallestDepth() {
        let xhigh = ScoredModel(result: ModelResult(name: "gpt-5.6-terra", depth: "xhigh", iq: 90, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9)
        let high = ScoredModel(result: ModelResult(name: "gpt-5.6-terra", depth: "high", iq: 90, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9)
        // IQ 并列时取 depth 字典序最小者："high" < "xhigh"，结果确定、与传入顺序无关。
        XCTAssertEqual(CodexSingleTierCondense.filtered([xhigh, high], menuBarBestID: nil).map(\.id), [high.id])
        XCTAssertEqual(CodexSingleTierCondense.filtered([high, xhigh], menuBarBestID: nil).map(\.id), [high.id])
    }

    func testCodexSingleTierCondense_leavesOtherModelsAndMultipleTargetsUntouched() {
        let terraLow = ScoredModel(result: ModelResult(name: "gpt-5.6-terra", depth: "medium", iq: 80, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.8)
        let terraHigh = ScoredModel(result: ModelResult(name: "gpt-5.6-terra", depth: "xhigh", iq: 95, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.95)
        let lunaLow = ScoredModel(result: ModelResult(name: "gpt-5.6-luna", depth: "medium", iq: 82, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.82)
        let lunaHigh = ScoredModel(result: ModelResult(name: "gpt-5.6-luna", depth: "xhigh", iq: 93, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.93)
        let untouched = ScoredModel(result: ModelResult(name: "gpt-5.5", depth: "medium", iq: 87, passed: 7, tasks: 20, cost: 20, timeMinutes: 30, family: .codex, isReference: false), score: 0.87)
        let result = CodexSingleTierCondense.filtered([terraLow, terraHigh, lunaLow, lunaHigh, untouched], menuBarBestID: nil)
        XCTAssertEqual(Set(result.map(\.id)), Set([terraHigh.id, lunaHigh.id, untouched.id]))
    }

    // MARK: - DeepSeekDisplayLimit：展示层最多 3 个，推荐项优先且超额时全部保留

    func testDeepSeekDisplayLimit_capsAtThree_whenNoneRecommended() {
        let models = (0..<5).map { i in
            ScoredModel(result: ModelResult(name: "deepseek-v\(i)", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9)
        }
        XCTAssertEqual(DeepSeekDisplayLimit.limited(models).count, 3)
        XCTAssertEqual(DeepSeekDisplayLimit.limited(models).map(\.id), Array(models.prefix(3)).map(\.id))
    }

    func testDeepSeekDisplayLimit_exactlyThree_keepsAll() {
        let models = (0..<3).map { i in
            ScoredModel(result: ModelResult(name: "deepseek-v\(i)", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9)
        }
        XCTAssertEqual(DeepSeekDisplayLimit.limited(models).map(\.id), models.map(\.id))
    }

    func testDeepSeekDisplayLimit_recommendedItemsFillFirst_thenTopUpToThree() {
        let recommended = ScoredModel(result: ModelResult(name: "deepseek-r", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9, recommendedIn: ["日常开发"])
        let rest = (0..<4).map { i in
            ScoredModel(result: ModelResult(name: "deepseek-v\(i)", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9)
        }
        let result = DeepSeekDisplayLimit.limited([recommended] + rest)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.id, recommended.id)
    }

    func testDeepSeekDisplayLimit_recommendedItemsExceedingThree_allKept() {
        let recommended = (0..<5).map { i in
            ScoredModel(result: ModelResult(name: "deepseek-r\(i)", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9, recommendedIn: ["日常开发"])
        }
        let rest = ScoredModel(result: ModelResult(name: "deepseek-v", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false), score: 0.9)
        let result = DeepSeekDisplayLimit.limited(recommended + [rest])
        XCTAssertEqual(result.map(\.id), recommended.map(\.id))
    }

    // MARK: - DeepSeekDisplayLimit.limitedGroups：同一限额套用到「模型推荐」折叠分组（一组一个模型）

    private func deepSeekGroup(_ name: String, recommendedIn: [String] = []) -> ModelRecommendationGroup {
        let tier = ScoredModel(
            result: ModelResult(name: name, depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false),
            score: 0.9, recommendedIn: recommendedIn
        )
        return ModelRecommendationGroup(modelName: name, metricSource: .codexRadar, tiers: [tier])
    }

    func testDeepSeekDisplayLimitGroups_capsAtThree_whenNoneRecommended() {
        let groups = (0..<5).map { deepSeekGroup("deepseek-v\($0)") }
        let result = DeepSeekDisplayLimit.limitedGroups(groups)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.id), Array(groups.prefix(3)).map(\.id))
    }

    func testDeepSeekDisplayLimitGroups_recommendedGroupsProtected_thenTopUpToThree() {
        let recommended = deepSeekGroup("deepseek-r", recommendedIn: ["日常开发"])
        let rest = (0..<4).map { deepSeekGroup("deepseek-v\($0)") }
        let result = DeepSeekDisplayLimit.limitedGroups([recommended] + rest)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.id, recommended.id)
    }

    func testDeepSeekDisplayLimitGroups_doesNotMergeDifferentModelsOrSources() {
        // 同名但不同 metricSource：两条不同的组，limitedGroups 只砍数量、不合并身份。
        let codexTier = ScoredModel(result: ModelResult(name: "deepseek-x", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false, metricSource: .codexRadar), score: 0.9)
        let radarTier = ScoredModel(result: ModelResult(name: "deepseek-x", depth: "high", iq: 90, passed: 7, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false, metricSource: .claudeRadar), score: 0.9)
        let codexGroup = ModelRecommendationGroup(modelName: "deepseek-x", metricSource: .codexRadar, tiers: [codexTier])
        let radarGroup = ModelRecommendationGroup(modelName: "deepseek-x", metricSource: .claudeRadar, tiers: [radarTier])
        let result = DeepSeekDisplayLimit.limitedGroups([codexGroup, radarGroup])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.id)), Set([codexGroup.id, radarGroup.id]))
    }

    // MARK: - 展示投影管线整合：质量过滤 → 单档收敛 → DeepSeek 限额，作用于 codexGroupsByVendor

    func testCodexGroupsByVendor_terraLunaCondensedToSingleTierInDisplay() throws {
        let models = [
            ModelResult(name: "gpt-5.6-terra", depth: "medium", iq: 85, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false),
            ModelResult(name: "gpt-5.6-terra", depth: "xhigh", iq: 96, passed: 10, tasks: 20, cost: 10, timeMinutes: 20, family: .codex, isReference: false),
            ModelResult(name: "gpt-5.5", depth: "medium", iq: 87, passed: 7, tasks: 20, cost: 20, timeMinutes: 30, family: .codex, isReference: false),
        ]
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        let openai = try XCTUnwrap(snapshot.codexGroupsByVendor.first { $0.vendor == .openai })
        let terraEntries = openai.models.filter { $0.result.name == "gpt-5.6-terra" }
        XCTAssertEqual(terraEntries.count, 1)
        XCTAssertEqual(terraEntries.first?.result.depth, "xhigh")   // 无 menuBarBest 命中，取 IQ 最高档
    }

    func testCodexGroupsByVendor_deepSeekGroupLimitedToThreeInDisplay() throws {
        let models = (0..<6).map { i in
            ModelResult(name: "deepseek-v\(i)", depth: "high", iq: 90, passed: 10, tasks: 20, cost: 5, timeMinutes: 20, family: .codex, isReference: false)
        }
        let scored = try RadarParser.scoreAndSort(models)
        let snapshot = RadarSnapshot(all: scored, updatedAt: Date())
        let deepseek = try XCTUnwrap(snapshot.codexGroupsByVendor.first { $0.vendor == .deepseek })
        XCTAssertEqual(deepseek.models.count, 3)
    }

    func testMenuBarBest_unaffectedByNonGPTVendorModels() {
        let points = [effPoint("gpt-5.5", "medium", iq: 87)]
        var codex = RadarParser.buildCodexFromEfficiency(points: points, insights: [])
        let grok = ModelResult(name: "grok-4.6", depth: "high", iq: 110, passed: 9, tasks: 12, cost: 8, timeMinutes: 40, family: .codex, isReference: false)
        codex.insert(ScoredModel(result: grok, score: 1), at: 0)
        let snapshot = RadarSnapshot(all: codex, updatedAt: Date(), codexSource: .website)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-5.5/medium")
    }

    // MARK: - buildCodexFromInsights：去重 + 首次出现顺序 + 合并 recommendedIn + item 自带指标

    func testBuildCodexFromInsights_dedupesKeepsOrderMergesRecommendedIn() throws {
        let insights = [
            InsightGroup(key: "daily_development", title: "日常开发", rule: nil, items: [
                InsightItem(model: "gpt-5.5", effort: "medium", iq: 87, passed: 7, samples: 12,
                            averageCostUSD: 23.9, averageDurationMinutes: 85, combinedCostIndex: 0.27, rule: nil, trend48h: nil),
            ]),
            InsightGroup(key: "budget", title: "预算优先", rule: nil, items: [
                InsightItem(model: "gpt-5.5", effort: "medium", iq: 87, passed: 7, samples: 12,
                            averageCostUSD: 23.9, averageDurationMinutes: 85, combinedCostIndex: 0.27, rule: nil, trend48h: nil),
                InsightItem(model: "gpt-5.4", effort: "xhigh", iq: 101, passed: nil, samples: nil,
                            averageCostUSD: nil, averageDurationMinutes: nil, combinedCostIndex: nil, rule: nil, trend48h: nil),
            ]),
        ]
        let codex = RadarParser.buildCodexFromInsights(insights: insights)
        XCTAssertEqual(codex.map(\.id), ["gpt-5.5/medium", "gpt-5.4/xhigh"])
        XCTAssertEqual(codex[0].recommendedIn, ["日常开发", "预算优先"])
        XCTAssertEqual(codex[1].recommendedIn, ["预算优先"])
        // item 自带指标透传
        XCTAssertEqual(codex[0].iq, 87)
        XCTAssertEqual(codex[0].result.cost, 23.9, accuracy: 1e-9)
        XCTAssertEqual(codex[0].result.timeMinutes, 85)
        XCTAssertEqual(try XCTUnwrap(codex[0].costIndex), 0.27, accuracy: 1e-9)
        // 缺失指标不伪装：紧凑指标行为 nil
        XCTAssertNil(codex[1].metricsLabel)
    }

    // MARK: - 紧凑指标行格式：缺失值不伪装为 0；成本指数兼顾小数/大数

    func testMetricsLabel_allValid() {
        let m = ScoredModel(
            result: ModelResult(name: "gpt-5.5", depth: "medium", iq: 87, passed: 7, tasks: 12,
                                cost: 23.9, timeMinutes: 85, family: .codex, isReference: false),
            score: 0.9, costIndex: 0.27)
        XCTAssertEqual(m.metricsLabel, "$23.9 · 1h25m · 指数0.27")
    }

    func testMetricsLabel_missingFieldsOmittedIndividually() {
        let noCost = ScoredModel(
            result: ModelResult(name: "a", depth: "x", iq: 87, passed: 0, tasks: 0,
                                cost: 0, timeMinutes: 85, family: .codex, isReference: false),
            score: 0.9, costIndex: nil)
        XCTAssertEqual(noCost.metricsLabel, "1h25m")

        let allMissing = ScoredModel(
            result: ModelResult(name: "a", depth: "x", iq: 87, passed: 0, tasks: 0,
                                cost: 0, timeMinutes: 0, family: .codex, isReference: false),
            score: 0.9, costIndex: nil)
        XCTAssertNil(allMissing.metricsLabel)
    }

    func testCostIndexLabel_compactAcrossMagnitudes() {
        func label(_ v: Double?) -> String? {
            ScoredModel(
                result: ModelResult(name: "a", depth: "x", iq: 1, passed: 0, tasks: 0,
                                    cost: 0, timeMinutes: 0, family: .codex, isReference: false),
                score: 0, costIndex: v).costIndexLabel
        }
        XCTAssertEqual(label(0.0002), "0.0002")
        XCTAssertEqual(label(0.27), "0.27")
        XCTAssertEqual(label(100), "100")
        XCTAssertEqual(label(123.456), "123")
        XCTAssertNil(label(0))     // 非正数省略，不显示 0
        XCTAssertNil(label(nil))
    }

    // MARK: - trend_48h 数组形状 / schema 不匹配的时间戳

    func testParseInsights_trend48hArrayShape_itemStillValid() throws {
        let json = """
        {"schema": 1, "recommendations": [
          {"key": "daily_development", "title": "日常开发", "items": [
            {"model": "gpt-5.5", "effort": "medium", "iq": 87.0, "trend_48h": [86.1, 86.8, 87.0]}
          ]}
        ]}
        """
        let groups = try RadarParser.parseInsights(json: Data(json.utf8))
        XCTAssertEqual(groups.count, 1)
        let item = try XCTUnwrap(groups[0].items.first)
        XCTAssertEqual(item.id, "gpt-5.5/medium")
        XCTAssertNil(item.trend48h)   // 不识别的形状明确忽略，不令条目失效
    }

    func testParseTimestamps_schemaMismatch_notTrusted() {
        let insights = #"{"schema": 99, "source_updated_at": "2026-07-26T10:00:00Z", "recommendations": []}"#
        XCTAssertNil(RadarParser.parseInsightsTimestamp(json: Data(insights.utf8)))
        let efficiency = #"{"schema": 99, "source_updated_at": "2026-07-26T09:00:00Z", "points": []}"#
        XCTAssertNil(RadarParser.parseEfficiencyTimestamp(json: Data(efficiency.utf8)))
    }

    // MARK: - 模型推荐（ModelRecommendation）：真实工程 IQ + 均价的同源同模型比较，
    // 与综合分（RadarParser.score）、insights 场景推荐口径完全无关。

    private func recTier(_ depth: String, iq: Double, cost: Double, source: MetricSource = .codexRadar) -> ScoredModel {
        ScoredModel(result: ModelResult(
            name: "test-model", depth: depth, iq: iq, passed: 0, tasks: 0,
            cost: cost, timeMinutes: 0, family: .codex, isReference: false, metricSource: source
        ), score: 0)
    }

    func testModelRecommendation_astra_cheaperMediumWinsWithinThreshold() {
        // medium 108.62 的 95% = 103.189，medium 107.14 达标且更便宜 → 推荐 medium。
        let medium = recTier("medium", iq: 107.14, cost: 2.238601)
        let high = recTier("high", iq: 108.62, cost: 3.065359)
        guard case .recommended(let picked, _, _) = ModelRecommendation.evaluate([medium, high]) else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(picked.result.depth, "medium")
    }

    func testModelRecommendation_sol_belowThresholdMediumLosesDespiteCheaperPrice() {
        // max 107.14 是最高分；medium 95.54 / 107.14 ≈ 89.2% < 95%，未达门槛，即便更便宜也不能选它。
        let max = recTier("max", iq: 107.14, cost: 7.999297)
        let medium = recTier("medium", iq: 95.54, cost: 2.92932)
        guard case .recommended(let picked, let maxIQ, let threshold) = ModelRecommendation.evaluate([max, medium]) else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(picked.result.depth, "max")
        XCTAssertEqual(maxIQ, 107.14, accuracy: 1e-9)
        XCTAssertEqual(threshold, 107.14 * 0.95, accuracy: 1e-9)
    }

    func testModelRecommendation_95PercentBoundary_isInclusive() {
        // maxIQ = 100 → threshold = 95（Double 精确值）；iq 恰好等于门槛应被纳入候选。
        let top = recTier("high", iq: 100, cost: 20)
        let boundary = recTier("medium", iq: 95, cost: 5)
        guard case .recommended(let picked, _, let threshold) = ModelRecommendation.evaluate([top, boundary]) else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(threshold, 95, accuracy: 1e-9)
        XCTAssertEqual(picked.result.depth, "medium", "达标（>=门槛）且更便宜，理应中选")
    }

    func testModelRecommendation_missingPriceAtHighestIQ_doesNotLowerThreshold() {
        // 最高分档缺价格：若先剔除它再取最高分，门槛会从 95 虚降到 85.5，让本不该入选的 90 分档
        // 误当候选。正确实现必须仍用 100 算门槛，令 90 分档落选，最终判定无可靠推荐。
        let topNoPrice = recTier("high", iq: 100, cost: 0)
        let belowRealThreshold = recTier("medium", iq: 90, cost: 5)
        guard case .unavailable(.noValidPrice) = ModelRecommendation.evaluate([topNoPrice, belowRealThreshold]) else {
            return XCTFail("expected .unavailable(.noValidPrice)")
        }
    }

    func testModelRecommendation_nanZeroNegative_excludedFromComparison() {
        let nanScore = recTier("a", iq: .nan, cost: 10)
        let zeroScore = recTier("b", iq: 0, cost: 10)
        let negativeScore = recTier("c", iq: -5, cost: 10)
        let nanPrice = recTier("d", iq: 100, cost: .nan)
        let zeroPrice = recTier("e", iq: 100, cost: 0)
        let negativePrice = recTier("f", iq: 100, cost: -5)
        let onlyValid = recTier("g", iq: 100, cost: 20)

        let outcome = ModelRecommendation.evaluate([
            nanScore, zeroScore, negativeScore, nanPrice, zeroPrice, negativePrice, onlyValid,
        ])
        guard case .recommended(let picked, let maxIQ, _) = outcome else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(picked.result.depth, "g")
        XCTAssertEqual(maxIQ, 100, accuracy: 1e-9, "NaN/0/负值不应参与最高分计算")
    }

    func testModelRecommendation_singleComparableTier_notTreatedAsReliableRecommendation() {
        let only = recTier("high", iq: 90, cost: 10)
        guard case .singleComparableTier(let picked) = ModelRecommendation.evaluate([only]) else {
            return XCTFail("expected .singleComparableTier")
        }
        XCTAssertEqual(picked.result.depth, "high")
    }

    // MARK: - ModelRecommendationGroup.isExpandable：只看实际档位数，不看推荐结论

    func testModelRecommendationGroup_singleTier_notExpandable() {
        let group = ModelRecommendationGroup(modelName: "test-model", metricSource: .codexRadar, tiers: [recTier("high", iq: 90, cost: 10)])
        guard case .singleComparableTier = group.outcome else { return XCTFail("expected .singleComparableTier") }
        XCTAssertFalse(group.isExpandable, "只有一档时没有东西可展开")
    }

    func testModelRecommendationGroup_multipleTiersButSingleValidIQ_stillExpandable() {
        // 两档，但第二档 IQ 无效（0），构不成「比较」，outcome 仍是 .singleComparableTier；
        // 展开列表要展示的是全部原始档位（这里两档），不能因为 outcome 是单档结论就禁止展开。
        let valid = recTier("high", iq: 90, cost: 10)
        let invalid = recTier("medium", iq: 0, cost: 5)
        let group = ModelRecommendationGroup(modelName: "test-model", metricSource: .codexRadar, tiers: [valid, invalid])
        guard case .singleComparableTier = group.outcome else { return XCTFail("expected .singleComparableTier") }
        XCTAssertEqual(group.tiers.count, 2)
        XCTAssertTrue(group.isExpandable, "多档时即使推荐结论落成单档也应可展开")
    }

    func testModelRecommendationGroup_multipleValidTiers_recommendedAndExpandable() {
        let a = recTier("high", iq: 100, cost: 10)
        let b = recTier("medium", iq: 90, cost: 5)
        let group = ModelRecommendationGroup(modelName: "test-model", metricSource: .codexRadar, tiers: [a, b])
        guard case .recommended = group.outcome else { return XCTFail("expected .recommended") }
        XCTAssertTrue(group.isExpandable)
    }

    func testModelRecommendation_noValidScore_returnsUnavailable() {
        let all = [recTier("a", iq: 0, cost: 10), recTier("b", iq: -1, cost: 10), recTier("c", iq: .nan, cost: 10)]
        guard case .unavailable(.noValidScore) = ModelRecommendation.evaluate(all) else {
            return XCTFail("expected .unavailable(.noValidScore)")
        }
    }

    func testModelRecommendation_tieBreak_isStableFirstOccurrence() {
        // 两档同价且都达标（98/100 = 98% >= 95%），平局取调用方给定顺序里先出现的一档。
        let a = recTier("a", iq: 100, cost: 10)
        let b = recTier("b", iq: 98, cost: 10)

        guard case .recommended(let firstOrderWinner, _, _) = ModelRecommendation.evaluate([a, b]) else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(firstOrderWinner.result.depth, "a")

        guard case .recommended(let reversedOrderWinner, _, _) = ModelRecommendation.evaluate([b, a]) else {
            return XCTFail("expected .recommended")
        }
        XCTAssertEqual(reversedOrderWinner.result.depth, "b")
    }

    func testModelRecommendationGroup_expandedTiersSortedByDepthOrder() {
        let tiers = [
            recTier("ultra", iq: 100, cost: 10),
            recTier("low", iq: 60, cost: 1),
            recTier("weird", iq: 70, cost: 2),      // 未知档
            recTier("xhigh", iq: 95, cost: 8),
            recTier("high", iq: 90, cost: 5),
            recTier("medium", iq: 80, cost: 3),
            recTier("max", iq: 98, cost: 9),
            recTier("another", iq: 65, cost: 1.5),  // 未知档，字典序排在 "weird" 之前
        ]
        let group = ModelRecommendationGroup(modelName: "test-model", metricSource: .codexRadar, tiers: tiers)
        XCTAssertEqual(
            group.tiers.map(\.result.depth),
            ["low", "medium", "high", "xhigh", "max", "ultra", "another", "weird"]
        )
    }

    func testGroupedForRecommendation_separatesSameModelNameAcrossMetricSources() throws {
        // 同一模型名 "opus-5" 在 claudecoderadar（雷达）与 codexradar（竞品列）两个源都出现，
        // 任务集与花费量级不同，绝不能合并到同一组比较（见 MetricSource 的注释）。
        func tier(_ depth: String, iq: Double, cost: Double, source: MetricSource) -> ScoredModel {
            ScoredModel(result: ModelResult(
                name: "opus-5", depth: depth, iq: iq, passed: 0, tasks: 0,
                cost: cost, timeMinutes: 0, family: .claude, isReference: false, metricSource: source
            ), score: 0)
        }
        let models = [
            tier("high", iq: 100, cost: 50, source: .claudeRadar),
            tier("medium", iq: 90, cost: 10, source: .claudeRadar),   // 90/100 = 90% < 95%，落选
            tier("high", iq: 80, cost: 5, source: .codexRadar),
        ]

        let groups = models.groupedForRecommendation()

        XCTAssertEqual(groups.count, 2, "同模型名不同 metricSource 必须分开成组")
        let claudeRadarGroup = try XCTUnwrap(groups.first { $0.metricSource == .claudeRadar })
        let codexRadarGroup = try XCTUnwrap(groups.first { $0.metricSource == .codexRadar })
        XCTAssertEqual(claudeRadarGroup.tiers.count, 2)
        XCTAssertEqual(codexRadarGroup.tiers.count, 1)

        guard case .recommended(let picked, _, _) = claudeRadarGroup.outcome else {
            return XCTFail("claudeRadar 分组应有推荐结论")
        }
        XCTAssertEqual(picked.result.depth, "high")

        guard case .singleComparableTier = codexRadarGroup.outcome else {
            return XCTFail("codexRadar 分组只有一档，应为 singleComparableTier")
        }
    }
}
