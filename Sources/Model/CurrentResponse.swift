// 解码层 —— https://codexradar.com/current.json。
//
// current.json 是 Codex 评分主源：model_iq.latest（主列）+ model_iq.comparisons.*（其它配置），
// 每个配置取 score/passed/tasks/cost_usd/wall_seconds/model/reasoning_effort。
// 时间戳来自 model_iq.quota_radar.updated_at（ISO8601 UTC）。
// latest/comparisons/quota_radar 均设为可选：评分与时间戳两条解析路径互不依赖，缺一不致连带失败。
import Foundation

struct CurrentResponse: Decodable {
    let modelIQ: ModelIQBlock

    enum CodingKeys: String, CodingKey {
        case modelIQ = "model_iq"
    }
}

struct ModelIQBlock: Decodable {
    let latest: ModelIQConfig?
    let comparisons: [String: ComparisonEntry]?
    let quotaRadar: QuotaRadar?

    enum CodingKeys: String, CodingKey {
        case latest, comparisons
        case quotaRadar = "quota_radar"
    }

    private struct ComparisonKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    // comparisons 逐项解码：某一项缺字段/格式不对时只跳过该项，不连带影响 latest 主条目和其它项。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latest = try container.decodeIfPresent(ModelIQConfig.self, forKey: .latest)
        quotaRadar = try container.decodeIfPresent(QuotaRadar.self, forKey: .quotaRadar)

        if let compContainer = try? container.nestedContainer(keyedBy: ComparisonKey.self, forKey: .comparisons) {
            var result: [String: ComparisonEntry] = [:]
            for key in compContainer.allKeys {
                if let entry = try? compContainer.decode(ComparisonEntry.self, forKey: key) {
                    result[key.stringValue] = entry
                }
            }
            comparisons = result
        } else {
            comparisons = nil
        }
    }
}

/// 一个 Codex 配置的当日检测结果（model_iq.latest 与每个 comparison 的 latest 同构）。
struct ModelIQConfig: Decodable {
    let score: Double          // IQ 智力分
    let passed: Int
    let tasks: Int
    let costUSD: Double         // 美元成本
    let wallSeconds: Double     // 并行墙钟（秒）
    let model: String           // "gpt-5.5"
    let reasoningEffort: String // "xhigh" / "high" / "medium"

    enum CodingKeys: String, CodingKey {
        case score, passed, tasks, model
        case costUSD = "cost_usd"
        case wallSeconds = "wall_seconds"
        case reasoningEffort = "reasoning_effort"
    }
}

/// model_iq.comparisons 的值：只取其 latest 配置。
struct ComparisonEntry: Decodable {
    let latest: ModelIQConfig
}

struct QuotaRadar: Decodable {
    let updatedAt: String                  // "2026-06-24T04:58:05Z"

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
    }
}

// MARK: - https://codexradar.com/api/radar-insights（站长推荐，权威源）

/// 可从任意 JSON 值解码成功的占位类型：用于逐项容错时跳过坏元素并推进 unkeyed 容器游标。
struct IgnoredJSONValue: Decodable {
    init(from decoder: Decoder) throws {}
}

private extension KeyedDecodingContainer {
    /// 上游计数字段可能在聚合后由整数变为 JSON 浮点数（例如 173.0 / 51.21）。
    /// 统一宽松解码并四舍五入，避免单个可选计数字段令整条推荐或效率记录失效。
    func decodeRoundedIntIfPresent(forKey key: Key) -> Int? {
        guard contains(key), (try? decodeNil(forKey: key)) != true else { return nil }
        if let value = try? decode(Int.self, forKey: key) { return value }
        guard let value = try? decode(Double.self, forKey: key),
              value.isFinite,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value.rounded())
    }
}

/// 站长推荐响应：schema 必须为 1；recommendations 保持服务端数组顺序。
struct InsightsResponse: Decodable {
    let schema: Int
    let sourceUpdatedAt: String?
    let comprehensivePoints: [ComprehensivePointDTO]?
    let recommendations: [InsightGroupDTO]

    enum CodingKeys: String, CodingKey {
        case schema, recommendations, comprehensivePoints = "comprehensive_points"
        case sourceUpdatedAt = "source_updated_at"
    }
}

/// 综合推荐候选的 IQ（网站端用它给空推荐分组补算候选）。
struct ComprehensivePointDTO: Decodable {
    let model: String
    let effort: String
    let iq: Double
}

/// 单个推荐分组（key/title/rule/items）。items 逐项容错：坏条目只跳过自身，不连带整组失败。
struct InsightGroupDTO: Decodable {
    let key: String
    let title: String
    let rule: String?
    let items: [InsightItemDTO]

    enum CodingKeys: String, CodingKey {
        case key, title, rule, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        rule = try container.decodeIfPresent(String.self, forKey: .rule)

        var itemsContainer = try container.nestedUnkeyedContainer(forKey: .items)
        var decoded: [InsightItemDTO] = []
        while !itemsContainer.isAtEnd {
            if let item = try? itemsContainer.decode(InsightItemDTO.self) {
                decoded.append(item)
            } else {
                _ = try? itemsContainer.decode(IgnoredJSONValue.self)
            }
        }
        items = decoded
    }
}

/// 推荐条目：identity = model + effort。除 model/effort/iq 外均为可选，缺失不致条目失败。
struct InsightItemDTO: Decodable {
    let model: String
    let effort: String
    let iq: Double
    let passed: Int?
    let samples: Int?
    let averageCostUSD: Double?
    let averageDurationMinutes: Double?
    let combinedCostIndex: Double?
    let rule: String?
    let trend48h: String?

    enum CodingKeys: String, CodingKey {
        case model, effort, iq, passed, samples, rule
        case averageCostUSD = "average_cost_usd"
        case averageDurationMinutes = "average_duration_minutes"
        case combinedCostIndex = "combined_cost_index"
        case trend48h = "trend_48h"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decode(String.self, forKey: .effort)
        iq = try container.decode(Double.self, forKey: .iq)
        passed = container.decodeRoundedIntIfPresent(forKey: .passed)
        samples = container.decodeRoundedIntIfPresent(forKey: .samples)
        averageCostUSD = try container.decodeIfPresent(Double.self, forKey: .averageCostUSD)
        averageDurationMinutes = try container.decodeIfPresent(Double.self, forKey: .averageDurationMinutes)
        combinedCostIndex = try container.decodeIfPresent(Double.self, forKey: .combinedCostIndex)
        rule = try container.decodeIfPresent(String.self, forKey: .rule)
        // trend_48h 上游可能给字符串或数字，宽松解码为字符串。
        if let s = try? container.decodeIfPresent(String.self, forKey: .trend48h) {
            trend48h = s
        } else if let d = try? container.decodeIfPresent(Double.self, forKey: .trend48h) {
            trend48h = String(format: "%.2f", d)
        } else {
            trend48h = nil
        }
    }
}

// MARK: - https://codexradar.com/api/intelligence-efficiency-metrics（智力效率，权威指标源）

/// 智力效率响应：兼容 schema 2/3；points 逐项容错，identity = model + effort。
struct EfficiencyResponse: Decodable {
    let schema: Int
    let sourceUpdatedAt: String?
    let points: [EfficiencyPointDTO]

    enum CodingKeys: String, CodingKey {
        case schema, points
        case sourceUpdatedAt = "source_updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        sourceUpdatedAt = try container.decodeIfPresent(String.self, forKey: .sourceUpdatedAt)

        var pointsContainer = try container.nestedUnkeyedContainer(forKey: .points)
        var decoded: [EfficiencyPointDTO] = []
        while !pointsContainer.isAtEnd {
            if let point = try? pointsContainer.decode(EfficiencyPointDTO.self) {
                decoded.append(point)
            } else {
                _ = try? pointsContainer.decode(IgnoredJSONValue.self)
            }
        }
        points = decoded
    }
}

/// 单个智力效率数据点。
struct EfficiencyPointDTO: Decodable {
    let model: String
    let effort: String
    let iq: Double
    let passed: Int?
    let validTasks: Int?
    let averagePriceUSD: Double?
    let averageMinutes: Double?
    let combinedCostIndex: Double?

    enum CodingKeys: String, CodingKey {
        case model, effort, iq, passed, total
        case validTasks = "valid_tasks"
        case averagePriceUSD = "average_price_usd"
        case averageMinutes = "average_minutes"
        case combinedCostIndex = "combined_cost_index"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        effort = try container.decode(String.self, forKey: .effort)
        iq = try container.decode(Double.self, forKey: .iq)
        passed = container.decodeRoundedIntIfPresent(forKey: .passed)
        validTasks = container.decodeRoundedIntIfPresent(forKey: .validTasks)
            ?? container.decodeRoundedIntIfPresent(forKey: .total)
        averagePriceUSD = try container.decodeIfPresent(Double.self, forKey: .averagePriceUSD)
        averageMinutes = try container.decodeIfPresent(Double.self, forKey: .averageMinutes)
        combinedCostIndex = try container.decodeIfPresent(Double.self, forKey: .combinedCostIndex)
    }
}

// MARK: - https://claudecoderadar.com/data/claude-code-radar.json

/// Claude 参考数据源：iq.models[] 每个模型带 name + 历史序列数组（iq/pass/valid/cost/time），
/// 数组元素可能为 null（当日缺测），取最后一个非 null 值作为最新结果。time 单位为小时。
struct ClaudeRadarResponse: Decodable {
    let iq: ClaudeIQBlock
}

struct ClaudeIQBlock: Decodable {
    let models: [ClaudeModelSeries]
}

/// 单个 Claude 配置的历史序列（数组元素可为 null）。
struct ClaudeModelSeries: Decodable {
    let name: String            // "Opus 4.8 xhigh" / "Haiku 4.5"
    let iq: [Double?]
    let pass: [Double?]
    let valid: [Double?]
    let cost: [Double?]
    let time: [Double?]         // 小时

    private enum CodingKeys: String, CodingKey {
        case name, label, iq, pass, valid, cost, time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 真实数据用 name；兼容旧的 label 字段
        if let name = try container.decodeIfPresent(String.self, forKey: .name) {
            self.name = name
        } else {
            self.name = try container.decode(String.self, forKey: .label)
        }
        iq = try container.decode([Double?].self, forKey: .iq)
        pass = try container.decode([Double?].self, forKey: .pass)
        valid = try container.decode([Double?].self, forKey: .valid)
        cost = try container.decode([Double?].self, forKey: .cost)
        time = try container.decode([Double?].self, forKey: .time)
    }
}

// MARK: - Radar Bench（radar-bench-binding.json / radar-bench-score）

/// 通用 JSON 值：Radar Bench 响应先整体解成它，再由 RadarBenchParser 按需取字段。
/// 原始值随观测一并保留（缓存也存它），网站新增的未知字段不会在解析中丢失。
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }
    var objectValue: [String: JSONValue]? { if case .object(let dict) = self { return dict } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let items) = self { return items } else { return nil } }
    var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }

    var stringValue: String? { if case .string(let value) = self { return value } else { return nil } }

    /// 有限数值（NaN / Inf 不可能出自合法 JSON，仍防御）。
    var doubleValue: Double? {
        if case .number(let value) = self, value.isFinite { return value }
        return nil
    }

    /// 整数值：数字必须是整数（78.5 不是整数），且在 Int 范围内。
    var intValue: Int? {
        guard let value = doubleValue, value == value.rounded(), abs(value) < 9e15 else { return nil }
        return Int(value)
    }
}
