import Foundation
import CryptoKit

struct WebLoginRequest {
    let state: String
    let codeVerifier: String
    var codeChallenge: String { Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8)))) }

    init() {
        state = Self.randomValue()
        codeVerifier = Self.randomValue()
    }
    init(state: String, codeVerifier: String) throws {
        guard Self.validCode(state), codeVerifier.range(of: "^[A-Za-z0-9._~-]{43,128}$", options: .regularExpression) != nil else {
            throw WorkspaceFailure.invalid("登录请求无效，请重试。")
        }
        self.state = state; self.codeVerifier = codeVerifier
    }
    func authorizationURL(server: URL) throws -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw WorkspaceFailure.invalid("网页登录需要有效的 HTTPS 服务器地址。")
        }
        components.path = "/native-login"
        components.queryItems = [URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"), URLQueryItem(name: "state", value: state)]
        guard let url = components.url else { throw WorkspaceFailure.invalid("无法创建登录请求。") }
        return url
    }
    func authorizationCode(from callback: URL) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == "guangyi-workspace", components.host == "auth", components.path == "/callback",
              components.port == nil, components.user == nil, components.password == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 2,
              items.filter({ $0.name == "state" }).count == 1,
              items.filter({ $0.name == "code" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value, Self.validCode(code) else {
            throw WorkspaceFailure.invalid("网页登录返回信息不匹配，请重新登录。")
        }
        return code
    }
    private static func validCode(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
    }
    private static func randomValue() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { base64URL(Data($0)) }
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum WorkspaceCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dates = WorkspaceDateCodingCache<Date, String> { formatter.string(from: $0) }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dates.value(for: date))
        }
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        let dates = WorkspaceDateCodingCache<String, Date> { value in
            guard let date = fractional.date(from: value) ?? ordinary.date(from: value) else {
                throw WorkspaceFailure.invalid("时间格式无效。")
            }
            return date
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            return try dates.value(for: value)
        }
        return decoder
    }
    static func equivalent(_ lhs: WorkspaceRecord, _ rhs: WorkspaceRecord) -> Bool {
        // Wire timestamps are millisecond precision; avoid reporting export rounding as an edit.
        var normalized = rhs
        if abs(lhs.createdAt.timeIntervalSince(rhs.createdAt)) < 0.002 { normalized.createdAt = lhs.createdAt }
        if abs(lhs.updatedAt.timeIntervalSince(rhs.updatedAt)) < 0.002 { normalized.updatedAt = lhs.updatedAt }
        let optionalDates: [WritableKeyPath<WorkspaceRecord, Date?>] = [\.archivedAt, \.deletedAt, \.completedAt,
            \.cancelledAt, \.startDate, \.targetDate, \.dueDate, \.scheduledAt, \.remindAt, \.snoozedUntil]
        for path in optionalDates {
            if let left = lhs[keyPath: path], let right = rhs[keyPath: path], abs(left.timeIntervalSince(right)) < 0.002 {
                normalized[keyPath: path] = left
            }
        }
        return lhs == normalized
    }
}

/// Sync snapshots repeat timestamps across records and across local/remote/base.
/// Keep each codec's original formatter semantics, but parse/format repeated values
/// once. FIFO eviction bounds retained data even when a codec handles many exports.
/// The lock also serializes access to the formatters owned by `makeValue`.
private final class WorkspaceDateCodingCache<Key: Hashable, Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity = 8_192
    private let makeValue: (Key) throws -> Value
    private var values: [Key: Value] = [:]
    private var keys: [Key] = []
    private var nextEviction = 0

    init(makeValue: @escaping (Key) throws -> Value) {
        self.makeValue = makeValue
    }

    func value(for key: Key) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = try makeValue(key)
        if keys.count < capacity {
            keys.append(key)
        } else {
            values.removeValue(forKey: keys[nextEviction])
            keys[nextEviction] = key
            nextEviction = (nextEviction + 1) % capacity
        }
        values[key] = value
        return value
    }
}
