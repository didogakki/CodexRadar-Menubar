// 拉取并解析 current.json。
import Foundation

enum RadarServiceError: LocalizedError {
    case http(Int)
    case network(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "服务器返回 \(code)"
        case .network(let msg): return msg
        case .decode: return "数据解析失败"
        }
    }
}

struct RadarService {
    let url = URL(string: "https://codexradar.com/current.json")!

    func fetch() async throws -> RadarSnapshot {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20

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

        do {
            return try RadarParser.parse(data)
        } catch {
            throw RadarServiceError.decode(String(describing: error))
        }
    }
}
