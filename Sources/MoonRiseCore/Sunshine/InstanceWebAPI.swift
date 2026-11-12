import Foundation
import OSLog

/// PIN 提交结果错误。
public enum InstanceWebAPIError: LocalizedError {
    case noCredentials        // 实例 Web 凭据未预置（用户已自设或实例未就绪）
    case invalidPin
    case http(Int, String)    // 状态码 + 响应体摘录

    public var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "实例 Web 凭据未预置（用户已自设或实例未就绪）"
        case .invalidPin:
            return "PIN 必须为 4 位数字"
        case .http(let code, let body):
            let excerpt = body.isEmpty ? "" : "：\(body.prefix(160))"
            return "实例 Web UI 请求失败（HTTP \(code)）\(excerpt)"
        }
    }
}

/// 扩展屏实例的 Sunshine Web UI API（D3/D4）：凭据预置、待配对列表、PIN 提交。
/// 鉴权 = HTTP Basic；凭据由 MoonRise 随机生成并存实例 credentials/webui.json（0600）。
/// 自签证书 → 使用不校验证书链的专用会话；请求不带 Origin/Referer 头 → 免 CSRF（confighttp 查证）。
public enum InstanceWebAPI {
    /// 实例 Web UI 凭据（MoonRise 生成；主实例不适用）。
    public struct Credentials: Codable, Equatable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    /// 待配对会话（GET /api/pin 返回项）。
    public struct PendingPairing: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let address: String
    }

    public enum ProbeResult: Equatable {
        case empty          // 凭据为空（302 → /welcome）
        case configured     // 已设凭据（401）
        case offline        // 不可达
    }

    // MARK: - 路径与端口

    public static func webPort(base: Int) -> Int { base + 1 }

    public static func webUICredentialsURL(for slotID: UUID) -> URL {
        InstanceConf.credentialsDirectory(for: slotID).appendingPathComponent("webui.json")
    }

    /// 主实例 Web UI 凭据副本路径（MoonRise 侧；与主 conf 同目录，随首屏重置一并清除）。
    public static func primaryWebUICredentialsURL(configPath: String) -> URL {
        URL(fileURLWithPath: Paths.expandTilde(configPath))
            .deletingLastPathComponent()
            .appendingPathComponent("credentials")
            .appendingPathComponent("webui.json")
    }

    // MARK: - 纯函数（可测）

    /// Basic auth 请求头值。
    public static func basicAuthHeader(_ credentials: Credentials) -> String {
        let raw = "\(credentials.username):\(credentials.password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }

    /// 解析 GET /api/pin 响应：{"pairings": [{"id","name","address"}]}。
    public static func parsePendingPairings(_ data: Data) -> [PendingPairing] {
        struct Wrapper: Decodable { let pairings: [PendingPairing]? }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.pairings ?? []
    }

    /// PIN 合法性：4 位数字。
    public static func isValidPin(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    /// 生成随机凭据。
    public static func generateCredentials() -> Credentials {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz")
        let user = "moonrise-" + String((0..<6).map { _ in alphabet.randomElement()! })
        return Credentials(username: user, password: UUID().uuidString)
    }

    // MARK: - 凭据存取

    public static func loadCredentials(from url: URL) -> Credentials? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func saveCredentials(_ credentials: Credentials, to url: URL) throws {
        try Paths.ensureParentDirectory(of: url)
        let data = try JSONEncoder().encode(credentials)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func loadCredentials(for slotID: UUID) -> Credentials? {
        loadCredentials(from: webUICredentialsURL(for: slotID))
    }

    // MARK: - 网络

    private static let log = Logger(subsystem: "com.rexzhang.moonrise", category: "pairing")

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let delegate = SelfSignedTrustDelegate()
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    /// GET /api/pin（不带凭据）：401 = 已设凭据；302 → /welcome = 凭据为空；其余 = 离线。
    public static func probeWebUI(webPort: Int) async -> ProbeResult {
        guard let url = URL(string: "https://localhost:\(webPort)/api/pin") else { return .offline }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .offline }
            if http.statusCode == 401 { return .configured }
            if (300..<400).contains(http.statusCode) || http.url?.path == "/welcome" { return .empty }
            return .offline
        } catch {
            return .offline
        }
    }

    /// 预置凭据（D4）：等待 web 就绪（timeout 内），凭据为空则 POST /api/password 写入随机凭据并落盘。
    /// credentialsURL 为 MoonRise 侧凭据副本路径（实例 credentials/webui.json 或主实例同目录 webui.json）。
    /// 返回：已预置凭据（含本次预置）；nil = 用户已自设凭据（无副本但 401）或超时离线 → 降级走 Web UI。
    public static func provisionCredentialsIfNeeded(credentialsURL: URL, webPort: Int, timeout: TimeInterval = 12) async -> Credentials? {
        if let existing = loadCredentials(from: credentialsURL) {
            return existing
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch await probeWebUI(webPort: webPort) {
            case .configured:
                return nil   // 用户已自设凭据 → 降级
            case .empty:
                let credentials = generateCredentials()
                if await setPassword(credentials, webPort: webPort) {
                    try? saveCredentials(credentials, to: credentialsURL)
                    return credentials
                }
            case .offline:
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return nil
    }

    private static func setPassword(_ credentials: Credentials, webPort: Int) async -> Bool {
        guard let url = URL(string: "https://localhost:\(webPort)/api/password") else { return false }
        let body: [String: String] = [
            "currentUsername": "",
            "currentPassword": "",
            "newUsername": credentials.username,
            "newPassword": credentials.password,
            "confirmNewPassword": credentials.password,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// 待配对设备列表。凭据缺失抛 noCredentials。
    public static func pendingPairings(credentials: Credentials?, webPort: Int) async throws -> [PendingPairing] {
        guard let credentials else { throw InstanceWebAPIError.noCredentials }
        guard let url = URL(string: "https://localhost:\(webPort)/api/pin") else {
            throw InstanceWebAPIError.http(0, "")
        }
        let (data, response) = try await session.data(for: makeRequest("GET", url, credentials: credentials))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            log.error("待配对列表请求失败：HTTP \(code) \(body.prefix(120), privacy: .public)")
            throw InstanceWebAPIError.http(code, body)
        }
        let pairings = parsePendingPairings(data)
        log.info("待配对设备 \(pairings.count) 个：\(pairings.map { "\($0.name)@\($0.address)" }.joined(separator: ", "), privacy: .public)")
        return pairings
    }

    /// 取消待配对会话（配对失败后清理残留）。
    public static func cancelPairing(credentials: Credentials, webPort: Int, pairingID: String) async throws {
        guard let url = URL(string: "https://localhost:\(webPort)/api/pin") else {
            throw InstanceWebAPIError.http(0, "")
        }
        var request = makeRequest("DELETE", url, credentials: credentials)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["pairing_id": pairingID])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            log.error("取消配对失败：HTTP \(code) \(body.prefix(120), privacy: .public)")
            throw InstanceWebAPIError.http(code, body)
        }
        log.info("已取消配对会话 \(pairingID, privacy: .public)")
    }

    /// 提交 PIN。Sunshine 的 POST /api/pin 会阻塞到客户端三步握手（challenge → secret）完成才返回，
    /// 响应体 {"status": true|false} 即最终配对结果；请求超时需盖过服务端 ping_timeout（默认 30s）。
    public static func submitPin(credentials: Credentials, webPort: Int, pairingID: String, name: String, pin: String) async throws -> Bool {
        log.info("PIN 提交：pairing_id=\(pairingID, privacy: .public) name=\(name, privacy: .public) pin=\(pin, privacy: .public)")
        guard isValidPin(pin) else { throw InstanceWebAPIError.invalidPin }
        guard let url = URL(string: "https://localhost:\(webPort)/api/pin") else {
            throw InstanceWebAPIError.http(0, "")
        }
        let body: [String: String] = ["name": name, "pairing_id": pairingID, "pin": pin]
        var request = makeRequest("POST", url, credentials: credentials)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 35
        request.httpBody = try? JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InstanceWebAPIError.http(0, "")
        }
        let responseText = String(data: data, encoding: .utf8) ?? ""
        log.info("PIN 提交响应：HTTP \(http.statusCode) \(responseText.prefix(200), privacy: .public)")
        guard http.statusCode == 200 else {
            throw InstanceWebAPIError.http(http.statusCode, responseText)
        }
        // 响应体严格解析：status == true 才算成功（status 由服务端阻塞语义给出，即最终结果）
        struct Body: Decodable { let status: Bool? }
        if let body = try? JSONDecoder().decode(Body.self, from: data), let status = body.status {
            log.info("PIN 配对结果：\(status)")
            return status
        }
        // 响应无 status 字段（异常形态）：以 /api/clients/list 是否出现该设备为权威判定
        // （配对会话在成功与失败时都会被移出待配对列表，不能用"会话消失"推断成功）
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1))
            if await isClientPaired(credentials: credentials, webPort: webPort, name: name) {
                log.info("已配对设备列表出现 \(name, privacy: .public)，判定成功")
                return true
            }
        }
        log.error("已配对设备列表未出现 \(name, privacy: .public)，判定失败")
        return false
    }

    /// 已配对设备名列表（GET /api/clients/list → {"named_certs": [{"name", "uuid", "enabled"}]}）。
    public static func pairedClientNames(credentials: Credentials, webPort: Int) async throws -> [String] {
        guard let url = URL(string: "https://localhost:\(webPort)/api/clients/list") else {
            throw InstanceWebAPIError.http(0, "")
        }
        let (data, response) = try await session.data(for: makeRequest("GET", url, credentials: credentials))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw InstanceWebAPIError.http(code, body)
        }
        return parseClientNames(data)
    }

    /// 解析 /api/clients/list 响应，返回已配对设备名。
    public static func parseClientNames(_ data: Data) -> [String] {
        struct Client: Decodable { let name: String? }
        struct Wrapper: Decodable { let namedCerts: [Client]? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let clients = (try? decoder.decode(Wrapper.self, from: data))?.namedCerts ?? []
        return clients.compactMap(\.name)
    }

    private static func isClientPaired(credentials: Credentials, webPort: Int, name: String) async -> Bool {
        (try? await pairedClientNames(credentials: credentials, webPort: webPort))?.contains(name) ?? false
    }

    // MARK: - 私有

    private static func makeRequest(_ method: String, _ url: URL, credentials: Credentials?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let credentials {
            request.setValue(basicAuthHeader(credentials), forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
