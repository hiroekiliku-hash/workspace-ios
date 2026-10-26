import Foundation

/// Public builds never default to a personal deployment. Invalid configuration
/// falls back to the reserved .invalid domain and cannot transmit to a real host.
enum WorkspaceConfiguration {
    static let serviceURL: URL = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "WorkspaceServiceURL") as? String ?? ""
        guard let components = URLComponents(string: raw),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/", let url = components.url else {
            return URL(string: "https://example.invalid")!
        }
        return url
    }()
}
import Observation
import Security
import CryptoKit

enum NativeCapabilities {
    static var passkeysEnabled: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "NativePasskeysEnabled")
        if let enabled = value as? Bool { return enabled }
        return (value as? String).map { ["YES", "TRUE", "1"].contains($0.uppercased()) } ?? false
    }
}

struct NativeSession: Codable {
    var accessToken: String
    var refreshToken: String?
    var displayName: String
    var account: String?
}
typealias RemoteWorkspace = VersionedWorkspace
struct RemoteDeviceRegistration: Codable {
    var deviceID: String
    var platform: String
    var token: String
    var bundleID: String
    var environment: String
}
protocol NativeBackendTransport {
    func signIn(baseURL: URL, email: String, password: String) async throws -> NativeSession
    func signIn(baseURL: URL, email: String, password: String, code: String?) async throws -> NativeSession
    func download(baseURL: URL, token: String) async throws -> RemoteWorkspace
    func upload(baseURL: URL, token: String, snapshot: WorkspaceState, expectedRevision: Int, sourceDeviceID: String) async throws -> RemoteWorkspace
    func download(baseURL: URL, token: String, workspaceID: String?) async throws -> RemoteWorkspace
    func upload(baseURL: URL, token: String, snapshot: WorkspaceState, expectedRevision: Int, sourceDeviceID: String, workspaceID: String?) async throws -> RemoteWorkspace
    func register(baseURL: URL, token: String, device: RemoteDeviceRegistration) async throws
    func signOut(baseURL: URL, token: String, deviceID: String?) async throws
}
extension NativeBackendTransport {
    func signIn(baseURL: URL, email: String, password: String, code: String?) async throws -> NativeSession {
        guard code == nil else { throw NativeBackendError.secondFactorRequired }
        return try await signIn(baseURL: baseURL, email: email, password: password)
    }

    func download(baseURL: URL, token: String, workspaceID: String?) async throws -> RemoteWorkspace {
        guard workspaceID == nil else { throw NativeBackendError.configuration }
        return try await download(baseURL: baseURL, token: token)
    }
    func upload(baseURL: URL, token: String, snapshot: WorkspaceState, expectedRevision: Int, sourceDeviceID: String, workspaceID: String?) async throws -> RemoteWorkspace {
        guard workspaceID == nil else { throw NativeBackendError.configuration }
        return try await upload(baseURL: baseURL, token: token, snapshot: snapshot, expectedRevision: expectedRevision, sourceDeviceID: sourceDeviceID)
    }
}
enum NativeBackendError: LocalizedError {
    case configuration, authentication, conflict, status(Int), malformed, insecureURL, passkeysUnavailable, secondFactorRequired, invalidSecondFactor
    var errorDescription: String? {
        switch self {
        case .configuration: WorkspaceLocalization.string("请先登录工作坊。")
        case .authentication: WorkspaceLocalization.string("登录已失效，请重新登录。")
        case .secondFactorRequired: WorkspaceLocalization.string("请输入“密码”App 中的验证码或恢复码。")
        case .invalidSecondFactor: WorkspaceLocalization.string("验证码无效或已使用，请输入新的验证码或恢复码。")
        case .conflict: WorkspaceLocalization.string("其他设备更新了内容，请同步后再试。")
        case .status(403): WorkspaceLocalization.string("此账号没有权限完成操作。")
        case .status(404): WorkspaceLocalization.string("此功能暂时不可用，请稍后重试。")
        case .status(429): WorkspaceLocalization.string("操作太频繁，请稍后重试。")
        case .status: WorkspaceLocalization.string("暂时无法完成操作，请稍后重试。")
        case .malformed: WorkspaceLocalization.string("暂时无法读取内容，请稍后重试。")
        case .insecureURL: WorkspaceLocalization.string("暂时无法连接工作坊，请稍后重试。")
        case .passkeysUnavailable: WorkspaceLocalization.string("请使用网页登录或账号密码登录。")
        }
    }
}
struct URLSessionBackend: NativeBackendTransport {
    private struct Envelope<T: Decodable>: Decodable { var data: T }
    private struct Login: Encodable { var email: String; var password: String; var code: String? = nil }
    private struct Upload: Encodable { var snapshot: WorkspaceState }
    private func request(_ baseURL: URL, path: String, method: String = "GET", token: String? = nil, data: Data? = nil,
        revision: Int? = nil, sourceDeviceID: String? = nil, workspaceID: String? = nil, idempotencyKey: UUID? = nil, query: [URLQueryItem] = []) async throws -> Data {
        let pathURL = baseURL.appendingPathComponent("api").appendingPathComponent("native").appendingPathComponent("v1").appendingPathComponent(path)
        guard var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) else { throw NativeBackendError.configuration }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NativeBackendError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = data; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if data != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let revision { request.setValue("\"\(revision)\"", forHTTPHeaderField: "If-Match") }
        if let sourceDeviceID { request.setValue(sourceDeviceID, forHTTPHeaderField: "X-Workspace-Device-ID") }
        if let workspaceID { request.setValue(workspaceID, forHTTPHeaderField: "X-Workspace-ID") }
        if let idempotencyKey { request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoBackendRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeBackendError.malformed }
        if path.hasPrefix("sharing"), !(200...299).contains(response.statusCode),
           let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let detail = payload["error"] as? [String: Any], let code = detail["code"] as? String {
            let messages = [
                "SHARING_MERGE_CONFLICT": WorkspaceLocalization.string("双方存在不同版本的同一事项，请先完成同步后再接受邀请。"),
                "SHARING_HAS_MEMBERS": WorkspaceLocalization.string("你的空间已有共享成员，请先移除成员，再加入其他人的空间。"),
                "SHARING_ACCOUNT_NOT_FOUND": WorkspaceLocalization.string("未找到这个账号，请确认邮箱，或请对方先注册工作坊。"),
                "SHARING_ALREADY_LINKED": WorkspaceLocalization.string("对方已经是你的共享成员。"),
                "SHARING_INVITATION_EXISTS": WorkspaceLocalization.string("已向对方发送邀请，请等待对方接受。"),
                "SHARING_SELF_INVITE": WorkspaceLocalization.string("请输入另一个人的账号。"),
                "SHARING_LIMIT": WorkspaceLocalization.string("关联账户或邀请数量已达上限，请先移除不再使用的关联。"),
                "SHARING_INVITATION_NOT_FOUND": WorkspaceLocalization.string("邀请已失效，请刷新后重试。")
            ]
            if let message = messages[code] { throw WorkspaceFailure.invalid(message) }
        }
        if path.hasPrefix("courses"), response.statusCode == 409 {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("课程已存在或已更新，请刷新课程目录、重新预览后再试。"))
        }
        if path == "session", response.statusCode == 401,
           let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let detail = payload["error"] as? [String: Any], let code = detail["code"] as? String {
            if code == "SECOND_FACTOR_REQUIRED" { throw NativeBackendError.secondFactorRequired }
            if code == "INVALID_SECOND_FACTOR" { throw NativeBackendError.invalidSecondFactor }
        }
        if response.statusCode == 401 { throw NativeBackendError.authentication }
        if response.statusCode == 409 || response.statusCode == 412 {
            if path.hasPrefix("passkeys") || path.hasPrefix("integrations/") { throw NativeBackendError.status(response.statusCode) }
            throw NativeBackendError.conflict
        }
        guard (200...299).contains(response.statusCode) else { throw NativeBackendError.status(response.statusCode) }
        guard body.count <= 128 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
        return body
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try ArchiveService.decoder().decode(Envelope<T>.self, from: data).data }
        catch { throw NativeBackendError.malformed }
    }
    func signIn(baseURL: URL, email: String, password: String) async throws -> NativeSession {
        try await signIn(baseURL: baseURL, email: email, password: password, code: nil)
    }
    func signIn(baseURL: URL, email: String, password: String, code: String?) async throws -> NativeSession {
        try decode(NativeSession.self, await request(baseURL, path: "session", method: "POST", data: JSONEncoder().encode(Login(email: email, password: password, code: code))))
    }
    func download(baseURL: URL, token: String) async throws -> RemoteWorkspace {
        try await download(baseURL: baseURL, token: token, workspaceID: nil)
    }
    func download(baseURL: URL, token: String, workspaceID: String?) async throws -> RemoteWorkspace {
        let result = try decode(RemoteWorkspace.self, await request(baseURL, path: "workspace", token: token, workspaceID: workspaceID))
        try WorkspaceLogic.validate(result.snapshot)
        return result
    }
    func upload(baseURL: URL, token: String, snapshot: WorkspaceState, expectedRevision: Int, sourceDeviceID: String) async throws -> RemoteWorkspace {
        try await upload(baseURL: baseURL, token: token, snapshot: snapshot, expectedRevision: expectedRevision, sourceDeviceID: sourceDeviceID, workspaceID: nil)
    }
    func upload(baseURL: URL, token: String, snapshot: WorkspaceState, expectedRevision: Int, sourceDeviceID: String, workspaceID: String?) async throws -> RemoteWorkspace {
        let result = try decode(RemoteWorkspace.self, await request(baseURL, path: "workspace", method: "PUT", token: token,
            data: ArchiveService.encoder().encode(Upload(snapshot: snapshot)), revision: expectedRevision, sourceDeviceID: sourceDeviceID, workspaceID: workspaceID))
        try WorkspaceLogic.validate(result.snapshot)
        return result
    }
    func register(baseURL: URL, token: String, device: RemoteDeviceRegistration) async throws {
        _ = try await request(baseURL, path: "devices", method: "PUT", token: token, data: JSONEncoder().encode(device))
    }
    func signOut(baseURL: URL, token: String, deviceID: String?) async throws {
        if let deviceID {
            _ = try await request(baseURL, path: "devices", method: "DELETE", token: token,
                data: JSONEncoder().encode(["deviceID": deviceID]))
        }
        _ = try await request(baseURL, path: "session", method: "DELETE", token: token)
    }
}
private final class NoBackendRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
enum SecureCredentials {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "WorkSpace") + ".session" }
    // The legacy Mac keychain's interaction switch is process-wide. Serialize
    // our operations so a silent startup read cannot affect an explicit login.
    private static let operationLock = NSLock()
    struct ReadResult: Sendable { let value: String?; let status: OSStatus }
    static func save(_ value: String, key: String) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("无法保存登录状态，请重试。")) }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("无法保存登录状态，请重试。"))
        }
    }
    static func read(_ key: String) -> String? {
        readResult(key).value
    }
    static func readResult(_ key: String, allowInteraction: Bool = true) -> ReadResult {
        operationLock.lock(); defer { operationLock.unlock() }
        #if os(macOS)
        // LAContext / kSecUseAuthenticationUI only suppress prompts reliably in
        // the Data Protection keychain; these existing items use the legacy one.
        var previous: DarwinBoolean = false
        if !allowInteraction {
            let status = SecKeychainGetUserInteractionAllowed(&previous)
            guard status == errSecSuccess else { return ReadResult(value: nil, status: status) }
            let change = SecKeychainSetUserInteractionAllowed(false)
            guard change == errSecSuccess else { return ReadResult(value: nil, status: change) }
        }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        #endif
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return ReadResult(value: nil, status: status) }
        return ReadResult(value: String(data: data, encoding: .utf8), status: status)
    }
    static func remove(_ key: String) {
        operationLock.lock(); defer { operationLock.unlock() }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
    }
}
@MainActor @Observable final class BackendService {
    fileprivate struct Credentials: Codable, Sendable {
        let serverOrigin: String
        let accessToken: String
        let refreshToken: String?
        let account: String?
    }
    /// An opaque pre-read result, including the absence of a saved account.
    /// Credentials stay within this file when the value crosses actor boundaries.
    struct PreparedSession: Sendable {
        fileprivate let credentials: Credentials?
        fileprivate var needsAuthorization = false
    }
    nonisolated private static func storedSession(allowInteraction: Bool = false) -> PreparedSession {
        let result = SecureCredentials.readResult("session", allowInteraction: allowInteraction)
        let credentials = result.value.flatMap { try? JSONDecoder().decode(Credentials.self, from: Data($0.utf8)) }
        return PreparedSession(credentials: credentials,
            needsAuthorization: result.status != errSecSuccess && result.status != errSecItemNotFound)
    }
    nonisolated static func prepareSession(isDemoMode: Bool = false) async -> PreparedSession {
        if isDemoMode { return PreparedSession(credentials: nil) }
        return await Task.detached(priority: .userInitiated) {
            storedSession()
        }.value
    }
    static let serviceURL = WorkspaceConfiguration.serviceURL
    let address: String
    private(set) var signedIn: Bool
    private(set) var sessionRestoreNeedsAuthorization = false
    private(set) var displayName: String
    private(set) var revision: Int?
    private(set) var currentWorkspaceID: String?
    private(set) var workspaceAccessRole = "owner"
    private struct SelectedWorkspace: Codable { var id: String; var role: String }
    private(set) var lastSync: Date?
    private(set) var deviceRegistrationStatus = WorkspaceLocalization.string("尚未注册")
    private let transport: NativeBackendTransport
    private let isDemoMode: Bool
    // Read Keychain once per service lifetime; SwiftUI rendering and sync guards
    // use this observable session so they never block on Keychain IPC.
    private var cachedCredentials: Credentials?
    // Plaintext integration keys never enter preferences or view state. The
    // Keychain entry is scoped to the exact service origin and signed-in account.
    private struct RetainedTextIntegrationKey: Codable {
        var accountScope: String
        var credentialID: String
        var accessToken: String
    }
    private var retainedTextIntegrationKey: RetainedTextIntegrationKey?
    private var retainedCalendarKeys: [RetainedTextIntegrationKey] = []
    private var retainedCourseIntegrationKey: RetainedTextIntegrationKey?
    init(transport: NativeBackendTransport = URLSessionBackend(), isDemoMode: Bool = false, preparedSession: PreparedSession? = nil) {
        self.isDemoMode = isDemoMode
        self.transport = transport
        let savedAddress = Self.serviceURL.absoluteString
        address = savedAddress
        let restored: PreparedSession
        if isDemoMode {
            restored = PreparedSession(credentials: nil)
        } else if let preparedSession {
            // A completed pre-read with no session must not read Keychain again.
            restored = preparedSession
        } else {
            restored = Self.storedSession()
        }
        let credentials = restored.credentials
        sessionRestoreNeedsAuthorization = restored.needsAuthorization
        cachedCredentials = credentials
        signedIn = credentials?.serverOrigin == savedAddress
        displayName = isDemoMode ? "演示用户" : UserDefaults.standard.string(forKey: "backendDisplayName") ?? ""
        restoreWorkspaceSelection()
    }
    private func restoreWorkspaceSelection() {
        if signedIn, let credentials = cachedCredentials, let account = credentials.account {
            let key = Self.selectionStorageKey(credentials.serverOrigin + "|" + account)
            if let data = UserDefaults.standard.data(forKey: key), let selected = try? JSONDecoder().decode(SelectedWorkspace.self, from: data) {
                currentWorkspaceID = selected.id
                workspaceAccessRole = selected.role == "editor" ? "editor" : "viewer"
            }
        }
    }
    /// Only a deliberate account-page action may ask macOS to unlock an old
    /// credential. A denied read never deletes or replaces the saved session.
    func restoreSavedSession() async throws {
        guard !isDemoMode, !signedIn else { return }
        let restored = await Task.detached(priority: .userInitiated) {
            Self.storedSession(allowInteraction: true)
        }.value
        try Task.checkCancellation()
        guard !signedIn else { return }
        sessionRestoreNeedsAuthorization = restored.needsAuthorization
        guard let credentials = restored.credentials, credentials.serverOrigin == address else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("未能恢复登录，请重试或重新登录。"))
        }
        cachedCredentials = credentials
        signedIn = true
        sessionRestoreNeedsAuthorization = false
        restoreWorkspaceSelection()
    }
    private func baseURL() throws -> URL {
        guard !isDemoMode else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("演示模式不连接账号或云端。")) }
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NativeBackendError.insecureURL
        }
        // Credentials remain bound to the application's fixed service origin.
        return url
    }
    private func credentials() throws -> (URL, String) {
        let url = try baseURL()
        guard let credentials = cachedCredentials, credentials.serverOrigin == url.absoluteString else {
            throw NativeBackendError.configuration
        }
        return (url, credentials.accessToken)
    }
    private static func deviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: "deviceID"), UUID(uuidString: existing) != nil { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: "deviceID")
        return created
    }
    func signIn(email: String, password: String, code: String? = nil) async throws {
        let url = try baseURL()
        let result = try await transport.signIn(baseURL: url, email: email, password: password, code: code)
        try acceptSession(result, at: url, accountFallback: email)
    }
    func signInWithWeb(using authorization: WebLoginAuthorization) async throws {
        let url = try baseURL()
        let request = WebLoginRequest()
        let callback = try await authorization.perform(url: request.authorizationURL(server: url))
        guard try baseURL() == url else { throw NativeBackendError.configuration }
        let code = try request.authorizationCode(from: callback)
        let result = try await URLSessionBackend().webLoginSession(baseURL: url, code: code, codeVerifier: request.codeVerifier)
        try acceptSession(result, at: url)
    }
    private func acceptSession(_ result: NativeSession, at url: URL, accountFallback: String? = nil) throws {
        guard try baseURL() == url else { throw NativeBackendError.configuration }
        guard !result.accessToken.isEmpty,
              let account = (result.account ?? accountFallback)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !account.isEmpty else {
            throw NativeBackendError.malformed
        }
        let credentials = Credentials(serverOrigin: url.absoluteString, accessToken: result.accessToken, refreshToken: result.refreshToken, account: account)
        let encoded = try JSONEncoder().encode(credentials)
        guard let value = String(data: encoded, encoding: .utf8) else { throw NativeBackendError.malformed }
        try SecureCredentials.save(value, key: "session")
        retainedTextIntegrationKey = nil
        retainedCalendarKeys = []
        retainedCourseIntegrationKey = nil
        cachedCredentials = credentials
        currentWorkspaceID = nil; workspaceAccessRole = "owner"
        signedIn = true; sessionRestoreNeedsAuthorization = false; displayName = result.displayName; revision = nil
        UserDefaults.standard.set(displayName, forKey: "backendDisplayName")
    }
    func signOut() async throws {
        guard !isDemoMode else { return }
        defer {
            for key in ["session", "accessToken", "refreshToken", "serverOrigin"] { SecureCredentials.remove(key) }
            cachedCredentials = nil
            retainedTextIntegrationKey = nil
            retainedCalendarKeys = []
            retainedCourseIntegrationKey = nil
            currentWorkspaceID = nil; workspaceAccessRole = "owner"
            signedIn = false; sessionRestoreNeedsAuthorization = false; displayName = ""; revision = nil
            UserDefaults.standard.removeObject(forKey: "backendDisplayName")
        }
        if let credentials = cachedCredentials, let url = URL(string: credentials.serverOrigin) {
            do {
                try await transport.signOut(baseURL: url, token: credentials.accessToken,
                    deviceID: UserDefaults.standard.string(forKey: "deviceID"))
            } catch { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("本机凭据已清除，但服务器暂时不可达，远程会话可能要到期后才失效。")) }
        }
    }
    var accountIdentityScope: String? {
        guard !isDemoMode, signedIn, let value = cachedCredentials, value.serverOrigin == address, let account = value.account, !account.isEmpty else { return nil }
        return value.serverOrigin + "|" + account
    }
    var accountScope: String? {
        guard let identity = accountIdentityScope else { return nil }
        return identity + (currentWorkspaceID.map { "|workspace:" + $0 } ?? "")
    }
    private static func selectionStorageKey(_ scope: String) -> String {
        "linked-workspace." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func selectWorkspace(id: String?, role: String) {
        currentWorkspaceID = id
        workspaceAccessRole = id == nil ? "owner" : (role == "editor" ? "editor" : "viewer")
        revision = nil; lastSync = nil
        guard let scope = accountIdentityScope else { return }
        let key = Self.selectionStorageKey(scope)
        if let id, let data = try? JSONEncoder().encode(SelectedWorkspace(id: id, role: workspaceAccessRole)) { UserDefaults.standard.set(data, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    var accountName: String { isDemoMode ? "演示用户" : cachedCredentials?.account ?? displayName }
    func downloadForSync(scope: String) async throws -> RemoteWorkspace {
        guard accountScope == scope else { throw NativeBackendError.configuration }
        let (url, token) = try credentials()
        let result = try await transport.download(baseURL: url, token: token, workspaceID: currentWorkspaceID)
        guard accountScope == scope, cachedCredentials?.accessToken == token else { throw NativeBackendError.configuration }
        if currentWorkspaceID != nil { workspaceAccessRole = result.accessRole == "editor" ? "editor" : "viewer" }
        return result
    }
    func uploadForSync(_ snapshot: WorkspaceState, revision: Int, scope: String) async throws -> RemoteWorkspace {
        guard accountScope == scope else { throw NativeBackendError.configuration }
        guard workspaceAccessRole != "viewer" else { throw NativeBackendError.status(403) }
        let (url, token) = try credentials()
        let result: RemoteWorkspace
        do { result = try await transport.upload(baseURL: url, token: token, snapshot: snapshot, expectedRevision: revision, sourceDeviceID: Self.deviceID(), workspaceID: currentWorkspaceID) }
        catch NativeBackendError.conflict { throw WorkspaceSyncError.revisionChanged }
        guard accountScope == scope, cachedCredentials?.accessToken == token else { throw NativeBackendError.configuration }
        return result
    }
    func acknowledgeSync(_ result: RemoteWorkspace) { revision = result.revision; lastSync = Date() }
    func download() async throws -> WorkspaceState {
        guard let scope = accountScope else { throw NativeBackendError.configuration }
        let result = try await downloadForSync(scope: scope)
        acknowledgeSync(result)
        return result.snapshot
    }
    func upload(_ state: WorkspaceState) async throws {
        guard let scope = accountScope, let revision else { throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先同步服务器内容。")) }
        let result = try await uploadForSync(state, revision: revision, scope: scope)
        acknowledgeSync(result)
    }
    func registerDevice(_ token: Data) async throws {
        let (url, access) = try credentials()
        let existing = Self.deviceID()
        #if os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        try await transport.register(baseURL: url, token: access, device: RemoteDeviceRegistration(deviceID: existing, platform: platform,
            token: token.map { String(format: "%02x", $0) }.joined(), bundleID: Bundle.main.bundleIdentifier ?? "", environment: environment))
        deviceRegistrationStatus = WorkspaceLocalization.string("已注册")
    }
}

struct CalendarTextCredential: Decodable, Identifiable {
    var id: String
    var name: String
    var created: Double
    var expires: Double
    var lastUsed: Double?
    var enabled: Bool? = nil

    var expirationDate: Date { Date(timeIntervalSince1970: expires / 1000) }
}

struct CalendarTextIntegration: Decodable {
    var credentials: [CalendarTextCredential]
    var endpoint: String
    var protocolVersion: String
    var prompt: String
    var manualPrompt: String? = nil

    enum CodingKeys: String, CodingKey {
        case credentials, endpoint, prompt, manualPrompt
        case protocolVersion = "protocol"
    }
}

struct CreatedCalendarTextCredential: Decodable {
    var credential: CalendarTextCredential
    var accessToken: String
    var endpoint: String
    var protocolVersion: String

    enum CodingKeys: String, CodingKey {
        case credential, accessToken, endpoint
        case protocolVersion = "protocol"
    }
}

extension URLSessionBackend {
    func calendarTextIntegration(baseURL: URL, token: String) async throws -> CalendarTextIntegration {
        try decode(CalendarTextIntegration.self, await request(baseURL, path: "integrations/text-tokens", token: token))
    }

    func createCalendarTextCredential(baseURL: URL, token: String, name: String = "AI 日程连接") async throws -> CreatedCalendarTextCredential {
        try decode(CreatedCalendarTextCredential.self, await request(baseURL, path: "integrations/text-tokens", method: "POST",
            token: token, data: JSONEncoder().encode(["name": name])))
    }

    func updateCalendarTextCredential(baseURL: URL, token: String, id: String, name: String, enabled: Bool) async throws {
        struct Update: Encodable { let id: String; let name: String; let enabled: Bool }
        _ = try await request(baseURL, path: "integrations/text-tokens", method: "PATCH", token: token,
            data: JSONEncoder().encode(Update(id: id, name: name, enabled: enabled)))
    }

    func revokeCalendarTextCredential(baseURL: URL, token: String, id: String) async throws {
        _ = try await request(baseURL, path: "integrations/text-tokens", method: "DELETE",
            token: token, data: JSONEncoder().encode(["id": id]))
    }
}

extension BackendService {
    var calendarTextCredentialID: String? {
        guard let retainedTextIntegrationKey, retainedTextIntegrationKey.accountScope == accountIdentityScope else { return nil }
        return retainedTextIntegrationKey.credentialID
    }

    private static func textIntegrationStorageKey(scope: String) -> String {
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return "calendar-text." + digest
    }

    private func textIntegrationContext() throws -> (url: URL, token: String, scope: String) {
        let (url, token) = try credentials()
        guard let scope = accountIdentityScope else { throw NativeBackendError.configuration }
        return (url, token, scope)
    }

    private func checkTextIntegrationContext(scope: String, token: String) throws {
        try Task.checkCancellation()
        guard accountIdentityScope == scope, cachedCredentials?.accessToken == token else { throw NativeBackendError.configuration }
    }

    func calendarTextIntegration() async throws -> CalendarTextIntegration {
        let context = try textIntegrationContext()
        let result = try await URLSessionBackend().calendarTextIntegration(baseURL: context.url, token: context.token)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        guard result.prompt.contains("{{API_KEY}}"), !result.endpoint.isEmpty, !result.protocolVersion.isEmpty else {
            throw NativeBackendError.malformed
        }

        let saved = loadSavedCalendarKeys(scope: context.scope)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        let validIDs = Set(result.credentials.filter { $0.expirationDate > Date() }.map(\.id))
        retainedCalendarKeys = saved.filter { $0.accountScope == context.scope && validIDs.contains($0.credentialID) && !$0.accessToken.isEmpty }
        retainedTextIntegrationKey = retainedCalendarKeys.last
        // Avoid writing the Keychain on every refresh. Removed credentials are
        // filtered here and persisted by explicit create/revoke operations.
        return result
    }

    func createCalendarTextCredential(name: String = "AI 日程连接") async throws {
        let context = try textIntegrationContext()
        let result = try await URLSessionBackend().createCalendarTextCredential(baseURL: context.url, token: context.token, name: name)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        guard !result.credential.id.isEmpty, !result.accessToken.isEmpty, result.credential.expirationDate > Date() else {
            throw NativeBackendError.malformed
        }
        let retained = RetainedTextIntegrationKey(accountScope: context.scope,
            credentialID: result.credential.id, accessToken: result.accessToken)
        var keys = loadSavedCalendarKeys(scope: context.scope)
        keys.append(retained)
        try persistCalendarKeys(keys, scope: context.scope)
        retainedCalendarKeys = keys
        retainedTextIntegrationKey = retained
    }

    private func loadSavedCalendarKeys(scope: String) -> [RetainedTextIntegrationKey] {
        let cached = retainedCalendarKeys.filter { $0.accountScope == scope }
        if !cached.isEmpty { return cached }
        guard let value = SecureCredentials.read(Self.textIntegrationStorageKey(scope: scope)),
              let data = value.data(using: .utf8) else { return [] }
        let saved = (try? JSONDecoder().decode([RetainedTextIntegrationKey].self, from: data))
            ?? (try? JSONDecoder().decode(RetainedTextIntegrationKey.self, from: data)).map { [$0] } ?? []
        return saved.filter { $0.accountScope == scope && !$0.accessToken.isEmpty }
    }

    private func persistCalendarKeys(_ keys: [RetainedTextIntegrationKey], scope: String) throws {
        if keys.isEmpty { SecureCredentials.remove(Self.textIntegrationStorageKey(scope: scope)); return }
        let data = try JSONEncoder().encode(keys)
        guard let value = String(data: data, encoding: .utf8) else { throw NativeBackendError.malformed }
        try SecureCredentials.save(value, key: Self.textIntegrationStorageKey(scope: scope))
    }

    func canCopyCalendarTextCredential(_ id: String) -> Bool {
        retainedCalendarKeys.contains { $0.credentialID == id && $0.accountScope == accountIdentityScope }
    }

    func updateCalendarTextCredential(_ id: String, name: String, enabled: Bool) async throws {
        let context = try textIntegrationContext()
        try await URLSessionBackend().updateCalendarTextCredential(baseURL: context.url, token: context.token,
            id: id, name: name, enabled: enabled)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
    }

    func revokeCalendarTextCredential(_ id: String) async throws {
        let context = try textIntegrationContext()
        try await URLSessionBackend().revokeCalendarTextCredential(baseURL: context.url, token: context.token, id: id)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        let keys = loadSavedCalendarKeys(scope: context.scope).filter { $0.credentialID != id }
        // Remove revoked material from memory even if the Keychain write fails.
        retainedCalendarKeys = keys
        retainedTextIntegrationKey = keys.last
        try persistCalendarKeys(keys, scope: context.scope)
    }

    /// Called only by the explicit copy action. Revalidate the key with the server
    /// before placing an account-bound credential in an AI prompt.
    func calendarTextPrompt(scope: String, credentialID: String? = nil) async throws -> String {
        guard accountIdentityScope == scope else { throw NativeBackendError.configuration }
        let configuration = try await calendarTextIntegration()
        try Task.checkCancellation()
        guard accountIdentityScope == scope,
              let retained = credentialID.flatMap({ id in retainedCalendarKeys.first { $0.credentialID == id } }) ?? (credentialID == nil ? retainedTextIntegrationKey : nil),
              retained.accountScope == scope,
              configuration.credentials.contains(where: { $0.id == retained.credentialID && ($0.enabled ?? true) }) else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先创建此设备的写入密钥。"))
        }
        return configuration.prompt.replacingOccurrences(of: "{{API_KEY}}", with: retained.accessToken)
    }
}

struct PasskeyChallenge: Decodable {
    struct Options: Decodable {
        struct RP: Decodable { var id: String }
        struct User: Decodable { var id: String; var name: String }
        struct Descriptor: Decodable { var id: String }
        var challenge: String
        var rp: RP?
        var rpId: String?
        var user: User?
        var excludeCredentials: [Descriptor]?
        var allowCredentials: [Descriptor]?
    }
    var challengeID: String
    var options: Options
}
struct PasskeyCredential: Encodable {
    struct Response: Encodable {
        var clientDataJSON: String
        var attestationObject: String?
        var authenticatorData: String?
        var signature: String?
        var userHandle: String?
        var transports: [String]?
    }
    var id: String
    var rawId: String
    var type = "public-key"
    var authenticatorAttachment = "platform"
    var clientExtensionResults: [String: String] = [:]
    var response: Response
}
struct RegisteredPasskeys: Decodable {
    struct Credential: Decodable, Identifiable { var id: String; var created: Double }
    var credentials: [Credential]
}
extension URLSessionBackend {
    func webLoginSession(baseURL: URL, code: String, codeVerifier: String) async throws -> NativeSession {
        struct Exchange: Encodable { let code: String; let codeVerifier: String }
        return try decode(NativeSession.self, await request(baseURL, path: "web-auth/token", method: "POST",
            data: JSONEncoder().encode(Exchange(code: code, codeVerifier: codeVerifier))))
    }
    func passkeyOptions(baseURL: URL, registering: Bool, token: String?) async throws -> PasskeyChallenge {
        try decode(PasskeyChallenge.self, await request(baseURL, path: registering ? "passkeys/register/options" : "passkeys/login/options", method: "POST", token: token, data: Data("{}".utf8)))
    }
    func verifyPasskey(baseURL: URL, challengeID: String, credential: PasskeyCredential) async throws -> NativeSession {
        struct Proof: Encodable { var challengeID: String; var credential: PasskeyCredential }
        return try decode(NativeSession.self, await request(baseURL, path: "passkeys/login/verify", method: "POST", data: JSONEncoder().encode(Proof(challengeID: challengeID, credential: credential))))
    }
    func registerPasskey(baseURL: URL, token: String, challengeID: String, credential: PasskeyCredential) async throws {
        struct Proof: Encodable { var challengeID: String; var credential: PasskeyCredential }
        _ = try await request(baseURL, path: "passkeys/register/verify", method: "POST", token: token, data: JSONEncoder().encode(Proof(challengeID: challengeID, credential: credential)))
    }
    func passkeys(baseURL: URL, token: String) async throws -> RegisteredPasskeys {
        try decode(RegisteredPasskeys.self, await request(baseURL, path: "passkeys", token: token))
    }
    func revokePasskey(baseURL: URL, token: String, id: String) async throws {
        _ = try await request(baseURL, path: "passkeys", method: "DELETE", token: token, data: JSONEncoder().encode(["id": id]))
    }
}
extension BackendService {
    func signInWithPasskey(using authorization: PasskeyAuthorization) async throws {
        guard NativeCapabilities.passkeysEnabled else { throw NativeBackendError.passkeysUnavailable }
        let url = try baseURL()
        let endpoint = URLSessionBackend()
        let options = try await endpoint.passkeyOptions(baseURL: url, registering: false, token: nil)
        let credential = try await authorization.perform(options: options.options, registering: false, expectedHost: url.host ?? "")
        let result = try await endpoint.verifyPasskey(baseURL: url, challengeID: options.challengeID, credential: credential)
        try acceptSession(result, at: url)
    }
    func addPasskey(using authorization: PasskeyAuthorization) async throws {
        guard NativeCapabilities.passkeysEnabled else { throw NativeBackendError.passkeysUnavailable }
        let (url, token) = try credentials()
        let scope = accountScope
        let endpoint = URLSessionBackend()
        let options = try await endpoint.passkeyOptions(baseURL: url, registering: true, token: token)
        let credential = try await authorization.perform(options: options.options, registering: true, expectedHost: url.host ?? "")
        guard accountScope == scope, try credentials().1 == token else { throw NativeBackendError.configuration }
        try await endpoint.registerPasskey(baseURL: url, token: token, challengeID: options.challengeID, credential: credential)
    }
    func registeredPasskeys() async throws -> RegisteredPasskeys {
        guard NativeCapabilities.passkeysEnabled else { throw NativeBackendError.passkeysUnavailable }
        let (url, token) = try credentials()
        return try await URLSessionBackend().passkeys(baseURL: url, token: token)
    }
    func revokePasskey(_ id: String) async throws {
        guard NativeCapabilities.passkeysEnabled else { throw NativeBackendError.passkeysUnavailable }
        let (url, token) = try credentials()
        try await URLSessionBackend().revokePasskey(baseURL: url, token: token, id: id)
    }
}

struct LinkedAccountSharing: Decodable {
    struct Invitation: Decodable, Identifiable {
        var id: String
        var ownerEmail: String
        var workspaceID: String
        var role: String
    }
    struct Outgoing: Decodable, Identifiable {
        var id: String
        var email: String
        var role: String
        var status: String
    }
    struct Member: Decodable, Identifiable { var id: String; var email: String; var role: String }
    struct Workspace: Decodable, Identifiable { var id: String; var ownerEmail: String; var role: String; var membershipID: String? }
    var ownedWorkspaceID: String
    var incoming: [Invitation]
    var outgoing: [Outgoing]
    var members: [Member]
    var workspaces: [Workspace]
}

extension URLSessionBackend {
    func linkedAccountSharing(baseURL: URL, token: String) async throws -> LinkedAccountSharing {
        try decode(LinkedAccountSharing.self, await request(baseURL, path: "sharing", token: token))
    }
    func changeLinkedAccountSharing(baseURL: URL, token: String, action: String, method: String = "POST", values: [String: String]) async throws {
        _ = try await request(baseURL, path: "sharing/" + action, method: method, token: token, data: JSONEncoder().encode(values))
    }
}

extension BackendService {
    func linkedAccountSharing() async throws -> LinkedAccountSharing {
        let (url, token) = try credentials()
        let identity = accountIdentityScope
        let result = try await URLSessionBackend().linkedAccountSharing(baseURL: url, token: token)
        try Task.checkCancellation()
        guard accountIdentityScope == identity, cachedCredentials?.accessToken == token else { throw NativeBackendError.configuration }
        if let currentWorkspaceID, let workspace = result.workspaces.first(where: { $0.id == currentWorkspaceID }) {
            workspaceAccessRole = workspace.role == "editor" ? "editor" : "viewer"
        }
        return result
    }
    func changeLinkedAccountSharing(action: String, method: String = "POST", values: [String: String]) async throws {
        let (url, token) = try credentials()
        let identity = accountIdentityScope
        try await URLSessionBackend().changeLinkedAccountSharing(baseURL: url, token: token, action: action, method: method, values: values)
        try Task.checkCancellation()
        guard accountIdentityScope == identity, cachedCredentials?.accessToken == token else { throw NativeBackendError.configuration }
    }
}


/// A server-owned document, independent of course revision and native UI releases.
/// The only native capabilities are the narrow, versioned player bridge.
struct CoursePlayerPackage: Codable, Equatable {
    var protocolVersion: String
    var rendererVersion: String
    var courseID: UUID
    var lessonID: UUID
    var courseRevision: Int
    var html: String
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case rendererVersion, courseID, lessonID, courseRevision, html
    }
    func validate(courseID: UUID, lessonID: UUID, revision: Int? = nil) throws {
        guard protocolVersion == "WORKSHOP-PLAYER/1", !rendererVersion.isEmpty, rendererVersion.utf8.count <= 120,
              self.courseID == courseID, self.lessonID == lessonID, courseRevision > 0,
              revision == nil || courseRevision == revision, !html.isEmpty, html.utf8.count <= 4 * 1024 * 1024 else {
            throw NativeBackendError.malformed
        }
    }
}

extension URLSessionBackend {
    func demoCoursePlayer(baseURL: URL, courseID: UUID, lessonID: UUID) async throws -> CoursePlayerPackage {
        let package = try decode(CoursePlayerPackage.self, await request(baseURL, path: "course-player/demo",
            query: [URLQueryItem(name: "courseID", value: courseID.uuidString), URLQueryItem(name: "lessonID", value: lessonID.uuidString)]))
        try package.validate(courseID: courseID, lessonID: lessonID)
        return package
    }
    func coursePlayer(baseURL: URL, token: String, workspaceID: String?, courseID: UUID, lessonID: UUID) async throws -> CoursePlayerPackage {
        let package = try decode(CoursePlayerPackage.self, await request(baseURL,
            path: "courses/" + courseID.uuidString + "/player", token: token, workspaceID: workspaceID,
            query: [URLQueryItem(name: "lessonID", value: lessonID.uuidString)]))
        try package.validate(courseID: courseID, lessonID: lessonID)
        return package
    }
    func courseCatalog(baseURL: URL, token: String, workspaceID: String?) async throws -> CourseCatalog {
        try decode(CourseCatalog.self, await request(baseURL, path: "courses", token: token, workspaceID: workspaceID))
    }
    func deleteCourse(baseURL: URL, token: String, workspaceID: String?, id: UUID, expectedRevision: Int) async throws {
        _ = try await request(baseURL, path: "courses/" + id.uuidString, method: "DELETE", token: token,
            revision: expectedRevision, workspaceID: workspaceID)
    }
    func setCourseStar(baseURL: URL, token: String, workspaceID: String?, id: UUID, starred: Bool) async throws {
        struct StarResult: Decodable { var starred: Bool }
        let result = try decode(StarResult.self, await request(baseURL, path: "courses/" + id.uuidString + "/star", method: "PUT", token: token,
            data: JSONEncoder().encode(["starred": starred]), workspaceID: workspaceID))
        guard result.starred == starred else { throw NativeBackendError.malformed }
    }
    func courseEdition(baseURL: URL, token: String, workspaceID: String?, id: UUID) async throws -> CourseEdition {
        let edition = try decode(CourseEdition.self, await request(baseURL, path: "courses/" + id.uuidString, token: token, workspaceID: workspaceID))
        try CourseValidation.validate(edition.course)
        guard edition.course.id == id, edition.revision > 0 else { throw NativeBackendError.malformed }
        return edition
    }
    func courseProgress(baseURL: URL, token: String, workspaceID: String?, id: UUID, update: CourseProgressUpdate? = nil) async throws -> CourseProgress {
        let result = try decode(CourseProgress.self, await request(baseURL, path: "courses/" + id.uuidString + "/progress",
            method: update == nil ? "GET" : "POST", token: token,
            data: try update.map { try ArchiveService.encoder().encode($0) }, workspaceID: workspaceID))
        guard result.courseID == id else { throw NativeBackendError.malformed }
        return result
    }
    func runCourseAnswer(baseURL: URL, token: String, workspaceID: String?, id: UUID,
                         revision: Int, lessonID: UUID, blockID: UUID, text: String, stdin: String?) async throws -> CourseCodeRunResult {
        struct Submission: Encodable {
            var courseRevision: Int; var lessonID: UUID; var blockID: UUID; var text: String; var stdin: String?
        }
        let result = try decode(CourseCodeRunResult.self, await request(baseURL, path: "courses/" + id.uuidString + "/run",
            method: "POST", token: token, data: JSONEncoder().encode(Submission(courseRevision: revision,
                lessonID: lessonID, blockID: blockID, text: text, stdin: stdin)), workspaceID: workspaceID))
        guard ["completed", "timeout", "compileError", "runtimeError", "unavailable", "outputLimit"].contains(result.status),
              result.stdout.utf8.count <= 32_768, result.stderr.utf8.count <= 32_768,
              (0...120_000).contains(result.durationMs) else { throw NativeBackendError.malformed }
        return result
    }
    func courseIntegration(baseURL: URL, token: String) async throws -> CalendarTextIntegration {
        try decode(CalendarTextIntegration.self, await request(baseURL, path: "integrations/course-tokens", token: token))
    }
    func createCourseCredential(baseURL: URL, token: String) async throws -> CreatedCalendarTextCredential {
        try decode(CreatedCalendarTextCredential.self, await request(baseURL, path: "integrations/course-tokens", method: "POST", token: token,
            data: JSONEncoder().encode(["name": "AI 课程发布"])))
    }
    func revokeCourseCredential(baseURL: URL, token: String, id: String) async throws {
        _ = try await request(baseURL, path: "integrations/course-tokens", method: "DELETE", token: token, data: JSONEncoder().encode(["id": id]))
    }
}

extension BackendService {
    private func courseContext() throws -> (url: URL, token: String, scope: String, workspaceID: String?) {
        let (url, token) = try credentials()
        guard let scope = accountScope else { throw NativeBackendError.configuration }
        return (url, token, scope, currentWorkspaceID)
    }
    private func checkCourseContext(scope: String, token: String) throws {
        try Task.checkCancellation()
        guard accountScope == scope, cachedCredentials?.accessToken == token else { throw NativeBackendError.configuration }
    }
    func courseCatalog() async throws -> CourseCatalog {
        let context = try courseContext()
        let result = try await URLSessionBackend().courseCatalog(baseURL: context.url, token: context.token, workspaceID: context.workspaceID)
        try checkCourseContext(scope: context.scope, token: context.token)
        guard result.courses.count <= 200, Set(result.courses.map(\.id)).count == result.courses.count,
              result.courses.allSatisfy({ $0.revision > 0 && $0.lessonCount > 0 && $0.lessonCount <= 40 && $0.title.utf16.count <= 240 }) else {
            throw NativeBackendError.malformed
        }
        let stars = result.starredCourseIDs ?? []
        guard stars.count <= 200, Set(stars).count == stars.count,
              Set(stars).isSubset(of: Set(result.courses.map(\.id))) else { throw NativeBackendError.malformed }
        return result
    }
    func deleteCourse(_ id: UUID, expectedRevision: Int) async throws {
        let context = try courseContext()
        guard workspaceAccessRole != "viewer" else { throw NativeBackendError.status(403) }
        guard expectedRevision > 0 else { throw NativeBackendError.malformed }
        try await URLSessionBackend().deleteCourse(baseURL: context.url, token: context.token,
            workspaceID: context.workspaceID, id: id, expectedRevision: expectedRevision)
        try checkCourseContext(scope: context.scope, token: context.token)
    }
    func setCourseStar(_ id: UUID, starred: Bool) async throws {
        let context = try courseContext()
        try await URLSessionBackend().setCourseStar(baseURL: context.url, token: context.token,
            workspaceID: context.workspaceID, id: id, starred: starred)
        try checkCourseContext(scope: context.scope, token: context.token)
    }
    func courseEdition(_ id: UUID) async throws -> CourseEdition {
        let context = try courseContext()
        let result = try await URLSessionBackend().courseEdition(baseURL: context.url, token: context.token, workspaceID: context.workspaceID, id: id)
        try checkCourseContext(scope: context.scope, token: context.token)
        return result
    }
    func coursePlayer(courseID: UUID, lessonID: UUID) async throws -> CoursePlayerPackage {
        let context = try courseContext()
        let result = try await URLSessionBackend().coursePlayer(baseURL: context.url, token: context.token,
            workspaceID: context.workspaceID, courseID: courseID, lessonID: lessonID)
        try checkCourseContext(scope: context.scope, token: context.token)
        return result
    }
    func courseProgress(_ id: UUID, update: CourseProgressUpdate? = nil) async throws -> CourseProgress {
        let context = try courseContext()
        let result = try await URLSessionBackend().courseProgress(baseURL: context.url, token: context.token, workspaceID: context.workspaceID, id: id, update: update)
        try checkCourseContext(scope: context.scope, token: context.token)
        return result
    }
    func runCourseAnswer(_ id: UUID, revision: Int, lessonID: UUID, blockID: UUID,
                         text: String, stdin: String? = nil) async throws -> CourseCodeRunResult {
        let context = try courseContext()
        let result = try await URLSessionBackend().runCourseAnswer(baseURL: context.url, token: context.token,
            workspaceID: context.workspaceID, id: id, revision: revision, lessonID: lessonID,
            blockID: blockID, text: text, stdin: stdin)
        try checkCourseContext(scope: context.scope, token: context.token)
        return result
    }
    var courseCredentialID: String? {
        guard let retainedCourseIntegrationKey, retainedCourseIntegrationKey.accountScope == accountIdentityScope else { return nil }
        return retainedCourseIntegrationKey.credentialID
    }
    private static func courseIntegrationStorageKey(scope: String) -> String {
        "courses-publish." + SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func courseIntegration() async throws -> CalendarTextIntegration {
        let context = try textIntegrationContext()
        let result = try await URLSessionBackend().courseIntegration(baseURL: context.url, token: context.token)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        guard result.protocolVersion == "WORKSHOP-COURSE/1", result.prompt.contains("{{API_KEY}}") else { throw NativeBackendError.malformed }
        let storageKey = Self.courseIntegrationStorageKey(scope: context.scope)
        let retained = retainedCourseIntegrationKey?.accountScope == context.scope ? retainedCourseIntegrationKey : SecureCredentials.read(storageKey).flatMap {
            try? JSONDecoder().decode(RetainedTextIntegrationKey.self, from: Data($0.utf8))
        }
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        if let retained, retained.accountScope == context.scope, !retained.accessToken.isEmpty,
           result.credentials.contains(where: { $0.id == retained.credentialID && $0.expirationDate > Date() }) {
            retainedCourseIntegrationKey = retained
        } else {
            SecureCredentials.remove(storageKey); retainedCourseIntegrationKey = nil
        }
        return result
    }
    func createCourseCredential() async throws {
        let context = try textIntegrationContext()
        let result = try await URLSessionBackend().createCourseCredential(baseURL: context.url, token: context.token)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        guard result.protocolVersion == "WORKSHOP-COURSE/1", result.accessToken.hasPrefix("wsc_"), result.credential.expirationDate > Date() else { throw NativeBackendError.malformed }
        let retained = RetainedTextIntegrationKey(accountScope: context.scope, credentialID: result.credential.id, accessToken: result.accessToken)
        let value = String(decoding: try JSONEncoder().encode(retained), as: UTF8.self)
        try SecureCredentials.save(value, key: Self.courseIntegrationStorageKey(scope: context.scope))
        retainedCourseIntegrationKey = retained
    }
    func revokeCourseCredential(_ id: String) async throws {
        let context = try textIntegrationContext()
        try await URLSessionBackend().revokeCourseCredential(baseURL: context.url, token: context.token, id: id)
        try checkTextIntegrationContext(scope: context.scope, token: context.token)
        if retainedCourseIntegrationKey?.credentialID == id {
            SecureCredentials.remove(Self.courseIntegrationStorageKey(scope: context.scope)); retainedCourseIntegrationKey = nil
        }
    }
    func coursePublishingPrompt(scope: String) async throws -> String {
        guard accountIdentityScope == scope else { throw NativeBackendError.configuration }
        let configuration = try await courseIntegration()
        guard accountIdentityScope == scope, let retained = retainedCourseIntegrationKey, retained.accountScope == scope else {
            throw WorkspaceFailure.invalid(WorkspaceLocalization.string("请先创建此设备的课程发布密钥。"))
        }
        return configuration.prompt.replacingOccurrences(of: "{{API_KEY}}", with: retained.accessToken)
    }
}


struct CoursePublication: Decodable {
    var id: UUID
    var revision: Int
    var updatedAt: Date
    var replayed: Bool?
}

extension URLSessionBackend {
    func publishCourse(baseURL: URL, token: String, workspaceID: String?, course: CourseDocument,
                       expectedRevision: Int?, mutationID: UUID) async throws -> CoursePublication {
        try decode(CoursePublication.self, await request(baseURL, path: "courses", method: "POST", token: token,
            data: WorkspaceCoding.encoder().encode(course), revision: expectedRevision,
            workspaceID: workspaceID, idempotencyKey: mutationID))
    }
}

extension BackendService {
    func manualCoursePrompt(scope: String) async throws -> String {
        guard accountIdentityScope == scope else { throw NativeBackendError.configuration }
        let configuration = try await courseIntegration()
        guard accountIdentityScope == scope, let prompt = configuration.manualPrompt,
              !prompt.isEmpty, !prompt.contains("{{API_KEY}}") else { throw NativeBackendError.malformed }
        return prompt
    }
    func publishCourse(_ course: CourseDocument, expectedRevision: Int?, mutationID: UUID) async throws -> CoursePublication {
        try CourseValidation.validate(course)
        let context = try courseContext()
        guard workspaceAccessRole != "viewer" else { throw NativeBackendError.status(403) }
        let result = try await URLSessionBackend().publishCourse(baseURL: context.url, token: context.token,
            workspaceID: context.workspaceID, course: course, expectedRevision: expectedRevision, mutationID: mutationID)
        try checkCourseContext(scope: context.scope, token: context.token)
        guard result.id == course.id, result.revision > 0 else { throw NativeBackendError.malformed }
        return result
    }
}
