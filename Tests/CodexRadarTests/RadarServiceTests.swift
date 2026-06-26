// 覆盖 RadarService.fetch 的集成路径：current.json 成功 + HTML 失败时应仍返回 Codex 组，并标记 Claude unavailable。
import XCTest
@testable import CodexRadar

/// 拦截 URLSession.shared 的请求，按 URL 返回预设的响应或错误，免去给 RadarService 引入依赖注入。
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let data: Data
        let statusCode: Int
    }

    static var stubs: [String: Stub] = [:]
    static var errors: [String: Error] = [:]

    static func reset() {
        stubs = [:]
        errors = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return stubs[url.absoluteString] != nil || errors[url.absoluteString] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if let error = Self.errors[url.absoluteString] {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let stub = Self.stubs[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class RadarServiceTests: XCTestCase {

    private let codexJSON = """
    {
      "model_iq": {
        "latest": {
          "score": 50.0, "passed": 4, "tasks": 12,
          "wall_seconds": 1483, "model": "gpt-5.5", "reasoning_effort": "xhigh",
          "cost_usd": 41.405896
        },
        "quota_radar": { "updated_at": "2026-06-26T05:44:34Z" }
      }
    }
    """

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testFetch_jsonSucceeds_htmlFails_returnsCodexGroupAndMarksClaudeUnavailable() async throws {
        let service = RadarService()
        StubURLProtocol.stubs[service.jsonURL.absoluteString] = .init(data: Data(codexJSON.utf8), statusCode: 200)
        StubURLProtocol.errors[service.htmlURL.absoluteString] = URLError(.timedOut)

        let snapshot = try await service.fetch()

        XCTAssertFalse(snapshot.codexGroup.isEmpty)
        XCTAssertTrue(snapshot.claudeGroup.isEmpty)
        switch snapshot.claudeStatus {
        case .unavailable: break
        case .ok: XCTFail("expected claudeStatus to be .unavailable when HTML fetch fails")
        }
    }

    func testFetch_jsonFails_throwsAndNeverReturnsSnapshot() async throws {
        let service = RadarService()
        StubURLProtocol.errors[service.jsonURL.absoluteString] = URLError(.timedOut)
        StubURLProtocol.stubs[service.htmlURL.absoluteString] = .init(data: Data(), statusCode: 200)

        do {
            _ = try await service.fetch()
            XCTFail("expected fetch() to throw when current.json fetch fails")
        } catch {
            // JSON 是主源，失败必须致命，不能静默返回空快照。
        }
    }
}
