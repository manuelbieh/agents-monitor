import CryptoKit
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path

let pollInterval: TimeInterval = 5 * 60
let maxBackoff: TimeInterval = 30 * 60
let minManualRefresh: TimeInterval = 60

enum Provider: String, CaseIterable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var defaultConfigDir: String {
        switch self {
        case .claude: return home + "/.claude"
        case .codex: return home + "/.codex"
        }
    }

    /// Prefix and marker file used to suggest unmonitored config dirs in the add form.
    var discovery: (prefix: String, marker: String) {
        switch self {
        case .claude: return (".claude", "settings.json")
        case .codex: return (".codex", "auth.json")
        }
    }
}

func expandHome(_ path: String) -> String {
    path.hasPrefix("~") ? home + path.dropFirst() : path
}

func collapseHome(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

func normalizeDir(_ path: String) -> String {
    let expanded = expandHome(path.trimmingCharacters(in: .whitespacesAndNewlines))
    return URL(fileURLWithPath: expanded).standardizedFileURL.path
}

func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// The API returns timestamps with microseconds, which ISO8601DateFormatter can't parse.
func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let trimmed = value.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    return ISO8601DateFormatter().date(from: trimmed)
}

func nowMilliseconds() -> Double {
    Date().timeIntervalSince1970 * 1000
}

let planNames = [
    "free": "Free", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "max": "Max",
    "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu",
]

func planName(_ plan: String?) -> String? {
    guard let plan else { return nil }
    return planNames[plan.lowercased()] ?? plan.prefix(1).uppercased() + plan.dropFirst()
}

struct Limit {
    let kind: String
    let label: String
    let usedPercent: Double
    let resetsAt: String?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    func isExhausted(at now: Date = Date()) -> Bool {
        guard usedPercent >= 100, let reset = parseDate(resetsAt) else { return false }
        return reset > now
    }

    var dictionary: [String: Any] {
        var dict: [String: Any] = ["kind": kind, "label": label, "usedPercent": usedPercent]
        if let resetsAt { dict["resetsAt"] = resetsAt }
        return dict
    }

    init(kind: String, label: String, usedPercent: Double, resetsAt: String?) {
        self.kind = kind
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    init?(dictionary: [String: Any]) {
        guard let kind = dictionary["kind"] as? String, let label = dictionary["label"] as? String else { return nil }
        self.init(
            kind: kind,
            label: label,
            usedPercent: (dictionary["usedPercent"] as? NSNumber)?.doubleValue ?? 0,
            resetsAt: dictionary["resetsAt"] as? String
        )
    }
}

final class Account {
    let provider: Provider
    let configDir: String
    var email: String?
    var plan: String?
    var limits: [Limit]?
    var fetchedAt: Double?
    var error: String?
    var nextFetchAt = Date.distantPast
    var backoff = pollInterval
    var inFlight = false

    init(provider: Provider, configDir: String) {
        self.provider = provider
        self.configDir = configDir
    }

    /// Limits that lock the whole account (scoped limits only lock one model or feature).
    var accountLimits: [Limit] { (limits ?? []).filter { $0.kind != "weekly_scoped" } }

    var isBlocked: Bool { (limits ?? []).contains { $0.isExhausted() } }

    var headroom: Double? { accountLimits.map(\.remainingPercent).min() }

    var displayName: String { email ?? collapseHome(configDir) }
}

// MARK: - Claude

struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Double?
    let subscriptionType: String?
}

// Claude Code stores OAuth credentials in the macOS keychain. The default instance
// (~/.claude) uses "Claude Code-credentials"; any CLAUDE_CONFIG_DIR instance appends
// the first 8 hex chars of sha256(configDir).
func keychainServices(for dir: String) -> [String] {
    let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
    let suffixed = "Claude Code-credentials-\(hash)"
    return dir == Provider.claude.defaultConfigDir ? ["Claude Code-credentials", suffixed] : [suffixed]
}

// Shelling out to /usr/bin/security avoids keychain permission prompts: Claude Code
// writes its entries through that binary, so it is already on each item's ACL.
func readKeychain(_ service: String) -> ClaudeCredentials? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", service, "-w"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String, !token.isEmpty
    else { return nil }

    return ClaudeCredentials(
        accessToken: token,
        expiresAt: (oauth["expiresAt"] as? NSNumber)?.doubleValue,
        subscriptionType: oauth["subscriptionType"] as? String
    )
}

func readClaudeCredentials(for dir: String) -> ClaudeCredentials? {
    // Pick the freshest token when several entries exist (old ones linger after re-logins).
    keychainServices(for: dir)
        .compactMap(readKeychain)
        .max { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }
}

func readClaudeEmail(for dir: String) -> String? {
    let file = dir == Provider.claude.defaultConfigDir ? home + "/.claude.json" : dir + "/.claude.json"
    return (readJSON(file)?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
}

func claudeLimitLabel(_ limit: [String: Any]) -> String {
    let kind = limit["kind"] as? String ?? ""
    if kind == "session" { return "5-hour limit" }
    if kind == "weekly_all" { return "7-day limit" }
    let scope = limit["scope"] as? [String: Any]
    let name = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
        ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
    return name.map { "7-day \($0)" } ?? kind.replacingOccurrences(of: "_", with: " ")
}

func claudeLimits(_ body: [String: Any]) -> [Limit] {
    if let limits = body["limits"] as? [[String: Any]], !limits.isEmpty {
        return limits.map {
            Limit(
                kind: $0["kind"] as? String ?? "",
                label: claudeLimitLabel($0),
                usedPercent: ($0["percent"] as? NSNumber)?.doubleValue ?? 0,
                resetsAt: $0["resets_at"] as? String
            )
        }
    }
    // Fallback for responses without the "limits" array.
    let legacy: [(String, String, String)] = [
        ("weekly_all", "7-day limit", "seven_day"),
        ("session", "5-hour limit", "five_hour"),
        ("weekly_scoped", "7-day Opus", "seven_day_opus"),
        ("weekly_scoped", "7-day Sonnet", "seven_day_sonnet"),
    ]
    return legacy.compactMap { kind, label, key in
        guard let value = body[key] as? [String: Any] else { return nil }
        return Limit(
            kind: kind,
            label: label,
            usedPercent: (value["utilization"] as? NSNumber)?.doubleValue ?? 0,
            resetsAt: value["resets_at"] as? String
        )
    }
}

// MARK: - Codex

struct CodexCredentials {
    let accessToken: String
    let accountId: String?
    let email: String?
    let expiresAt: Double?
}

func decodeJWTPayload(_ token: String?) -> [String: Any]? {
    let parts = token?.split(separator: ".") ?? []
    guard parts.count >= 2 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

// Codex keeps its ChatGPT login in <CODEX_HOME>/auth.json and refreshes it itself.
func readCodexCredentials(for dir: String) -> CodexCredentials? {
    guard let tokens = readJSON(dir + "/auth.json")?["tokens"] as? [String: Any],
          let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
    else { return nil }
    let exp = (decodeJWTPayload(accessToken)?["exp"] as? NSNumber)?.doubleValue
    return CodexCredentials(
        accessToken: accessToken,
        accountId: tokens["account_id"] as? String,
        email: decodeJWTPayload(tokens["id_token"] as? String)?["email"] as? String,
        expiresAt: exp.map { $0 * 1000 }
    )
}

func windowName(_ seconds: Double) -> String {
    let hours = Int((seconds / 3600).rounded())
    return hours % 24 == 0 ? "\(hours / 24)-day" : "\(hours)-hour"
}

func codexLimit(_ window: [String: Any], scope: String?) -> Limit {
    let seconds = (window["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
    let resetAt = (window["reset_at"] as? NSNumber)?.doubleValue
    let kind = scope != nil ? "weekly_scoped" : seconds <= 24 * 3600 ? "session" : "weekly_all"
    return Limit(
        kind: kind,
        label: "\(windowName(seconds)) \(scope ?? "limit")",
        usedPercent: (window["used_percent"] as? NSNumber)?.doubleValue ?? 0,
        resetsAt: resetAt.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) }
    )
}

func codexLimits(_ body: [String: Any]) -> [Limit] {
    var limits: [Limit] = []
    let windows = { (rateLimit: Any?, scope: String?) in
        guard let rateLimit = rateLimit as? [String: Any] else { return }
        for key in ["primary_window", "secondary_window"] {
            if let window = rateLimit[key] as? [String: Any] { limits.append(codexLimit(window, scope: scope)) }
        }
    }
    windows(body["rate_limit"], nil)
    windows(body["code_review_rate_limit"], "Code review")
    return limits
}

// MARK: - Monitor

/// A ready-to-send usage request, or the reason one can't be made right now.
enum Preparation {
    case ready(URLRequest, parse: ([String: Any]) -> [Limit])
    case failed(String, retryIn: TimeInterval)
}

/// Owns the account list and polls the usage endpoints. All state lives on the main thread.
final class Monitor {
    private(set) var accounts: [Account] = []
    var onChange: (() -> Void)?

    private let supportDir: URL
    private var accountsFile: URL { supportDir.appendingPathComponent("accounts.json") }
    private var cacheFile: URL { supportDir.appendingPathComponent("usage-cache.json") }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        supportDir = appSupport.appendingPathComponent("AgentsMonitor")
        // The app used to be called Claude Monitor; carry over its accounts and cache.
        let legacyDir = appSupport.appendingPathComponent("ClaudeMonitor")
        if !FileManager.default.fileExists(atPath: supportDir.path),
           FileManager.default.fileExists(atPath: legacyDir.path) {
            try? FileManager.default.moveItem(at: legacyDir, to: supportDir)
        }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        var entries: [(Provider, String)] = [(.claude, Provider.claude.defaultConfigDir)]
        if let data = try? Data(contentsOf: accountsFile),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries = list.compactMap { item in
                guard let dir = item["configDir"] as? String else { return nil }
                let provider = (item["provider"] as? String).flatMap(Provider.init(rawValue:)) ?? .claude
                return (provider, normalizeDir(dir))
            }
        }

        let cache = (try? Data(contentsOf: cacheFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        let now = Date()
        for (index, (provider, dir)) in entries.enumerated() {
            let account = Account(provider: provider, configDir: dir)
            if let cached = cache[dir] as? [String: Any] {
                account.limits = (cached["limits"] as? [[String: Any]])?.compactMap(Limit.init(dictionary:))
                account.fetchedAt = (cached["fetchedAt"] as? NSNumber)?.doubleValue
                account.email = cached["email"] as? String
                account.plan = cached["plan"] as? String
            }
            // Stagger the initial requests so accounts don't all hit the endpoints at once.
            account.nextFetchAt = now.addingTimeInterval(Double(index) * 2)
            accounts.append(account)
        }
        saveAccounts()
    }

    private func saveAccounts() {
        let list = accounts.map { ["provider": $0.provider.rawValue, "configDir": collapseHome($0.configDir)] }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? data.write(to: accountsFile)
        }
    }

    private func saveCache() {
        var cache: [String: Any] = [:]
        for account in accounts {
            guard let limits = account.limits else { continue }
            var entry: [String: Any] = ["limits": limits.map(\.dictionary), "fetchedAt": account.fetchedAt ?? 0]
            entry["email"] = account.email
            entry["plan"] = account.plan
            cache[account.configDir] = entry
        }
        if let data = try? JSONSerialization.data(withJSONObject: cache) {
            try? data.write(to: cacheFile)
        }
    }

    // MARK: Accounts

    func account(for dir: String) -> Account? {
        accounts.first { $0.configDir == dir }
    }

    func addAccount(provider: Provider, dir rawDir: String, completion: @escaping (String?) -> Void) {
        let dir = normalizeDir(rawDir)
        guard isDirectory(dir) else { return completion("\(collapseHome(dir)) does not exist") }
        guard account(for: dir) == nil else { return completion("Account already added") }

        DispatchQueue.global(qos: .userInitiated).async {
            let hasCredentials = provider == .claude
                ? readClaudeCredentials(for: dir) != nil
                : readCodexCredentials(for: dir) != nil
            DispatchQueue.main.async {
                guard hasCredentials else {
                    return completion("No \(provider.displayName) login found for \(collapseHome(dir))")
                }
                let account = Account(provider: provider, configDir: dir)
                self.accounts.append(account)
                self.saveAccounts()
                self.refresh(account) { completion(nil) }
            }
        }
    }

    func removeAccount(_ rawDir: String) -> Bool {
        let dir = normalizeDir(rawDir)
        guard let index = accounts.firstIndex(where: { $0.configDir == dir }) else { return false }
        accounts.remove(at: index)
        saveAccounts()
        saveCache()
        onChange?()
        return true
    }

    func candidates(for provider: Provider) -> [String] {
        let (prefix, marker) = provider.discovery
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .map { home + "/" + $0 }
            .filter { isDirectory($0) && FileManager.default.fileExists(atPath: $0 + "/" + marker) && account(for: $0) == nil }
            .map(collapseHome)
            .sorted()
    }

    // MARK: Polling

    func tick() {
        let now = Date()
        for account in accounts where now >= account.nextFetchAt && !account.inFlight {
            refresh(account)
        }
    }

    func refreshAll() {
        let now = nowMilliseconds()
        for account in accounts where account.fetchedAt.map({ now - $0 > minManualRefresh * 1000 }) ?? true {
            account.nextFetchAt = .distantPast
        }
        tick()
    }

    func refresh(_ account: Account, completion: (() -> Void)? = nil) {
        guard !account.inFlight else { completion?(); return }
        account.inFlight = true
        let finish = {
            account.inFlight = false
            self.onChange?()
            completion?()
        }

        DispatchQueue.global(qos: .utility).async {
            let preparation = self.prepare(account)
            DispatchQueue.main.async {
                switch preparation {
                case let .failed(message, delay):
                    account.error = message
                    account.nextFetchAt = Date().addingTimeInterval(delay)
                    finish()
                case let .ready(request, parse):
                    self.send(request, for: account, parse: parse, done: finish)
                }
            }
        }
    }

    /// Runs off the main thread: reads credentials and builds the provider's request.
    private func prepare(_ account: Account) -> Preparation {
        let dir = account.configDir
        switch account.provider {
        case .claude:
            let email = readClaudeEmail(for: dir)
            guard let credentials = readClaudeCredentials(for: dir) else {
                return .failed("No credentials found in keychain", retryIn: pollInterval)
            }
            DispatchQueue.main.async {
                account.email = email ?? account.email
                account.plan = planName(credentials.subscriptionType) ?? account.plan
            }
            if let expiresAt = credentials.expiresAt, expiresAt < nowMilliseconds() {
                // Refreshing here would rotate the refresh token behind Claude Code's back.
                return .failed("Token expired, start this Claude instance to renew it", retryIn: 60)
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return .ready(request, parse: claudeLimits)

        case .codex:
            guard let credentials = readCodexCredentials(for: dir) else {
                return .failed("No login found in auth.json", retryIn: pollInterval)
            }
            DispatchQueue.main.async { account.email = credentials.email ?? account.email }
            if let expiresAt = credentials.expiresAt, expiresAt < nowMilliseconds() {
                return .failed("Token expired, start Codex to renew it", retryIn: 60)
            }
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 15)
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
            if let accountId = credentials.accountId {
                request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
            return .ready(request) { body in
                DispatchQueue.main.async {
                    account.plan = planName(body["plan_type"] as? String) ?? account.plan
                    account.email = account.email ?? body["email"] as? String
                }
                return codexLimits(body)
            }
        }
    }

    private func send(
        _ request: URLRequest,
        for account: Account,
        parse: @escaping ([String: Any]) -> [Limit],
        done: @escaping () -> Void
    ) {
        func fail(_ message: String, retryIn delay: TimeInterval = pollInterval) {
            account.error = message
            account.nextFetchAt = Date().addingTimeInterval(delay)
            done()
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error {
                    return fail("Request failed: \(error.localizedDescription)")
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 {
                    account.backoff = min(account.backoff * 2, maxBackoff)
                    return fail("Rate limited, retrying later", retryIn: account.backoff)
                }
                guard status == 200,
                      let data,
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return fail(status == 401 ? "Token rejected (401)" : "Usage request failed (\(status))")
                }

                account.limits = parse(body)
                account.fetchedAt = nowMilliseconds()
                account.error = nil
                account.backoff = pollInterval
                account.nextFetchAt = Date().addingTimeInterval(pollInterval)
                // parse() may have queued email/plan updates; save after they land.
                DispatchQueue.main.async {
                    self.saveCache()
                    done()
                }
            }
        }.resume()
    }

    // MARK: API

    func publicState() -> [String: Any] {
        [
            "now": nowMilliseconds(),
            "providers": Provider.allCases.map { ["id": $0.rawValue, "name": $0.displayName] },
            "accounts": accounts.map { account -> [String: Any] in
                var dict: [String: Any] = [
                    "provider": account.provider.rawValue,
                    "configDir": collapseHome(account.configDir),
                    "loading": account.inFlight && account.limits == nil,
                ]
                dict["email"] = account.email
                dict["plan"] = account.plan
                dict["limits"] = account.limits?.map(\.dictionary)
                dict["fetchedAt"] = account.fetchedAt
                dict["error"] = account.error
                return dict
            },
        ]
    }
}
