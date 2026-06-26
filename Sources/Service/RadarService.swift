// 拉取并解析数据：current.json（Codex 评分主源 + 时间戳，必需）+ HTML 对比表（Claude 参考列，best-effort）。
import Foundation

enum RadarServiceError: LocalizedError {
    case http(Int)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "服务器返回 \(code)"
        case .network(let msg): return msg
        case .decode(let msg): return msg
        }
    }
}

struct RadarService {
    let htmlURL = URL(string: "https://codexradar.com/")!
    let jsonURL = URL(string: "https://codexradar.com/current.json")!

    func fetch() async throws -> RadarSnapshot {
        // 并发拉取：JSON 是 Codex 主源（必需），HTML 仅供 Claude 参考列（best-effort）。
        async let jsonData = data(from: jsonURL, timeout: 10)
        async let htmlData = try? data(from: htmlURL, timeout: 20)

        // 主源：current.json → Codex。拉取或解析失败即致命错误（走 lastError）。
        let json: Data
        do {
            json = try await jsonData
        } catch let e as RadarServiceError {
            throw e
        }
        let codex: [ModelResult]
        do {
            codex = try RadarParser.parseCodex(json: json)
        } catch {
            throw RadarServiceError.decode((error as? LocalizedError)?.errorDescription ?? "current.json 解析失败")
        }

        // best-effort：HTML → Claude 参考列。任何失败或 0 个 Claude 都降级，绝不影响 Codex。
        let claude: [ModelResult] = (await htmlData)
            .map { String(decoding: $0, as: UTF8.self) }
            .flatMap { try? RadarParser.parseClaude(html: $0) } ?? []
        let claudeStatus: ClaudeStatus = claude.isEmpty ? .unavailable : .ok

        let models: [ScoredModel]
        do {
            models = try RadarParser.scoreAndSort(codex + claude)
        } catch {
            throw RadarServiceError.decode((error as? LocalizedError)?.errorDescription ?? "数据解析失败")
        }

        // 时间戳：JSON 的 quota_radar.updated_at；失败则回退到当前时间，不致命。
        let updatedAt = RadarParser.parseTimestamp(json: json) ?? Date()

        return RadarSnapshot(all: models, updatedAt: updatedAt, claudeStatus: claudeStatus)
    }

    private func data(from url: URL, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RadarServiceError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RadarServiceError.http(http.statusCode)
        }
        return data
    }
}
