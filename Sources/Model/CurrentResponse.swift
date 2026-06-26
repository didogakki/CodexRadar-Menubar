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
