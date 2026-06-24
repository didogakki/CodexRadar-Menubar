// 解码层 —— 严格对应 https://codexradar.com/current.json 的【真实】结构。
//
// 与交接稿 DataModel.swift 的差异（已对真实接口核对）：
//   • 没有 model_iq.scoreboard 数组；评分分散在 model_iq.latest（主条目）
//     + model_iq.comparisons.<动态key>.latest（若干对比条目），需在 Parser 里拼装。
//   • 每条用 model / reasoning_effort，而非 name / tag。
//   • 24h 重置概率在 prediction.probability_24h（0...1），不在 quota_radar.reset_24h。
//   • quota_radar.updated_at 存在且正确（ISO8601 UTC）。
import Foundation

struct CurrentResponse: Decodable {
    let prediction: Prediction
    let modelIQ: ModelIQBlock

    enum CodingKeys: String, CodingKey {
        case prediction
        case modelIQ = "model_iq"
    }
}

struct Prediction: Decodable {
    let probability24h: Double?

    enum CodingKeys: String, CodingKey {
        case probability24h = "probability_24h"
    }
}

struct ModelIQBlock: Decodable {
    let quotaRadar: QuotaRadar
    let latest: Run?                       // 主条目（如 gpt-5.5 xhigh）
    let comparisons: [String: Comparison]  // 动态键：gpt_54_xhigh / gpt_55_high / ...

    enum CodingKeys: String, CodingKey {
        case quotaRadar = "quota_radar"
        case latest, comparisons
    }
}

struct QuotaRadar: Decodable {
    let updatedAt: String                  // "2026-06-24T04:58:05Z"

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
    }
}

struct Comparison: Decodable {
    let latest: Run?
}

/// model_iq.latest 与 comparisons.*.latest 共用的运行结果。
struct Run: Decodable {
    let model: String
    let reasoningEffort: String
    let score: Double
    let status: String
    let passed: Int
    let tasks: Int

    enum CodingKeys: String, CodingKey {
        case model, score, status, passed, tasks
        case reasoningEffort = "reasoning_effort"
    }
}
