// 拉取并解析数据（codexradar.com 同基准 Radar Bench，radar-bench-v2-150）：
// - /data/radar-bench-binding.json：基准身份（benchmark / task_set_sha256 / 计分版本）与可读取的「模型 + 档位」；
// - /api/radar-bench-score?model=&effort=&view=summary：逐档读取成绩，必须带 X-Radar-Bench-Selection: user-selected-v1
//   （不带返回 428），与网站自动队列同样的并发上限 3，繁忙（429/502/503/504、超时）按 Retry-After 有限次重试。
// 旧的 radar-insights / intelligence-efficiency-metrics / current.json（IQ 量纲）不再请求：
// 它们与新分数不同量纲，且前两者目前 502，绝不与新数据混用。
import Foundation

enum RadarServiceError: LocalizedError {
    case http(Int)
    case network(String)
    case decode(String)
    /// 站点繁忙：429 / 502 / 503 / 504（status 非 nil），或超时、连接中断（status 为 nil）。可重试。
    case busy(status: Int?, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return code == 428 ? "站点要求选择请求头（428）" : "服务器返回 \(code)"
        case .network(let msg): return msg
        case .decode(let msg): return msg
        case .busy(let status, _): return status.map { "服务繁忙（\($0)）" } ?? "请求超时或连接中断"
        }
    }
}

/// 一批逐档读取的汇总。
struct RadarBenchBatchOutcome: Equatable {
    var succeeded = 0
    var failed = 0
    /// 因整批被暂停而从未发起请求的档位数（含已领取但发送前被叫停的）。
    var skipped = 0
    /// 任务被取消而未完成的档位数；succeeded + failed + skipped + cancelled = 去重后的档位数。
    var cancelled = 0
    /// 整批被暂停的原因（站点繁忙 / 被拒绝）；nil = 正常跑完。
    var stopReason: String?
    /// 暂停原因是 Retry-After 过长时，建议多久后再试（秒）。
    var retryAfter: TimeInterval?
}

struct RadarService {
    let bindingURL = URL(string: "https://codexradar.com/data/radar-bench-binding.json")!
    let scoreEndpoint = URL(string: "https://codexradar.com/api/radar-bench-score")!

    static let selectionHeaderField = "X-Radar-Bench-Selection"
    static let selectionHeaderValue = "user-selected-v1"
    static let requestTimeout: TimeInterval = 15

    /// 退避 / Retry-After 的等待实现；测试注入记录型实现以免真的睡眠。
    var sleep: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// 共享冷却使用的时钟；测试与 `sleep` 一起注入可控实现，避免真实时钟 + 立即返回的 sleep 空转。
    var now: @Sendable () -> Date = { Date() }

    func scoreURL(for selection: BenchSelection) -> URL {
        var components = URLComponents(url: scoreEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "model", value: selection.model),
            URLQueryItem(name: "effort", value: selection.effort),
            URLQueryItem(name: "view", value: "summary"),
        ]
        return components.url!
    }

    // MARK: - 绑定

    /// 读取并校验绑定；繁忙时有限次重试（网站自身对绑定读取也是一次性的，这里多给两次机会）。
    func fetchBinding() async throws -> RadarBenchBinding {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let data = try await send(URLRequest(url: bindingURL))
                do {
                    return try RadarBenchParser.parseBinding(json: data)
                } catch {
                    throw RadarServiceError.decode(error.localizedDescription)
                }
            } catch RadarServiceError.busy(let status, let retryAfter) {
                guard attempt < RadarBenchPolicy.maxAttempts,
                      (retryAfter ?? 0) <= RadarBenchPolicy.maxWait else {
                    throw RadarServiceError.busy(status: status, retryAfter: retryAfter)
                }
                await sleep(retryAfter ?? Self.backoff(attempt: attempt))
            }
        }
    }

    // MARK: - 逐档成绩

    /// 读取一个档位的成绩（单次尝试，不重试）。响应必须通过与绑定的身份/范围校验。
    func fetchObservation(_ selection: BenchSelection, binding: RadarBenchBinding) async throws -> RadarBenchObservation {
        var request = URLRequest(url: scoreURL(for: selection))
        request.setValue(Self.selectionHeaderValue, forHTTPHeaderField: Self.selectionHeaderField)
        let data = try await send(request)
        do {
            return try RadarBenchParser.parseObservation(json: data, binding: binding, selection: selection)
        } catch {
            throw RadarServiceError.decode(error.localizedDescription)
        }
    }

    /// 批量读取：去重、并发 ≤ 3、共享冷却（任一 worker 遇到繁忙，其余 worker 的下一次请求也等）。
    /// 单档繁忙最多尝试 `maxAttempts` 次，等待遵循 Retry-After（超过 `maxWait` 则不等待、直接暂停整批）；
    /// 连续多个档位重试耗尽、或站点以 428 拒绝时同样暂停整批，避免继续打一个已经拒绝我们的服务。
    /// 每个档位完成（成功或最终失败）立即回调；因暂停而从未发起请求的档位不回调，计入 `skipped`。
    /// 每次真正发请求前都重新检查取消、整批暂停与共享冷却（含已领取的档位和重试）。
    func fetchBatch(
        binding: RadarBenchBinding,
        selections: [BenchSelection],
        onResult: @escaping @MainActor (BenchSelection, Result<RadarBenchObservation, Error>) -> Void
    ) async -> RadarBenchBatchOutcome {
        var seen = Set<String>()
        let unique = selections.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return RadarBenchBatchOutcome() }

        let state = BatchState(pending: unique, now: now)
        let tally = BatchTally()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(RadarBenchPolicy.concurrency, unique.count) {
                group.addTask {
                    while !Task.isCancelled {
                        guard let selection = await state.next() else { break }
                        let result = await self.run(selection, binding: binding, state: state, onResult: onResult)
                        await tally.record(result)
                    }
                }
            }
        }

        var outcome = RadarBenchBatchOutcome()
        outcome.succeeded = await tally.succeeded
        outcome.failed = await tally.failed
        outcome.skipped = await state.skippedCount
        outcome.cancelled = max(0, unique.count - outcome.succeeded - outcome.failed - outcome.skipped)
        outcome.stopReason = await state.stopReason
        outcome.retryAfter = await state.stopRetryAfter
        return outcome
    }

    fileprivate enum RunResult {
        case succeeded
        /// 已发起过请求且最终失败（含重试等待期间被叫停）。
        case failed
        /// 已领取但发送前整批被叫停，从未发起请求。
        case skipped
        case cancelled
    }

    private enum SendGate {
        case go, stopped, cancelled
    }

    /// 发请求前的闸门：取消 → 整批暂停 → 共享冷却。等待期间别的 worker 可能延长冷却或叫停整批，
    /// 所以每次醒来都重新检查，直到冷却真正结束才放行。
    private func waitToSend(_ state: BatchState) async -> SendGate {
        while true {
            if Task.isCancelled { return .cancelled }
            if await state.isStopped { return .stopped }
            let wait = await state.remainingCooldown()
            if wait <= 0 { return .go }
            await sleep(wait)
        }
    }

    private func run(
        _ selection: BenchSelection,
        binding: RadarBenchBinding,
        state: BatchState,
        onResult: @MainActor (BenchSelection, Result<RadarBenchObservation, Error>) -> Void
    ) async -> RunResult {
        var attempt = 0
        var pendingRetryError: RadarServiceError?
        while true {
            attempt += 1
            switch await waitToSend(state) {
            case .go:
                break
            case .cancelled:
                return .cancelled
            case .stopped:
                // 重试期间被叫停：之前已经尝试过，按失败收口；首次尝试前被叫停：从未发送，计 skipped。
                if let pendingRetryError {
                    await onResult(selection, .failure(pendingRetryError))
                    return .failed
                }
                await state.skipClaimed()
                return .skipped
            }
            do {
                let observation = try await fetchObservation(selection, binding: binding)
                await state.recordSuccess()
                await onResult(selection, .success(observation))
                return .succeeded
            } catch is CancellationError {
                return .cancelled
            } catch let error as RadarServiceError {
                switch error {
                case .busy(_, let retryAfter):
                    if let retryAfter, retryAfter > RadarBenchPolicy.maxWait {
                        await state.stop("站点繁忙，请约 \(Int(retryAfter.rounded(.up))) 秒后重试", retryAfter: retryAfter)
                        await onResult(selection, .failure(error))
                        return .failed
                    }
                    let delay = min(retryAfter ?? Self.backoff(attempt: attempt), RadarBenchPolicy.maxWait)
                    await state.coolDown(for: delay)
                    if attempt >= RadarBenchPolicy.maxAttempts {
                        if await state.recordBusyExhausted() {
                            await state.stop("站点持续繁忙，已暂停本轮读取", retryAfter: nil)
                        }
                        await onResult(selection, .failure(error))
                        return .failed
                    }
                    // 重试的等待交给下一轮 waitToSend：它按共享冷却的最新截止时间等。
                    pendingRetryError = error
                case .http(428):
                    await state.stop("站点拒绝了选择请求头（428），已暂停本轮读取", retryAfter: nil)
                    await onResult(selection, .failure(error))
                    return .failed
                default:
                    await onResult(selection, .failure(error))
                    return .failed
                }
            } catch {
                await onResult(selection, .failure(error))
                return .failed
            }
        }
    }

    // MARK: - 传输

    private func send(_ template: URLRequest) async throws -> Data {
        var request = template
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.requestTimeout
        request.httpShouldHandleCookies = false

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .notConnectedToInternet:
                throw RadarServiceError.busy(status: nil, retryAfter: nil)
            default:
                throw RadarServiceError.network(error.localizedDescription)
            }
        } catch {
            throw RadarServiceError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if [429, 502, 503, 504].contains(http.statusCode) {
                throw RadarServiceError.busy(status: http.statusCode, retryAfter: Self.retryAfter(in: http))
            }
            throw RadarServiceError.http(http.statusCode)
        }
        return data
    }

    /// 无 Retry-After 时的指数退避：2s、4s……封顶 maxWait。
    static func backoff(attempt: Int) -> TimeInterval {
        min(2 * pow(2, Double(max(attempt - 1, 0))), RadarBenchPolicy.maxWait)
    }

    /// Retry-After：非负秒数（可带小数）或 HTTP-date；无法解析返回 nil。
    static func retryAfter(in response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.allSatisfy({ $0.isNumber || $0 == "." }), let seconds = Double(raw), seconds.isFinite {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw).map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// 批次共享状态：待读队列 + 共享冷却 + 暂停标志。
private actor BatchState {
    private var pending: [BenchSelection]
    private var cooldownUntil = Date.distantPast
    private var consecutiveBusyFailures = 0
    private(set) var stopReason: String?
    private(set) var stopRetryAfter: TimeInterval?
    private(set) var skippedCount = 0
    private let now: @Sendable () -> Date

    init(pending: [BenchSelection], now: @escaping @Sendable () -> Date) {
        self.pending = pending
        self.now = now
    }

    var isStopped: Bool { stopReason != nil }

    func next() -> BenchSelection? {
        guard stopReason == nil, !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    /// 已领取、但发送前整批被叫停的档位。
    func skipClaimed() { skippedCount += 1 }

    func remainingCooldown() -> TimeInterval { max(0, cooldownUntil.timeIntervalSince(now())) }

    func coolDown(for seconds: TimeInterval) {
        cooldownUntil = max(cooldownUntil, now().addingTimeInterval(seconds))
    }

    func recordSuccess() { consecutiveBusyFailures = 0 }

    /// 一个档位重试耗尽；返回是否已达到「连续繁忙失败」上限。
    func recordBusyExhausted() -> Bool {
        consecutiveBusyFailures += 1
        return consecutiveBusyFailures >= RadarBenchPolicy.maxConsecutiveBusyFailures
    }

    func stop(_ reason: String, retryAfter: TimeInterval?) {
        guard stopReason == nil else { return }
        stopReason = reason
        stopRetryAfter = retryAfter
        skippedCount += pending.count
        pending.removeAll()
    }
}

private actor BatchTally {
    private(set) var succeeded = 0
    private(set) var failed = 0

    fileprivate func record(_ result: RadarService.RunResult) {
        switch result {
        case .succeeded: succeeded += 1
        case .failed: failed += 1
        case .skipped, .cancelled: break   // skipped 已由 BatchState 计数；cancelled 由 fetchBatch 按差额得出
        }
    }
}

// MARK: - 观测缓存（UserDefaults）

/// 每档最近一次**成功**观测的本地缓存：绑定身份 + 逐档原始响应 + 成功读取时间。
/// 载入时每条都重新按当前绑定校验（身份、范围、自洽），并丢弃年龄超过 24h 的条目，
/// 因此换了基准 / task_set_sha256 / 计分版本的旧缓存不可能被带进新数据。
struct RadarBenchStore {
    static let key = "radarBenchCache.v1"
    static let schema = "codexradar-bench-cache-v1"

    var defaults: UserDefaults = .standard

    private struct Payload: Codable {
        var schema: String
        var binding: RadarBenchBinding
        var entries: [Item]
    }

    private struct Item: Codable {
        var selection: BenchSelection
        var fetchedAt: Date
        var raw: JSONValue
    }

    func load(now: Date) -> (binding: RadarBenchBinding, entries: [String: RadarBenchEntry])? {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schema == Self.schema else { return nil }
        let known = Set(payload.binding.selections.map(\.id))
        var entries: [String: RadarBenchEntry] = [:]
        for item in payload.entries where known.contains(item.selection.id) {
            let age = now.timeIntervalSince(item.fetchedAt)
            guard age <= RadarBenchPolicy.maxCacheAge, age >= -300,
                  let observation = try? RadarBenchParser.parseObservation(
                    item.raw, binding: payload.binding, selection: item.selection) else { continue }
            entries[item.selection.id] = RadarBenchEntry(observation: observation, fetchedAt: item.fetchedAt)
        }
        return (payload.binding, entries)
    }

    func save(binding: RadarBenchBinding, entries: [String: RadarBenchEntry]) {
        let items: [Item] = binding.selections.compactMap { selection in
            guard let entry = entries[selection.id], let observation = entry.observation,
                  let fetchedAt = entry.fetchedAt else { return nil }
            return Item(selection: selection, fetchedAt: fetchedAt, raw: observation.raw)
        }
        let payload = Payload(schema: Self.schema, binding: binding, entries: items)
        if let data = try? JSONEncoder().encode(payload) { defaults.set(data, forKey: Self.key) }
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}
