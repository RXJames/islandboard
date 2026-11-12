import Foundation
import Defaults
import Security

/// Which quota dialect the account speaks. `newAPI` is the new-api/one-api
/// gateway (`/api/user/self`, `{success,data}` envelope); `deepseek` is the
/// DeepSeek official API (`/user/balance`, plain JSON with decimal-string amounts);
/// `server` is a self-hosted inference server exposing a Prometheus `/metrics`
/// route with vllm/sushi token counters (prefill & decode throughput, totals).
enum NewAPIKind: String, Codable, CaseIterable, Identifiable {
    case newAPI
    case deepSeek
    case server

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .newAPI: return "New API gateway"
        case .deepSeek: return "DeepSeek"
        case .server: return "Inference server"
        }
    }
}

struct NewAPIAccount: Codable, Defaults.Serializable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var baseURL: String
    var kind: NewAPIKind

    init(id: UUID = UUID(), name: String, baseURL: String, kind: NewAPIKind = .newAPI) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        // Rows stored before DeepSeek support exist without a kind; they are gateways.
        kind = try container.decodeIfPresent(NewAPIKind.self, forKey: .kind) ?? .newAPI
    }
}

struct NewAPIAccountSnapshot: Equatable, Identifiable {
    let id: UUID
    let name: String
    let balanceQuota: Int?
    let usedQuota: Int?
    let requestCount: Int?
    let todayQuota: Int?
    let weekQuota: Int?
    let currentRPM: Int?
    let currentTPM: Int?
    let errorMessage: String?
    /// Pre-formatted balance for dialects that report money as decimal strings
    /// (DeepSeek), e.g. "¥110.00". Gateway accounts use `balanceQuota` instead.
    var balanceText: String? = nil
    /// Pre-formatted label/value rows for dialects whose card is not quota-shaped
    /// (inference server: prefill/decode tok/s, token totals).
    var serverRows: [ServerMetricRow] = []

    var isSuccessful: Bool { errorMessage == nil }
}

protocol NewAPIAccountProviding {
    func accounts() -> [NewAPIAccount]
    func apiKey(for account: NewAPIAccount) -> String?
}

enum NewAPIKeychain {
    private static let service = "com.Ebullioscopic.Atoll.new-api"

    static func read(accountID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ apiKey: String, accountID: UUID) throws {
        let data = Data(apiKey.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess || updateStatus == errSecItemNotFound else {
            throw NewAPIKeychainError(status: updateStatus)
        }
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw NewAPIKeychainError(status: addStatus) }
        }
    }

    static func delete(accountID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NewAPIKeychainError(status: status)
        }
    }
}

struct NewAPIKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Unable to store the New API key (Keychain status \(status))." }
}

struct NewAPIAccountStore: NewAPIAccountProviding {
    func accounts() -> [NewAPIAccount] { Defaults[.newAPIAccounts] }

    func apiKey(for account: NewAPIAccount) -> String? {
        NewAPIKeychain.read(accountID: account.id)
    }

    static func upsert(_ account: NewAPIAccount, apiKey: String) throws {
        var account = account
        account.name = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        account.baseURL = account.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.name.isEmpty else {
            throw NewAPIStoreError.invalidName
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Defaults[.newAPIAccounts].contains { $0.id == account.id }
        let storedKey = NewAPIKeychain.read(accountID: account.id)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty && (!existing || storedKey?.isEmpty != false) {
            throw NewAPIStoreError.missingAPIKey
        }
        guard NewAPIClient.normalizedBaseURL(account.baseURL) != nil else {
            throw NewAPIStoreError.invalidBaseURL
        }
        if !trimmedKey.isEmpty {
            try NewAPIKeychain.save(trimmedKey, accountID: account.id)
        }
        var accounts = Defaults[.newAPIAccounts]
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        Defaults[.newAPIAccounts] = accounts
    }

    static func delete(_ account: NewAPIAccount) throws {
        try NewAPIKeychain.delete(accountID: account.id)
        var accounts = Defaults[.newAPIAccounts]
        accounts.removeAll { $0.id == account.id }
        Defaults[.newAPIAccounts] = accounts
    }
}

enum NewAPIStoreError: LocalizedError {
    case invalidName
    case missingAPIKey
    case invalidBaseURL

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a name for this account."
        case .missingAPIKey: return "Enter an API key for this account."
        case .invalidBaseURL: return "Enter a valid New API URL, including http:// or https://."
        }
    }
}

struct ServerMetricRow: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// Minimal Prometheus text-exposition parser: samples without labels, and per-name
/// sums for label-split counters. NaN/Inf samples are dropped.
enum PrometheusText {
    static func parse(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let namePart = String(line[..<space])
            let valuePart = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
            // Sample identity is the name without labels; labeled series of the same
            // counter are summed, which is what totals want.
            let name = namePart.prefix(while: { $0 != "{" })
            guard let value = Double(valuePart), value.isFinite else { continue }
            out[String(name), default: 0] += value
        }
        return out
    }
}

/// Window rates from two adjacent `/metrics` samples. Prefill uses the server's
/// own processed-token counter (mean over the window — an idle window yields nil);
/// decode uses the live generation gauge, which also ticks for in-flight requests.
actor ServerRates {
    static let shared = ServerRates()

    private struct Sample { let date: Date; let prefill: Double?; let decode: Double? }
    private var last: [UUID: Sample] = [:]

    func reset(accountID: UUID) { last[accountID] = nil }

    /// Returns (prefill tok/s, decode tok/s) — nil when no work happened in the
    /// window (or on the very first sample).
    func rates(accountID: UUID, now: Date, prefillTotal: Double?, decodeLive: Double?) -> (prefill: Double?, decode: Double?) {
        let previous = last[accountID]
        let sample = Sample(date: now, prefill: prefillTotal, decode: decodeLive)
        last[accountID] = sample
        guard let previous, now.timeIntervalSince(previous.date) > 1 else { return (nil, nil) }
        let dt = now.timeIntervalSince(previous.date)
        func rate(_ before: Double?, _ after: Double?) -> Double? {
            guard let before, let after, after >= before else { return nil }
            let delta = after - before
            return delta > 0 ? delta / dt : nil
        }
        return (rate(previous.prefill, sample.prefill), rate(previous.decode, sample.decode))
    }
}

struct NewAPIClient {
    typealias RequestHandler = (URLRequest) async throws -> (Data, URLResponse)

    private let requestHandler: RequestHandler

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.requestHandler = { request in try await session.data(for: request) }
    }

    init(requestHandler: @escaping RequestHandler) {
        self.requestHandler = requestHandler
    }

    static func normalizedBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = path.isEmpty ? "" : "/\(path)"
        return components?.url
    }

    func fetchAccount(_ account: NewAPIAccount, apiKey: String, now: Date, calendar: Calendar = .current) async throws -> NewAPIAccountSnapshot {
        guard let baseURL = Self.normalizedBaseURL(account.baseURL) else {
            throw NewAPIClientError.invalidBaseURL
        }
        if account.kind == .deepSeek {
            return try await fetchDeepSeekAccount(account, baseURL: baseURL, apiKey: apiKey)
        }
        if account.kind == .server {
            return try await fetchServerAccount(account, baseURL: baseURL, apiKey: apiKey, now: now)
        }
        let selfData = try await request(path: "/api/user/self", baseURL: baseURL, apiKey: apiKey)
        let user = try decode(NewAPIEnvelope<NewAPIUser>.self, from: selfData)
        guard user.success, let userData = user.data else { throw NewAPIClientError.apiRequestFailed }

        let end = Int64(now.timeIntervalSince1970)
        let todayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        let weekStart = Int64(calendar.dateInterval(of: .weekOfYear, for: now)?.start.timeIntervalSince1970 ?? now.timeIntervalSince1970)
        let throughputStart = max(0, end - 60)

        async let todayStat = fetchStat(baseURL: baseURL, apiKey: apiKey, start: todayStart, end: end)
        async let weekStat = fetchStat(baseURL: baseURL, apiKey: apiKey, start: weekStart, end: end)
        async let throughputStat = fetchStat(baseURL: baseURL, apiKey: apiKey, start: throughputStart, end: end)

        var todayQuota: Int?
        var weekQuota: Int?
        var currentRPM: Int?
        var currentTPM: Int?
        var errorMessage: String?

        do {
            let stat = try await todayStat
            todayQuota = stat.quota
        } catch {
            errorMessage = "Daily usage unavailable"
        }

        do {
            let stat = try await weekStat
            weekQuota = stat.quota
        } catch {
            errorMessage = errorMessage ?? "Weekly usage unavailable"
        }

        do {
            let stat = try await throughputStat
            currentRPM = stat.rpm
            currentTPM = stat.tpm
        } catch {
            errorMessage = errorMessage ?? "Current throughput unavailable"
        }

        return NewAPIAccountSnapshot(
            id: account.id,
            name: account.name,
            balanceQuota: userData.quota,
            usedQuota: userData.usedQuota,
            requestCount: userData.requestCount,
            todayQuota: todayQuota,
            weekQuota: weekQuota,
            currentRPM: currentRPM,
            currentTPM: currentTPM,
            errorMessage: errorMessage
        )
    }

    /// DeepSeek official API: `GET /user/balance` returns plain JSON with
    /// decimal-string money amounts. The API exposes no per-request stat route,
    /// so today/week/RPM/TPM stay nil and the card shows the balance alone.
    private func fetchDeepSeekAccount(_ account: NewAPIAccount, baseURL: URL, apiKey: String) async throws -> NewAPIAccountSnapshot {
        var request = URLRequest(url: baseURL.appendingPathComponent("user/balance"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await requestHandler(request)
        guard let http = response as? HTTPURLResponse else { throw NewAPIClientError.httpFailure }
        guard (200..<300).contains(http.statusCode) else {
            // Surface DeepSeek's own message (invalid key, rate limit…) instead of a bare "request failed".
            if let err = try? JSONDecoder().decode(DeepSeekErrorBody.self, from: data), let message = err.error?.message {
                throw NewAPIClientError.providerError(message)
            }
            throw NewAPIClientError.httpFailure
        }
        let balance = try decode(DeepSeekBalanceResponse.self, from: data)
        let infos = balance.balanceInfos ?? []
        let balanceText: String?
        if infos.isEmpty {
            balanceText = nil
        } else {
            let symbols = ["CNY": "¥", "USD": "$"]
            let parts = infos.compactMap { info -> String? in
                guard let total = info.totalBalance else { return nil }
                let symbol = symbols[info.currency ?? "CNY"] ?? ""
                return symbol + total
            }
            balanceText = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        var errorMessage: String?
        if balance.isAvailable == false {
            errorMessage = "Balance service unavailable"
            if let reason = balance.unavailableReason, !reason.isEmpty {
                errorMessage = "\(errorMessage!): \(reason)"
            }
        } else if balanceText == nil {
            errorMessage = "No balance reported"
        }
        return NewAPIAccountSnapshot(
            id: account.id,
            name: account.name,
            balanceQuota: nil,
            usedQuota: nil,
            requestCount: nil,
            todayQuota: nil,
            weekQuota: nil,
            currentRPM: nil,
            currentTPM: nil,
            errorMessage: errorMessage,
            balanceText: balanceText
        )
    }

    /// Inference server: reads `/metrics` (Prometheus) and maps the sushi/vllm
    /// token counters to card rows. Speeds are window rates between consecutive
    /// refresh samples (`ServerRates`); totals are cumulative since server start.
    private func fetchServerAccount(_ account: NewAPIAccount, baseURL: URL, apiKey: String, now: Date) async throws -> NewAPIAccountSnapshot {
        let data = try await request(path: "/metrics", baseURL: baseURL, apiKey: apiKey)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NewAPIClientError.invalidResponse
        }
        let metrics = PrometheusText.parse(text)
        guard metrics["vllm:prompt_tokens_total"] != nil || metrics["vllm:generation_tokens_total"] != nil else {
            throw NewAPIClientError.notInferenceServer
        }

        let rates = await ServerRates.shared.rates(
            accountID: account.id,
            now: now,
            prefillTotal: metrics["sushi:prefill_tokens_total"],
            decodeLive: metrics["sushi:generation_tokens_live"]
        )

        var rows: [ServerMetricRow] = []
        rows.append(ServerMetricRow(label: "Prefill", value: rates.prefill.map { Self.speed($0) } ?? "idle"))
        rows.append(ServerMetricRow(label: "Decode", value: rates.decode.map { Self.speed($0) } ?? "idle"))
        rows.append(ServerMetricRow(label: "Input", value: metrics["vllm:prompt_tokens_total"].map(Self.compactTokens) ?? "-"))
        rows.append(ServerMetricRow(label: "Output", value: metrics["vllm:generation_tokens_total"].map(Self.compactTokens) ?? "-"))
        if let requests = metrics["vllm:request_success_total"] {
            rows.append(ServerMetricRow(label: "Requests", value: Self.compactTokens(requests)))
        }
        if let gpu = metrics["sushi:gpu_utilization_pct"] {
            rows.append(ServerMetricRow(label: "GPU", value: String(format: "%.0f%%", gpu)))
        }
        return NewAPIAccountSnapshot(
            id: account.id,
            name: account.name,
            balanceQuota: nil,
            usedQuota: nil,
            requestCount: nil,
            todayQuota: nil,
            weekQuota: nil,
            currentRPM: nil,
            currentTPM: nil,
            errorMessage: nil,
            serverRows: rows
        )
    }

    static func speed(_ tokPerSec: Double) -> String {
        tokPerSec >= 100 ? String(format: "%.0f tok/s", tokPerSec) : String(format: "%.1f tok/s", tokPerSec)
    }

    static func compactTokens(_ n: Double) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
        case 1_000...: return String(format: "%.1fk", n / 1_000)
        default: return String(Int(n))
        }
    }

    private func fetchStat(baseURL: URL, apiKey: String, start: Int64, end: Int64) async throws -> NewAPIStat {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/log/self/stat"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "start_timestamp", value: String(start)),
            URLQueryItem(name: "end_timestamp", value: String(end))
        ]
        guard let url = components?.url else { throw NewAPIClientError.invalidURL }
        let data = try await request(url: url, apiKey: apiKey)
        let response = try decode(NewAPIEnvelope<NewAPIStat>.self, from: data)
        guard response.success, let stat = response.data else { throw NewAPIClientError.apiRequestFailed }
        return stat
    }

    private func request(path: String, baseURL: URL, apiKey: String) async throws -> Data {
        try await request(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), apiKey: apiKey)
    }

    private func request(url: URL, apiKey: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await requestHandler(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NewAPIClientError.httpFailure
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw NewAPIClientError.invalidResponse }
    }
}

private struct NewAPIEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
}

/// `GET /user/balance` — https://api-docs.deepseek.com/api/get-user-balance
struct DeepSeekBalanceResponse: Decodable {
    let isAvailable: Bool?
    let balanceInfos: [BalanceInfo]?
    let unavailableReason: String?

    struct BalanceInfo: Decodable {
        let currency: String?
        let totalBalance: String?
        let grantedBalance: String?
        let toppedUpBalance: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
        case unavailableReason = "unavailable_reason"
    }
}

/// OpenAI-style error body DeepSeek returns on auth/rate-limit failures.
private struct DeepSeekErrorBody: Decodable {
    struct Inner: Decodable { let message: String? }
    let error: Inner?
}

struct NewAPIUser: Decodable, Equatable {
    let quota: Int
    let usedQuota: Int
    let requestCount: Int

    init(quota: Int, usedQuota: Int, requestCount: Int) {
        self.quota = quota
        self.usedQuota = usedQuota
        self.requestCount = requestCount
    }

    enum CodingKeys: String, CodingKey {
        case quota
        case usedQuota = "used_quota"
        case requestCount = "request_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quota = try Self.decodeInt(forKey: .quota, from: container)
        usedQuota = try Self.decodeInt(forKey: .usedQuota, from: container)
        requestCount = try Self.decodeInt(forKey: .requestCount, from: container)
    }

    private static func decodeInt(forKey key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) throws -> Int {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key), let int = Int(value) { return int }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(codingPath: container.codingPath + [key], debugDescription: "Expected an integer or numeric string")
        )
    }
}

struct NewAPIStat: Decodable, Equatable {
    let quota: Int
    let rpm: Int
    let tpm: Int

    init(quota: Int, rpm: Int, tpm: Int) {
        self.quota = quota
        self.rpm = rpm
        self.tpm = tpm
    }

    enum CodingKeys: String, CodingKey {
        case quota
        case rpm
        case tpm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quota = try Self.decodeInt(forKey: .quota, from: container)
        rpm = try Self.decodeInt(forKey: .rpm, from: container)
        tpm = try Self.decodeInt(forKey: .tpm, from: container)
    }

    private static func decodeInt(forKey key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) throws -> Int {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key), let int = Int(value) { return int }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(codingPath: container.codingPath + [key], debugDescription: "Expected an integer or numeric string")
        )
    }
}

enum NewAPIClientError: LocalizedError {
    case invalidBaseURL
    case invalidURL
    case httpFailure
    case apiRequestFailed
    case invalidResponse
    case providerError(String)
    case notInferenceServer

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Invalid New API URL"
        case .invalidURL: return "Invalid New API request URL"
        case .httpFailure: return "New API request failed"
        case .apiRequestFailed: return "New API returned an unsuccessful response"
        case .invalidResponse: return "New API returned an invalid response"
        case .providerError(let message): return message
        case .notInferenceServer: return "No inference-server token metrics at this URL"
        }
    }
}

struct NewAPIUsageProvider: UsageProvider {
    let id: ProviderID = .newAPI
    let accountSource: NewAPIAccountProviding
    let client: NewAPIClient
    let includedKinds: Set<NewAPIKind>?
    let emptyMessage: String

    init(
        accountSource: NewAPIAccountProviding = NewAPIAccountStore(),
        includedKinds: Set<NewAPIKind>? = nil,
        emptyMessage: String = "No New API accounts configured",
        client: NewAPIClient = NewAPIClient()
    ) {
        self.accountSource = accountSource
        self.includedKinds = includedKinds
        self.emptyMessage = emptyMessage
        self.client = client
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let accounts = accountSource.accounts().filter { account in
            includedKinds?.contains(account.kind) ?? true
        }
        guard !accounts.isEmpty else { throw UsageError.notConfigured(emptyMessage) }

        let snapshots = await withTaskGroup(of: NewAPIAccountSnapshot.self, returning: [NewAPIAccountSnapshot].self) { group in
            for account in accounts {
                group.addTask {
                    guard let apiKey = accountSource.apiKey(for: account)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                          !apiKey.isEmpty else {
                        return NewAPIAccountSnapshot(id: account.id, name: account.name, balanceQuota: nil, usedQuota: nil, requestCount: nil, todayQuota: nil, weekQuota: nil, currentRPM: nil, currentTPM: nil, errorMessage: "API key not configured")
                    }
                    do {
                        return try await client.fetchAccount(account, apiKey: apiKey, now: now)
                    } catch {
                        return NewAPIAccountSnapshot(id: account.id, name: account.name, balanceQuota: nil, usedQuota: nil, requestCount: nil, todayQuota: nil, weekQuota: nil, currentRPM: nil, currentTPM: nil, errorMessage: error.localizedDescription)
                    }
                }
            }
            var result: [NewAPIAccountSnapshot] = []
            for await snapshot in group { result.append(snapshot) }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        var snapshot = UsageSnapshot()
        snapshot.newAPIAccounts = snapshots
        snapshot.lastUpdated = now
        return snapshot
    }
}

/// DeepSeek is a billing/provider card of its own, backed by the official
/// `/user/balance` API. Accounts are still created through the shared API
/// accounts editor with `kind == .deepSeek`.
struct DeepSeekUsageProvider: UsageProvider {
    let id: ProviderID = .deepSeek
    private let delegate: NewAPIUsageProvider

    init(accountSource: NewAPIAccountProviding = NewAPIAccountStore(), client: NewAPIClient = NewAPIClient()) {
        delegate = NewAPIUsageProvider(
            accountSource: accountSource,
            includedKinds: [.deepSeek],
            emptyMessage: "No DeepSeek accounts configured",
            client: client
        )
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        try await delegate.fetchSnapshot(now: now)
    }
}
