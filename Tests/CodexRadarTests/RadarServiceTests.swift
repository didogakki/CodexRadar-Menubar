// 覆盖 Radar Bench（radar-bench-v2-150）取数链路：RadarService 的读取 / 重试 / 并发 / 缓存，
// 以及 RadarViewModel 的逐档合并（部分失败不覆盖成功行、换基准作废缓存、后台只补读过期档位、偏好不被刷新重置）。
// 旧 insights / efficiency / current.json 的 fetch() 契约测试已随该数据源一并替换为下面的新契约测试。
import XCTest
@testable import CodexRadar

/// 拦截 URLSession.shared 的请求，按 URL 返回预设的响应或错误，免去给 RadarService 引入依赖注入。
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var data: Data
        var statusCode: Int
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    private static var _stubs: [String: Stub] = [:]
    private static var _sequences: [String: [Stub]] = [:]
    private static var _errors: [String: Error] = [:]
    private static var _log: [(url: String, headers: [String: String])] = []
    private static var _inFlight = 0
    private static var _maxInFlight = 0

    static var stubs: [String: Stub] {
        get { lock.lock(); defer { lock.unlock() }; return _stubs }
        set { lock.lock(); _stubs = newValue; lock.unlock() }
    }

    /// 同一 URL 的多次响应按顺序消费，最后一个重复使用（用来模拟「先繁忙后成功」）。
    static var sequences: [String: [Stub]] {
        get { lock.lock(); defer { lock.unlock() }; return _sequences }
        set { lock.lock(); _sequences = newValue; lock.unlock() }
    }

    static var errors: [String: Error] {
        get { lock.lock(); defer { lock.unlock() }; return _errors }
        set { lock.lock(); _errors = newValue; lock.unlock() }
    }

    /// 实际发起过的请求（URL + 请求头）。
    static var requestLog: [(url: String, headers: [String: String])] {
        lock.lock(); defer { lock.unlock() }; return _log
    }
    static var requestedURLs: [String] { requestLog.map(\.url) }
    static var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }

    static func reset() {
        lock.lock()
        _stubs = [:]; _sequences = [:]; _errors = [:]; _log = []; _inFlight = 0; _maxInFlight = 0
        lock.unlock()
    }

    private static func known(_ url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _stubs[url] != nil || _sequences[url] != nil || _errors[url] != nil
    }

    private static func nextStub(for url: String) -> Stub? {
        lock.lock(); defer { lock.unlock() }
        if var queue = _sequences[url], !queue.isEmpty {
            let first = queue[0]
            if queue.count > 1 { queue.removeFirst(); _sequences[url] = queue }
            return first
        }
        return _stubs[url]
    }

    private static func begin(_ url: String, headers: [String: String]) {
        lock.lock()
        _log.append((url, headers))
        _inFlight += 1
        _maxInFlight = max(_maxInFlight, _inFlight)
        lock.unlock()
    }

    private static func end() { lock.lock(); _inFlight -= 1; lock.unlock() }

    private static func error(for url: String) -> Error? { lock.lock(); defer { lock.unlock() }; return _errors[url] }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return known(url.absoluteString)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        Self.begin(key, headers: request.allHTTPHeaderFields ?? [:])
        if let error = Self.error(for: key) {
            Self.end()
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard var stub = Self.nextStub(for: key) else {
            Self.end()
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // 与站点一致：评分接口不带选择头返回 428。
        if url.path == "/api/radar-bench-score",
           request.value(forHTTPHeaderField: RadarService.selectionHeaderField) != RadarService.selectionHeaderValue {
            stub = Stub(data: Data("{}".utf8), statusCode: 428)
        }
        let respond = { [self] in
            let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
            Self.end()
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: respond)
        } else {
            respond()
        }
    }

    override func stopLoading() {}
}

/// 记录 RadarService 的退避 / Retry-After 等待，免去真实睡眠。
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [TimeInterval] = []
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return _values }
    func record(_ seconds: TimeInterval) { lock.lock(); _values.append(seconds); lock.unlock() }
}

/// 线程安全的可控时钟，给 RadarService 的共享冷却注入（worker 在多个线程上读写）。
final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

/// 可控等待闸门：sleep 记录时长并挂起，直到测试 `releaseNext()` / `openAll()`；释放时按时长推进时钟。
/// 任务取消会唤醒挂起的 sleep（与真实 Task.sleep 一致）。没有任何真实睡眠，也不会空转。
final class ManualSleeper: @unchecked Sendable {
    private typealias Waiter = (seconds: TimeInterval, continuation: CheckedContinuation<Bool, Never>)

    private let lock = NSLock()
    private let clock: LockedClock
    private var recorded: [TimeInterval] = []
    private var order: [UUID] = []
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledEarly = Set<UUID>()
    private var isOpen = false

    init(clock: LockedClock) { self.clock = clock }

    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }
    var waitingCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }

    func sleep(_ seconds: TimeInterval) async {
        if recordAndCheckOpen(seconds) { clock.advance(seconds); return }
        let id = UUID()
        let released = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                register(id, seconds, continuation)
            }
        } onCancel: {
            self.cancel(id)
        }
        if released { clock.advance(seconds) }
    }

    /// 放行最早挂起的一个 sleep。
    func releaseNext() {
        lock.lock()
        var next: Waiter?
        while !order.isEmpty, next == nil { next = waiters.removeValue(forKey: order.removeFirst()) }
        lock.unlock()
        next?.continuation.resume(returning: true)
    }

    /// 之后所有 sleep（含已挂起的）都立即返回；用于测试收尾，保证批次一定能结束。
    func openAll() {
        lock.lock()
        isOpen = true
        let all = Array(waiters.values)
        waiters = [:]; order = []
        lock.unlock()
        all.forEach { $0.continuation.resume(returning: true) }
    }

    private func recordAndCheckOpen(_ seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recorded.append(seconds)
        return isOpen
    }

    private func register(_ id: UUID, _ seconds: TimeInterval, _ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if cancelledEarly.contains(id) {
            lock.unlock(); continuation.resume(returning: false)
        } else if isOpen {
            lock.unlock(); continuation.resume(returning: true)
        } else {
            order.append(id); waiters[id] = (seconds, continuation)
            lock.unlock()
        }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if waiter == nil { cancelledEarly.insert(id) }
        lock.unlock()
        waiter?.continuation.resume(returning: false)
    }
}

/// 线程安全的回调记录（onResult 在 MainActor 上，断言在测试线程上）。
final class BatchResultLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(id: String, success: Bool)] = []
    var entries: [(id: String, success: Bool)] { lock.lock(); defer { lock.unlock() }; return _entries }
    func record(_ id: String, success: Bool) { lock.lock(); _entries.append((id, success)); lock.unlock() }
}

/// 可手动拨动的时钟（ViewModel 的 now 注入）。
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// 2026-10-18 站点现行契约的测试夹具。`realSummaryJSON` 是线上 gpt-6.1-sol / medium 的真实响应原文
/// （含 79/80 费用样本、微秒级 latest_graded_at、history 等），其余档位由它改写 model/effort/score 等字段得到。
enum BenchFixtures {
    static let benchmark = "radar-bench-final64-20261004"
    static let catalog = "dradar-four-library-deployment007-server024-20261004-config64"
    static let sha = "f75ff09b6117cd83d3ab6ea744fe379ac117676c042538d5df5e38489af27bc4"

    static let layout: [(model: String, efforts: [String])] = [
        ("gpt-6.1-sol", ["low", "medium", "high", "xhigh", "max", "ultra"]),
        ("gpt-6-astra", ["low", "medium", "high", "xhigh", "max", "ultra"]),
        ("gpt-6-sol", ["low", "medium", "high", "xhigh", "max", "ultra"]),
        ("gpt-6-luna", ["low", "medium", "high", "xhigh", "max"]),
        ("gpt-5.6-sol", ["low", "medium", "high", "xhigh", "max", "ultra"]),
        ("gpt-5.6-luna", ["low", "medium", "high", "xhigh", "max"]),
    ]
    static var selections: [BenchSelection] {
        layout.flatMap { item in item.efforts.map { BenchSelection(model: item.model, effort: $0) } }
    }

    static let realSummaryJSON = #"""
{"schema":"radar-bench-public-summary-v6-150-details","benchmark":"radar-bench-final64-20261004","score_version":"radar-bench-v2-150","score_max":150,"catalog_version":"dradar-four-library-deployment007-server024-20261004-config64","task_set_sha256":"f75ff09b6117cd83d3ab6ea744fe379ac117676c042538d5df5e38489af27bc4","model":"gpt-6.1-sol","effort":"medium","score":78.2121020962733,"coverage":64,"required_tasks":64,"score_status":"complete","graded_runs_count":80,"source_counts":{"deepswe":15,"pompeii":16,"tb4":14,"science":19},"scoring_policy_version":"radar-bench-v2-last3-per-task-equal-weight-150","source_scores":{"deepswe":{"score":100,"coverage":15,"required_tasks":15,"graded_runs_count":22},"pompeii":{"score":120.66090838509317,"coverage":16,"required_tasks":16,"graded_runs_count":16},"tb4":{"score":69.64285714285714,"coverage":14,"required_tasks":14,"graded_runs_count":20},"science":{"score":31.57894736842105,"coverage":19,"required_tasks":19,"graded_runs_count":22}},"statistics":{"sample_count":80,"cost_basis":"official_standard_api_equivalent; no estimates or claimed cash charges","metrics":{"elapsed_ms":{"total":47805382.86827114,"mean":597567.2858533893,"known_total":47805382.86827114,"known_samples":80,"missing_samples":0,"missing_reason":null},"api_equivalent_usd":{"total":null,"mean":null,"known_total":28.957456,"known_samples":79,"missing_samples":1,"missing_reason":"source_evidence_incomplete"}}},"statistics_state":"available","detail_metrics":{"valid_grade_events":80,"latest_graded_at":"2026-10-18T00:59:23.459695Z","as_of":"2026-10-18T07:23:00.209Z","graded_24h":4,"graded_48h":13,"metrics":{"total_tokens":{"known_total":90393953,"known_samples":79,"missing_samples":1},"input_tokens":{"known_total":89346730,"known_samples":79,"missing_samples":1},"output_tokens":{"known_total":1047223,"known_samples":79,"missing_samples":1},"cache_tokens":{"known_total":84320128,"known_samples":79,"missing_samples":1},"reasoning_tokens":{"known_total":407768,"known_samples":79,"missing_samples":1},"cache_write_tokens":{"known_total":0,"known_samples":79,"missing_samples":1},"turn_count":{"known_total":79,"known_samples":79,"missing_samples":1}},"metrics_state":"available"},"history":{"schema":"radar-bench-public-history-v1-150-daily","score_version":"radar-bench-v2-150","score_max":150,"model":"gpt-6.1-sol","effort":"medium","time_zone":"UTC","bucket":"day","basis":"last canonical score per UTC grading day; days without grades omitted","updated_bucket":"2026-10-18T00:00:00.000Z","points":[{"at":"2026-10-06T00:00:00.000Z","score":0,"coverage":1,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-09T00:00:00.000Z","score":76.91535461505127,"coverage":43,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-10T00:00:00.000Z","score":76.83022774327122,"coverage":45,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-11T00:00:00.000Z","score":78.34809039249373,"coverage":47,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-13T00:00:00.000Z","score":75.14431859700402,"coverage":51,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-14T00:00:00.000Z","score":76.58385093167702,"coverage":52,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-15T00:00:00.000Z","score":75.13630089717046,"coverage":54,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-16T00:00:00.000Z","score":78.94935884592265,"coverage":62,"required_tasks":64,"score_status":"provisional"},{"at":"2026-10-17T00:00:00.000Z","score":79.3839770962733,"coverage":64,"required_tasks":64,"score_status":"complete"},{"at":"2026-10-18T00:00:00.000Z","score":78.2121020962733,"coverage":64,"required_tasks":64,"score_status":"complete"}]},"history_state":"available"}
"""#

    static func realSummaryObject() -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(realSummaryJSON.utf8)) as! [String: Any]
    }

    static func bindingData(
        benchmark: String = benchmark, sha: String = sha, enabled: Bool = true, verified: Bool = true,
        selections: [BenchSelection] = selections, extra: [String: Any] = [:]
    ) -> Data {
        var object: [String: Any] = [
            "enabled": enabled, "interface_confirmed": true, "production_read_verified": verified,
            "active_display_selection": ["model": "gpt-6.1-sol", "effort": "low"],
            "transport_origin": "https://api.codexradar.com", "endpoint_path": "/api/v1/radar-bench-score",
            "benchmark": benchmark, "catalog_version": catalog, "task_set_sha256": sha,
            "total_tasks": 64, "total_cells": 320,
            "source_counts": ["deepswe": 15, "pompeii": 16, "tb4": 14, "science": 19],
            "model_efforts": selections.map { ["model": $0.model, "effort": $0.effort] },
            "members": [["source_benchmark": "deepswe15-20261003-v4", "collection_id": "deepswe", "task_id": "igel-persist-feature-schema"]],
            "score_version": "radar-bench-v2-150", "score_max": 150,
        ]
        for (key, value) in extra { object[key] = value }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// 由真实样本改写出某档位的成绩响应。`score` 传 NSNull() 表示 null。
    static func summaryObject(
        _ selection: BenchSelection, score: Any = 90.0, coverage: Int = 64, status: String = "complete",
        costKnown: Int = 80, costMissing: Int = 0, costTotal: Double = 28.0,
        sha: String = sha, benchmark: String = benchmark
    ) -> [String: Any] {
        var object = realSummaryObject()
        object["model"] = selection.model
        object["effort"] = selection.effort
        object["score"] = score
        object["coverage"] = coverage
        object["score_status"] = status
        object["task_set_sha256"] = sha
        object["benchmark"] = benchmark
        var statistics = object["statistics"] as! [String: Any]
        var metrics = statistics["metrics"] as! [String: Any]
        metrics["api_equivalent_usd"] = [
            "total": costMissing == 0 ? costTotal : NSNull(),
            "mean": costMissing == 0 ? costTotal / Double(max(costKnown, 1)) : NSNull(),
            "known_total": costTotal, "known_samples": costKnown, "missing_samples": costMissing,
            "missing_reason": costMissing == 0 ? NSNull() : "source_evidence_incomplete",
        ] as [String: Any]
        statistics["metrics"] = metrics
        object["statistics"] = statistics
        return object
    }

    static func summaryData(_ selection: BenchSelection, score: Any = 90.0, coverage: Int = 64, status: String = "complete",
                            costKnown: Int = 80, costMissing: Int = 0, costTotal: Double = 28.0,
                            sha: String = sha, benchmark: String = benchmark) -> Data {
        let object = summaryObject(selection, score: score, coverage: coverage, status: status,
                                   costKnown: costKnown, costMissing: costMissing, costTotal: costTotal,
                                   sha: sha, benchmark: benchmark)
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// 默认分数：按绑定顺序递减（第一个 = gpt-6.1-sol/low 为最高分）。
    static func defaultScore(_ selection: BenchSelection) -> Double {
        let index = selections.firstIndex(of: selection) ?? 0
        return 120 - Double(index) * 2
    }

    static let t0 = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
}

final class RadarServiceTests: XCTestCase {

    private var sleeps: SleepRecorder!
    private var serviceClock: LockedClock!
    private var suiteNames: [String] = []

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(StubURLProtocol.self)
        sleeps = SleepRecorder()
        serviceClock = LockedClock(BenchFixtures.t0)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames = []
        super.tearDown()
    }

    /// 记录型 sleep 同时推进可控时钟：共享冷却按这条时钟计算，等待立即返回但冷却确实走完。
    private func makeService() -> RadarService {
        let recorder = sleeps!, clock = serviceClock!
        return RadarService(sleep: { recorder.record($0); clock.advance($0) }, now: { clock.now })
    }

    /// 等待由测试闸门控制的服务（释放前不会继续，也不依赖真实时间流逝）。
    private func makeGatedService(_ sleeper: ManualSleeper) -> RadarService {
        let clock = serviceClock!
        return RadarService(sleep: { await sleeper.sleep($0) }, now: { clock.now })
    }

    /// 有限时长轮询（只用于等 worker 进入挂起点，超时即失败，绝不无限等待）。
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    private func requestCount(_ url: URL) -> Int {
        StubURLProtocol.requestedURLs.filter { $0 == url.absoluteString }.count
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "codexradar.tests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// 绑定 + 全部 34 档成功（默认分数递减）。
    private func stubHappyPath(_ service: RadarService, binding: Data = BenchFixtures.bindingData()) {
        StubURLProtocol.stubs[service.bindingURL.absoluteString] = .init(data: binding, statusCode: 200)
        for selection in BenchFixtures.selections {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] =
                .init(data: BenchFixtures.summaryData(selection, score: BenchFixtures.defaultScore(selection)), statusCode: 200)
        }
    }

    private func scoreRequestCount() -> Int {
        StubURLProtocol.requestedURLs.filter { $0.contains("/api/radar-bench-score") }.count
    }

    @MainActor
    private func makeVM(_ service: RadarService, clock: TestClock, defaults: UserDefaults? = nil) -> RadarViewModel {
        RadarViewModel(service: service, cacheDefaults: defaults ?? isolatedDefaults(), now: { clock.now })
    }

    // MARK: - URL / 请求形态

    func testServiceOnlyTargetsCodexRadarHostAndScoreURLShape() {
        let service = RadarService()
        XCTAssertEqual(service.bindingURL.host, "codexradar.com")
        XCTAssertEqual(service.bindingURL.path, "/data/radar-bench-binding.json")
        let url = service.scoreURL(for: BenchSelection(model: "gpt-6.1-sol", effort: "medium"))
        XCTAssertEqual(url.host, "codexradar.com")
        XCTAssertEqual(url.absoluteString,
                       "https://codexradar.com/api/radar-bench-score?model=gpt-6.1-sol&effort=medium&view=summary")
    }

    func testFetchObservation_sendsSelectionHeader_andParsesRealSample() async throws {
        let service = makeService()
        let selection = BenchSelection(model: "gpt-6.1-sol", effort: "medium")
        StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] =
            .init(data: Data(BenchFixtures.realSummaryJSON.utf8), statusCode: 200)
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())

        let observation = try await service.fetchObservation(selection, binding: binding)

        let sent = StubURLProtocol.requestLog.first?.headers[RadarService.selectionHeaderField]
        XCTAssertEqual(sent, "user-selected-v1", "评分接口必须带 X-Radar-Bench-Selection，否则站点返回 428")
        XCTAssertEqual(observation.score!, 78.2121020962733, accuracy: 1e-9)
        XCTAssertEqual(observation.coverage, 64)
    }

    // MARK: - 批量读取：去重 / 并发 ≤ 3 / 重试 / 暂停

    func testFetchBatch_dedupesSelections_andBoundsConcurrencyToThree() async throws {
        let service = makeService()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let picked = Array(BenchFixtures.selections.prefix(8))
        for selection in picked {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] =
                .init(data: BenchFixtures.summaryData(selection), statusCode: 200, delay: 0.08)
        }

        let outcome = await service.fetchBatch(binding: binding, selections: picked + picked.prefix(4)) { _, _ in }

        XCTAssertEqual(outcome.succeeded, 8)
        XCTAssertEqual(scoreRequestCount(), 8, "重复档位只请求一次")
        XCTAssertLessThanOrEqual(StubURLProtocol.maxInFlight, RadarBenchPolicy.concurrency)
        XCTAssertGreaterThanOrEqual(StubURLProtocol.maxInFlight, 2, "应当确实并发而不是串行")
    }

    func testFetchBatch_busyResponseRetriesHonoringRetryAfter() async throws {
        let service = makeService()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let selection = BenchFixtures.selections[0]
        let url = service.scoreURL(for: selection).absoluteString
        StubURLProtocol.sequences[url] = [
            .init(data: Data("busy".utf8), statusCode: 503, headers: ["Retry-After": "7"]),
            .init(data: BenchFixtures.summaryData(selection), statusCode: 200),
        ]

        let outcome = await service.fetchBatch(binding: binding, selections: [selection]) { _, _ in }

        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0 == url }.count, 2)
        XCTAssertEqual(sleeps.values, [7], "必须等满 Retry-After 再重试")
    }

    func testFetchBatch_retriesAreFinite() async throws {
        let service = makeService()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let selection = BenchFixtures.selections[0]
        let url = service.scoreURL(for: selection).absoluteString
        StubURLProtocol.stubs[url] = .init(data: Data("busy".utf8), statusCode: 502)

        let outcome = await service.fetchBatch(binding: binding, selections: [selection]) { _, _ in }

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0 == url }.count, RadarBenchPolicy.maxAttempts)
        XCTAssertEqual(sleeps.values.count, RadarBenchPolicy.maxAttempts - 1)
    }

    func testFetchBatch_longRetryAfterPausesWholeBatchWithoutWaiting() async throws {
        let service = makeService()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let picked = Array(BenchFixtures.selections.prefix(9))
        for selection in picked {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] =
                .init(data: Data("slow down".utf8), statusCode: 429, headers: ["Retry-After": "120"])
        }

        let outcome = await service.fetchBatch(binding: binding, selections: picked) { _, _ in }

        XCTAssertEqual(outcome.retryAfter, 120)
        XCTAssertNotNil(outcome.stopReason)
        XCTAssertGreaterThan(outcome.skipped, 0, "暂停后剩余档位不再发请求")
        XCTAssertLessThan(scoreRequestCount(), picked.count)
        XCTAssertTrue(sleeps.values.isEmpty, "超过上限的 Retry-After 不在本轮里睡等")
    }

    func testFetchBatch_428StopsBatch() async throws {
        let service = makeService()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let picked = Array(BenchFixtures.selections.prefix(9))
        for selection in picked {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] =
                .init(data: Data("{}".utf8), statusCode: 428)
        }

        let outcome = await service.fetchBatch(binding: binding, selections: picked) { _, _ in }

        XCTAssertNotNil(outcome.stopReason)
        XCTAssertLessThan(scoreRequestCount(), picked.count)
        XCTAssertTrue(sleeps.values.isEmpty, "428 是确定性拒绝，不重试")
    }

    // MARK: - 批量读取：并发叫停 / 冷却延长 / 取消（可控闸门，不依赖真实等待）

    /// s0 先繁忙（Retry-After 10，重试在冷却里等）；s1 成功后其 worker 领取 s3 并卡在共享冷却里；
    /// s2 最后返回 `stopStub` 叫停整批。叫停通知（s2 的回调）才放行所有等待。
    /// 叫停后：s0 的重试、s3（已领取未发送）、s4（未领取）都不能再发请求。
    private func runConcurrentStopScenario(stopStub: StubURLProtocol.Stub) async throws -> (RadarBenchBatchOutcome, [BenchSelection], BatchResultLog) {
        let sleeper = ManualSleeper(clock: serviceClock)
        let service = makeGatedService(sleeper)
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let picked = Array(BenchFixtures.selections.prefix(5))
        func url(_ i: Int) -> String { service.scoreURL(for: picked[i]).absoluteString }
        StubURLProtocol.sequences[url(0)] = [
            .init(data: Data("busy".utf8), statusCode: 503, headers: ["Retry-After": "10"]),
            .init(data: BenchFixtures.summaryData(picked[0]), statusCode: 200),
        ]
        StubURLProtocol.stubs[url(1)] = .init(data: BenchFixtures.summaryData(picked[1]), statusCode: 200, delay: 0.15)
        var stop = stopStub
        stop.delay = 0.5
        StubURLProtocol.stubs[url(2)] = stop
        for i in 3...4 {
            StubURLProtocol.stubs[url(i)] = .init(data: BenchFixtures.summaryData(picked[i]), statusCode: 200)
        }

        let log = BatchResultLog()
        let stopper = picked[2].id
        let outcome = await service.fetchBatch(binding: binding, selections: picked) { selection, result in
            if case .success = result { log.record(selection.id, success: true) } else { log.record(selection.id, success: false) }
            // 叫停已经生效（回调在 state.stop 之后），此时才放行所有挂起的等待。
            if selection.id == stopper { sleeper.openAll() }
        }
        sleeper.openAll()
        return (outcome, picked, log)
    }

    private func assertConcurrentStopClosesBatch(
        _ outcome: RadarBenchBatchOutcome, _ picked: [BenchSelection], _ log: BatchResultLog,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let service = RadarService()
        func count(_ i: Int) -> Int { requestCount(service.scoreURL(for: picked[i])) }
        XCTAssertEqual([count(0), count(1), count(2), count(3), count(4)], [1, 1, 1, 0, 0],
                       "叫停后：s0 的重试、已领取的 s3、未领取的 s4 都不能再发请求", file: file, line: line)
        XCTAssertNotNil(outcome.stopReason, file: file, line: line)
        XCTAssertEqual(outcome.succeeded, 1, "只有 s1 成功", file: file, line: line)
        XCTAssertEqual(outcome.failed, 2, "s0（已尝试、重试被叫停）与 s2（叫停者）计为失败", file: file, line: line)
        XCTAssertEqual(outcome.skipped, 2, "s3 已领取未发送 + s4 未领取 = skipped", file: file, line: line)
        XCTAssertEqual(outcome.cancelled, 0, file: file, line: line)
        XCTAssertEqual(outcome.succeeded + outcome.failed + outcome.skipped + outcome.cancelled, picked.count,
                       "统计必须闭合", file: file, line: line)
        // 回调只给「尝试过」的档位：s0 失败、s1 成功、s2 失败；skipped 的 s3 / s4 没有回调。
        let entries = log.entries
        XCTAssertEqual(Set(entries.map(\.id)), [picked[0].id, picked[1].id, picked[2].id], file: file, line: line)
        XCTAssertEqual(entries.first { $0.id == picked[1].id }?.success, true, file: file, line: line)
        XCTAssertEqual(entries.first { $0.id == picked[0].id }?.success, false, file: file, line: line)
    }

    func testFetchBatch_concurrentLongRetryAfterStop_claimedAndRetryingTasksNeverSend() async throws {
        let (outcome, picked, log) = try await runConcurrentStopScenario(
            stopStub: .init(data: Data("slow down".utf8), statusCode: 429, headers: ["Retry-After": "120"]))
        assertConcurrentStopClosesBatch(outcome, picked, log)
        XCTAssertEqual(outcome.retryAfter, 120)
    }

    func testFetchBatch_concurrent428Stop_claimedAndRetryingTasksNeverSend() async throws {
        let (outcome, picked, log) = try await runConcurrentStopScenario(
            stopStub: .init(data: Data("{}".utf8), statusCode: 428))
        assertConcurrentStopClosesBatch(outcome, picked, log)
        XCTAssertNil(outcome.retryAfter)
    }

    func testFetchBatch_cooldownExtendedWhileWaiting_wakingWorkerHonorsLatestDeadline() async throws {
        let sleeper = ManualSleeper(clock: serviceClock)
        let service = makeGatedService(sleeper)
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let picked = Array(BenchFixtures.selections.prefix(2))
        // s0：Retry-After 5 后重试成功。s1：稍后返回更长的 Retry-After 20，把共享冷却延长到 t0+20。
        StubURLProtocol.sequences[service.scoreURL(for: picked[0]).absoluteString] = [
            .init(data: Data("busy".utf8), statusCode: 503, headers: ["Retry-After": "5"]),
            .init(data: BenchFixtures.summaryData(picked[0]), statusCode: 200),
        ]
        StubURLProtocol.sequences[service.scoreURL(for: picked[1]).absoluteString] = [
            .init(data: Data("busy".utf8), statusCode: 503, headers: ["Retry-After": "20"], delay: 0.3),
            .init(data: BenchFixtures.summaryData(picked[1]), statusCode: 200),
        ]
        let task = Task { await service.fetchBatch(binding: binding, selections: picked) { _, _ in } }
        defer { sleeper.openAll() }

        let bothWaiting = await waitUntil { sleeper.waitingCount == 2 }
        XCTAssertTrue(bothWaiting, "两个 worker 都应在共享冷却里等")
        XCTAssertEqual(sleeper.values, [5, 20])
        XCTAssertEqual(scoreRequestCount(), 2)

        // 放行 s0 的 5 秒等待：冷却已被 s1 延长到 20 秒，醒来后只能再等剩下的 15 秒，不能直接重试。
        sleeper.releaseNext()
        let reWaiting = await waitUntil { sleeper.values.count == 3 && sleeper.waitingCount == 2 }
        XCTAssertTrue(reWaiting, "醒后应按最新截止时间继续等")
        XCTAssertEqual(sleeper.values, [5, 20, 15])
        XCTAssertEqual(requestCount(service.scoreURL(for: picked[0])), 1, "冷却未结束，s0 不能重试")
        XCTAssertEqual(scoreRequestCount(), 2)

        sleeper.openAll()
        let outcome = await task.value
        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(scoreRequestCount(), 4)
    }

    func testFetchBatch_cancelWhileWaitingOnCooldown_sendsNothingMoreAndClosesStats() async throws {
        let sleeper = ManualSleeper(clock: serviceClock)
        let service = makeGatedService(sleeper)
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let picked = Array(BenchFixtures.selections.prefix(5))
        // s0 繁忙 → 共享冷却；s1、s2 稍后成功，其 worker 领取 s3、s4 后卡在冷却里。
        StubURLProtocol.sequences[service.scoreURL(for: picked[0]).absoluteString] = [
            .init(data: Data("busy".utf8), statusCode: 503, headers: ["Retry-After": "5"]),
            .init(data: BenchFixtures.summaryData(picked[0]), statusCode: 200),
        ]
        for i in 1...4 {
            StubURLProtocol.stubs[service.scoreURL(for: picked[i]).absoluteString] =
                .init(data: BenchFixtures.summaryData(picked[i]), statusCode: 200, delay: i <= 2 ? 0.2 : 0)
        }
        let task = Task { await service.fetchBatch(binding: binding, selections: picked) { _, _ in } }
        defer { sleeper.openAll() }

        let allWaiting = await waitUntil { sleeper.waitingCount == 3 }
        XCTAssertTrue(allWaiting, "s0 的重试 + 已领取的 s3、s4 都应卡在冷却里")
        XCTAssertEqual(scoreRequestCount(), 3)

        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(scoreRequestCount(), 3, "取消后不再发任何请求")
        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertEqual(outcome.skipped, 0, "取消不是整批暂停")
        XCTAssertEqual(outcome.cancelled, 3, "s0（重试中）、s3、s4 被取消")
        XCTAssertNil(outcome.stopReason)
    }

    func testFetchBatch_identityMismatchIsFailureAndNotRetried() async throws {
        let service = makeService()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let selection = BenchFixtures.selections[0]
        let url = service.scoreURL(for: selection).absoluteString
        StubURLProtocol.stubs[url] = .init(
            data: BenchFixtures.summaryData(selection, sha: String(repeating: "0", count: 64)), statusCode: 200)

        let outcome = await service.fetchBatch(binding: binding, selections: [selection]) { _, _ in }

        XCTAssertEqual(outcome.failed, 1)
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0 == url }.count, 1)
    }

    func testRetryAfterParsing_secondsAndHTTPDate() {
        let url = URL(string: "https://codexradar.com/")!
        func response(_ value: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": value])!
        }
        XCTAssertEqual(RadarService.retryAfter(in: response("7")), 7)
        XCTAssertEqual(RadarService.retryAfter(in: response("1.5")), 1.5)
        XCTAssertNil(RadarService.retryAfter(in: response("-5")))
        XCTAssertNil(RadarService.retryAfter(in: response("soon")))
        let now = ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!
        XCTAssertEqual(RadarService.retryAfter(in: response("Sun, 18 Oct 2026 12:00:30 GMT"), now: now) ?? -1, 30, accuracy: 0.5)
    }

    func testFetchBinding_retriesBusyThenValidates() async throws {
        let service = makeService()
        StubURLProtocol.sequences[service.bindingURL.absoluteString] = [
            .init(data: Data(), statusCode: 503, headers: ["Retry-After": "3"]),
            .init(data: BenchFixtures.bindingData(), statusCode: 200),
        ]
        let binding = try await service.fetchBinding()
        XCTAssertEqual(binding.selections.count, 34)
        XCTAssertEqual(sleeps.values, [3])
    }

    // MARK: - 缓存存取

    func testStore_roundTripsObservationsAndDropsExpiredOnes() throws {
        let store = RadarBenchStore(defaults: isolatedDefaults())
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let fresh = BenchFixtures.selections[0], old = BenchFixtures.selections[1]
        let t0 = BenchFixtures.t0
        func entry(_ s: BenchSelection, at: Date) throws -> RadarBenchEntry {
            RadarBenchEntry(observation: try RadarBenchParser.parseObservation(
                json: BenchFixtures.summaryData(s), binding: binding, selection: s), fetchedAt: at)
        }
        store.save(binding: binding, entries: [
            fresh.id: try entry(fresh, at: t0.addingTimeInterval(-3600)),
            old.id: try entry(old, at: t0.addingTimeInterval(-25 * 3600)),
        ])

        let loaded = try XCTUnwrap(store.load(now: t0))
        XCTAssertEqual(loaded.binding, binding)
        XCTAssertEqual(Set(loaded.entries.keys), [fresh.id], "超过 24h 的观测载入时必须丢弃")
        XCTAssertEqual(loaded.entries[fresh.id]?.fetchedAt, t0.addingTimeInterval(-3600))
        XCTAssertNotNil(loaded.entries[fresh.id]?.observation?.raw["history"], "原始响应（含未建模字段）随缓存保留")
    }

    // MARK: - ViewModel：成功路径、读取时间 vs 评分时间、榜首

    @MainActor
    func testRefresh_success_separatesReadTimeFromGradedTime_andNamesChampionOnlyWhenComplete() async throws {
        let service = makeService()
        stubHappyPath(service)
        let clock = TestClock(BenchFixtures.t0)
        let vm = makeVM(service, clock: clock)

        await vm.refresh()

        let snapshot = try XCTUnwrap(vm.snapshot)
        XCTAssertEqual(snapshot.codexGroup.count, 34)
        XCTAssertEqual(snapshot.updatedAt, BenchFixtures.t0, "updatedAt 是成功读取时间")
        let graded = try XCTUnwrap(snapshot.benchmark?.latestGradedAt)
        let expectedGraded = ISO8601DateFormatter().date(from: "2026-10-18T00:59:23Z")!.timeIntervalSince1970 + 0.459
        XCTAssertEqual(graded.timeIntervalSince1970, expectedGraded, accuracy: 0.01)
        XCTAssertNotEqual(graded, snapshot.updatedAt, "评分时间来自接口，绝不等于读取时间或 Date()")
        XCTAssertNotNil(snapshot.gradedAtLabel)
        XCTAssertEqual(snapshot.menuBarBest?.id, "gpt-6.1-sol/low", "整批完整时才有榜首（分数最高者）")
        XCTAssertNil(vm.lastError)
        XCTAssertEqual(scoreRequestCount(), 34)
        // 每个评分请求都带选择头（桩对缺头返回 428，全部成功即说明都带了）。
        XCTAssertTrue(StubURLProtocol.requestLog.filter { $0.url.contains("/api/radar-bench-score") }
            .allSatisfy { $0.headers[RadarService.selectionHeaderField] == "user-selected-v1" })
    }

    @MainActor
    func testRefresh_partialFirstBatch_neverDeclaresChampion() async throws {
        let service = makeService()
        stubHappyPath(service)
        // 只有前 5 档成功，其余 500。
        for selection in BenchFixtures.selections.dropFirst(5) {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] = .init(data: Data("err".utf8), statusCode: 500)
        }
        let vm = makeVM(service, clock: TestClock(BenchFixtures.t0))

        await vm.refresh()

        let snapshot = try XCTUnwrap(vm.snapshot)
        XCTAssertEqual(snapshot.codexGroup.count, 5)
        XCTAssertNil(snapshot.menuBarBest, "局部批次的最高分不是全局冠军")
        XCTAssertEqual(StatusItemTitleBuilder.make(snapshot: snapshot).string, "◐ 6.1-sol·low 5/34")
        XCTAssertEqual(snapshot.provisionalMenuBarBest?.id, "gpt-6.1-sol/low")
        XCTAssertEqual(snapshot.menuBarDisplayedID, snapshot.provisionalMenuBarBest?.id)
        let detail = try XCTUnwrap(StatusItemTitleBuilder.detail(snapshot: snapshot, now: BenchFixtures.t0))
        XCTAssertTrue(detail.contains("不是全榜冠军"))
        XCTAssertTrue(detail.contains("5/34"))
        XCTAssertTrue(detail.contains("29 个档位最近一次刷新失败"))
        XCTAssertFalse(detail.contains("全榜榜首"))
        XCTAssertNotNil(vm.lastError)
    }

    // MARK: - ViewModel：部分失败不覆盖成功行

    @MainActor
    func testRefresh_partialFailure_keepsPreviousSuccessfulRows() async throws {
        let service = makeService()
        stubHappyPath(service)
        let clock = TestClock(BenchFixtures.t0)
        let vm = makeVM(service, clock: clock)
        await vm.refresh()
        let before = try XCTUnwrap(vm.snapshot)
        let failing = Array(BenchFixtures.selections[0..<3])

        clock.advance(600)
        for selection in failing {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] = .init(data: Data("err".utf8), statusCode: 500)
        }
        // 其余档位给新分数，证明成功行确实被更新。
        let updated = BenchFixtures.selections[10]
        StubURLProtocol.stubs[service.scoreURL(for: updated).absoluteString] =
            .init(data: BenchFixtures.summaryData(updated, score: 33.5), statusCode: 200)
        await vm.refresh()

        let after = try XCTUnwrap(vm.snapshot)
        XCTAssertEqual(after.codexGroup.count, 34, "失败的读取不能让成功行消失")
        for selection in failing {
            let row = try XCTUnwrap(after.codexGroup.first { $0.id == selection.id })
            let old = try XCTUnwrap(before.codexGroup.first { $0.id == selection.id })
            XCTAssertEqual(row.result.bench?.score, old.result.bench?.score, "失败档位保留上次成功的分数")
            XCTAssertEqual(row.benchRead?.fetchedAt, BenchFixtures.t0, "读取时间仍是上次成功读取，而不是这次尝试")
            XCTAssertEqual(row.benchRead?.isStale, true)
            XCTAssertNotNil(row.benchRead?.lastError)
        }
        XCTAssertEqual(after.codexGroup.first { $0.id == updated.id }?.result.bench?.score, 33.5)
        XCTAssertNil(after.menuBarBest, "本轮有档位读取失败，不再声明榜首")
        XCTAssertTrue(vm.lastError?.contains("3 个档位读取失败") ?? false)
    }

    // MARK: - ViewModel：基准变化作废缓存与旧观测

    @MainActor
    func testRefresh_bindingChange_discardsOldBenchmarkObservationsAndCache() async throws {
        let defaults = isolatedDefaults()
        let service = makeService()
        stubHappyPath(service)
        let clock = TestClock(BenchFixtures.t0)
        let first = makeVM(service, clock: clock, defaults: defaults)
        await first.refresh()
        XCTAssertEqual(first.snapshot?.codexGroup.count, 34)
        StubURLProtocol.reset()

        // 站点换了任务集（新 sha / 新基准名）：只有一档能读到，其余失败。
        let newSHA = String(repeating: "b", count: 64)
        StubURLProtocol.stubs[service.bindingURL.absoluteString] =
            .init(data: BenchFixtures.bindingData(benchmark: "radar-bench-next", sha: newSHA), statusCode: 200)
        for selection in BenchFixtures.selections {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] = .init(data: Data("err".utf8), statusCode: 500)
        }
        let readable = BenchFixtures.selections[4]
        StubURLProtocol.stubs[service.scoreURL(for: readable).absoluteString] = .init(
            data: BenchFixtures.summaryData(readable, score: 50, sha: newSHA, benchmark: "radar-bench-next"), statusCode: 200)

        let second = makeVM(service, clock: clock, defaults: defaults)
        XCTAssertEqual(second.snapshot?.codexGroup.count, 34, "启动时先用同基准的 24h 内缓存")
        await second.refresh()

        let snapshot = try XCTUnwrap(second.snapshot)
        XCTAssertEqual(snapshot.codexGroup.map(\.id), [readable.id], "新基准下旧观测一条都不能混入")
        XCTAssertEqual(snapshot.benchmark?.binding.benchmark, "radar-bench-next")
        // 重启后缓存里也不应再有旧基准的数据。
        let reloaded = RadarBenchStore(defaults: defaults).load(now: clock.now)
        XCTAssertEqual(reloaded?.binding.taskSetSHA256, newSHA)
        XCTAssertEqual(reloaded?.entries.count, 1)
    }

    @MainActor
    func testCache_olderThan24h_isNotShown_andWithin24h_isMarkedStale() async throws {
        let defaults = isolatedDefaults()
        let binding = try RadarBenchParser.parseBinding(json: BenchFixtures.bindingData())
        let store = RadarBenchStore(defaults: defaults)
        let a = BenchFixtures.selections[0], b = BenchFixtures.selections[1]
        func entry(_ s: BenchSelection, ageHours: Double) throws -> RadarBenchEntry {
            RadarBenchEntry(
                observation: try RadarBenchParser.parseObservation(
                    json: BenchFixtures.summaryData(s), binding: binding, selection: s),
                fetchedAt: BenchFixtures.t0.addingTimeInterval(-ageHours * 3600))
        }
        store.save(binding: binding, entries: [a.id: try entry(a, ageHours: 25), b.id: try entry(b, ageHours: 23)])

        let vm = RadarViewModel(service: makeService(), cacheDefaults: defaults, now: { BenchFixtures.t0 })

        XCTAssertEqual(vm.snapshot?.codexGroup.map(\.id), [b.id])
        XCTAssertEqual(vm.snapshot?.codexGroup.first?.benchRead?.isStale, true)
    }

    // MARK: - ViewModel：后台轮询不整批重扫

    @MainActor
    func testRefresh_backgroundOnlyRereadsMissingOrStaleSelections() async throws {
        let service = makeService()
        stubHappyPath(service)
        let clock = TestClock(BenchFixtures.t0)
        let vm = makeVM(service, clock: clock)

        await vm.refresh(trigger: .launch)
        XCTAssertEqual(scoreRequestCount(), 34)

        clock.advance(30 * 60)
        await vm.refresh(trigger: .background)
        XCTAssertEqual(scoreRequestCount(), 34, "30 分钟后的后台轮询不应再发 34 个评分请求")

        clock.advance(4 * 3600)
        await vm.refresh(trigger: .background)
        XCTAssertEqual(scoreRequestCount(), 68, "超过 staleAfter 才重读")

        clock.advance(120)
        await vm.refresh(trigger: .manual)
        XCTAssertEqual(scoreRequestCount(), 102, "手动刷新重读全部档位")

        clock.advance(10)
        await vm.refresh(trigger: .manual)
        XCTAssertEqual(scoreRequestCount(), 102, "手动刷新也不会在 60s 内重复读同一档位")
    }

    @MainActor
    func testRefresh_afterBusyPauseHonorsRetryAfterCooldown() async throws {
        let service = makeService()
        stubHappyPath(service)
        for selection in BenchFixtures.selections {
            StubURLProtocol.stubs[service.scoreURL(for: selection).absoluteString] =
                .init(data: Data("slow".utf8), statusCode: 429, headers: ["Retry-After": "120"])
        }
        let clock = TestClock(BenchFixtures.t0)
        let vm = makeVM(service, clock: clock)
        await vm.refresh()
        let requestsAfterFirst = StubURLProtocol.requestedURLs.count

        clock.advance(30)
        await vm.refresh(trigger: .manual)

        XCTAssertEqual(StubURLProtocol.requestedURLs.count, requestsAfterFirst, "冷却期内不发任何请求")
        XCTAssertTrue(vm.lastError?.contains("站点繁忙") ?? false)
    }

    @MainActor
    func testRefresh_bindingRejected_doesNotReadScores() async throws {
        let service = makeService()
        stubHappyPath(service, binding: BenchFixtures.bindingData(verified: false))
        let vm = makeVM(service, clock: TestClock(BenchFixtures.t0))

        await vm.refresh()

        XCTAssertNil(vm.snapshot)
        XCTAssertNotNil(vm.lastError)
        XCTAssertEqual(scoreRequestCount(), 0, "绑定未通过校验就不读成绩")
    }

    // MARK: - 偏好与榜单状态在刷新前后保留

    @MainActor
    func testRefresh_preservesPersistedPreferencesAndExpandedState_onSuccessAndFailure() async {
        let originalListMode = UserDefaults.standard.object(forKey: RadarViewModel.listModeKey)
        let originalFrontier = UserDefaults.standard.object(forKey: RadarViewModel.onlyFrontierKey)
        defer {
            for (key, value) in [(RadarViewModel.listModeKey, originalListMode), (RadarViewModel.onlyFrontierKey, originalFrontier)] {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let service = makeService()
        stubHappyPath(service)
        let clock = TestClock(BenchFixtures.t0)
        let vm = makeVM(service, clock: clock)
        vm.listMode = .full
        vm.onlyFrontier = true
        vm.expandedRecommendationIDs = ["gpt-6.1-sol#codexRadar"]

        await vm.refresh()
        XCTAssertNotNil(vm.snapshot)
        XCTAssertEqual(vm.listMode, .full)
        XCTAssertTrue(vm.onlyFrontier)
        XCTAssertEqual(vm.expandedRecommendationIDs, ["gpt-6.1-sol#codexRadar"])

        StubURLProtocol.reset()   // 全部不可用：失败路径
        StubURLProtocol.errors[service.bindingURL.absoluteString] = URLError(.timedOut)
        clock.advance(600)
        await vm.refresh()
        XCTAssertNotNil(vm.lastError)
        XCTAssertNotNil(vm.snapshot, "整体读取失败也保留上次成功的榜单")
        XCTAssertEqual(vm.listMode, .full)
        XCTAssertTrue(vm.onlyFrontier)
        XCTAssertEqual(vm.expandedRecommendationIDs, ["gpt-6.1-sol#codexRadar"])

        // 新实例从 UserDefaults 读回同样的偏好（跨会话保存）。
        let reopened = makeVM(service, clock: clock)
        XCTAssertEqual(reopened.listMode, .full)
        XCTAssertTrue(reopened.onlyFrontier)
    }

    // MARK: - 快照形态：不虚构竞品分区，Terra/Luna 不被旧单档收敛折叠

    @MainActor
    func testRefresh_snapshotShowsOnlyOpenAISection_andKeepsAllLunaTiers() async throws {
        let service = makeService()
        stubHappyPath(service)
        let vm = makeVM(service, clock: TestClock(BenchFixtures.t0))
        await vm.refresh()

        let snapshot = try XCTUnwrap(vm.snapshot)
        XCTAssertEqual(snapshot.availableSections, [.vendor(.openai)], "绑定里没有 Claude/Grok/DeepSeek，不凭空出现")
        XCTAssertTrue(snapshot.claudeGroup.isEmpty)
        let luna = snapshot.codexGroupsByVendor.first?.models.filter { $0.result.name == "gpt-5.6-luna" }
        XCTAssertEqual(luna?.count, 5, "旧的 luna 单档收敛与 IQ≥50 下限不适用于 Radar Bench")
    }

    // MARK: - 固定控件可达

    func testBoardMaxHeight_keepsFixedControlsOnScreen() {
        let screen: CGFloat = 800, chrome: CGFloat = 330
        let board = PopoverRootView.boardMaxHeight(screenHeight: screen, chromeHeight: chrome)
        XCTAssertLessThanOrEqual(board + chrome + 12, screen, "滚动区 + 固定区域不能超出屏幕，底部刷新/退出才点得到")
        // 头部提示变长（固定区域变高）时，滚动区相应缩小。
        XCTAssertLessThan(PopoverRootView.boardMaxHeight(screenHeight: screen, chromeHeight: 420), board)
        // 首帧还没量到固定区域高度时用保守估算。
        XCTAssertEqual(PopoverRootView.boardMaxHeight(screenHeight: screen, chromeHeight: 0), 800 - 260 - 40)
        XCTAssertGreaterThanOrEqual(PopoverRootView.boardMaxHeight(screenHeight: 300, chromeHeight: 330), 120)
    }
}
