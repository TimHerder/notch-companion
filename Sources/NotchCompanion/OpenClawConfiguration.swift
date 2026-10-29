import Foundation
import CryptoKit
import Security

/// Reads the chosen native config and bounded native includes without writes.
/// Secret stores are never executed; unsupported resolution gets setup guidance.
struct OpenClawConfiguration: Decodable {
    struct Secret: Decodable {
        var literal: String?
        var source: String?
        var id: String?
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { literal = string; return }
            let object = try value.decode([String: String].self)
            source = object["source"]; id = object["id"]
        }
        func resolve(_ environment: [String: String]) throws -> String? {
            if let literal {
                if literal.hasPrefix("${"), literal.hasSuffix("}") {
                    let key = String(literal.dropFirst(2).dropLast())
                    guard let value = environment[key], !value.isEmpty else { throw AppError("OpenClaw's Gateway credential environment variable is unavailable to this app. Launch with the native environment configured.") }
                    return value
                }
                return literal
            }
            if source == "env", let id, let value = environment[id], !value.isEmpty { return value }
            throw AppError("This Gateway credential uses a native secret resolver unavailable to the companion. Expose the existing Gateway bootstrap credential through OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD; keep model sign-in owned by OpenClaw.")
        }
    }
    struct Gateway: Decodable {
        struct Auth: Decodable { var mode: String?; var token: Secret?; var password: Secret? }
        struct TLS: Decodable { var enabled: Bool? }
        var port: Int?; var mode: String?; var auth: Auth?; var tls: TLS?
    }
    struct Agents: Decodable {
        struct Agent: Decodable { var id: String; var workspace: String?; var `default`: Bool? }
        struct Entry: Decodable { var workspace: String?; var `default`: Bool? }
        struct Defaults: Decodable { var workspace: String? }
        var list: [Agent]?; var entries: [String: Entry]?; var defaults: Defaults?; var ownership: String?
        var roster: [Agent] {
            if let entries { return entries.map { Agent(id: $0.key, workspace: $0.value.workspace, default: $0.value.default) }.sorted { $0.id < $1.id } }
            return list ?? []
        }
    }
    var gateway: Gateway?
    var agents: Agents?

    static func load(directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("openclaw.json")
        let data = try OpenClawConfigIncludes.read(url, environment: environment)
        let decoder = JSONDecoder(); decoder.allowsJSON5 = true
        do { return try decoder.decode(Self.self, from: data) }
        catch { throw AppError("The selected OpenClaw configuration could not be read. Supported Gateway configuration is native JSON/JSON5 with token/password or environment secret references.") }
    }
    static func configuredAgents(profileID: String) throws -> [String] {
        let config = try load(directory: profileID)
        if config.agents?.entries == nil && config.agents?.list == nil { return ["main"] }
        return config.agents?.roster.map(\.id) ?? []
    }
    static func defaultAgent(profileID: String) throws -> String {
        let config = try load(directory: profileID)
        if let selected = config.inheritedWorkspaceOwner { return selected }
        throw AppError("This OpenClaw profile has several configured agents. Choose the intended agent explicitly in Settings.")
    }
    static func workspace(profileID: String, agent: String) throws -> String? {
        let config = try load(directory: profileID)
        let path: String
        if let explicit = config.agents?.roster.first(where: { $0.id == agent })?.workspace, !explicit.isEmpty { path = explicit }
        else if config.inheritedWorkspaceOwner == agent {
            path = config.agents?.defaults?.workspace ?? URL(fileURLWithPath: profileID).appendingPathComponent("workspace").path
        } else if let root = config.agents?.defaults?.workspace {
            path = root + "/" + agent
        } else { path = URL(fileURLWithPath: profileID).appendingPathComponent("workspace-" + agent).path }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expanded = path == "~" ? home.path : path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        guard expanded.hasPrefix("/") else { throw AppError("The selected OpenClaw agent workspace must resolve to an absolute native folder.") }
        return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private var inheritedWorkspaceOwner: String? {
        let roster = agents?.roster ?? []
        if roster.isEmpty && agents?.entries == nil && agents?.list == nil { return "main" }
        if roster.count == 1 { return roster[0].id }
        if agents?.ownership != "explicit" {
            let marked = roster.filter { $0.default == true }
            if marked.count == 1 { return marked[0].id }
        }
        return nil
    }
    func endpoint() throws -> URL {
        guard gateway?.mode != "remote", gateway?.tls?.enabled != true else {
            throw AppError("This adapter connects to an existing local loopback Gateway. Remote Gateways and custom TLS require a supported native transport setup.")
        }
        let port = gateway?.port ?? 18789
        guard (1...65535).contains(port), let url = URL(string: "ws://127.0.0.1:\(port)") else { throw AppError("OpenClaw's configured local Gateway port is invalid.") }
        return url
    }
    func auth(environment: [String: String]) throws -> [String: String] {
        if let token = environment["OPENCLAW_GATEWAY_TOKEN"], !token.isEmpty { return ["token": token] }
        if let password = environment["OPENCLAW_GATEWAY_PASSWORD"], !password.isEmpty { return ["password": password] }
        if gateway?.auth?.mode == "none" { return [:] }
        if gateway?.auth?.mode == "password", let password = try gateway?.auth?.password?.resolve(environment) { return ["password": password] }
        if let token = try gateway?.auth?.token?.resolve(environment) { return ["token": token] }
        throw AppError("OpenClaw's local Gateway bootstrap credential is unavailable. Set up Gateway authentication with OpenClaw normally, then reconnect.")
    }
}

/// Companion identity and scoped Gateway tokens live in Keychain, never in the
/// native agent profile. No native device identity or OAuth grant is borrowed.
struct OpenClawDevice: Codable {
    var privateKey: Data
    var token: String?
    var scopes: [String] = []
    static let requiredScopes = ["operator.read", "operator.write", "operator.approvals", "operator.questions"]
    static func account(directory: String, endpoint: URL) -> String {
        SHA256.hash(data: Data((directory + "|" + endpoint.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(account: String) throws -> Self {
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try JSONDecoder().decode(Self.self, from: data) }
        guard status == errSecItemNotFound else { throw AppError("Unlock your login Keychain to use the companion's OpenClaw device identity (Keychain \(status)).") }
        let device = Self(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
        try device.save(account: account); return device
    }
    func save(account: String) throws {
        let data = try JSONEncoder().encode(self), query = Self.keychainQuery(account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError("The companion could not save its OpenClaw pairing in Keychain (\(status)).") }
    }
    private static func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "NotchCompanion.OpenClaw", kSecAttrAccount as String: account]
    }
    func proof(nonce: String, timestamp: Int, token: String?, scopes: [String]) throws -> [String: Any] {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let publicKey = key.publicKey.rawRepresentation
        let id = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        let payload = ["v3", id, "gateway-client", "ui", "operator", scopes.joined(separator: ","), String(timestamp), token ?? "", nonce, "macos", "mac"].joined(separator: "|")
        return ["id": id, "publicKey": Self.base64url(publicKey), "signature": Self.base64url(try key.signature(for: Data(payload.utf8))), "signedAt": timestamp, "nonce": nonce]
    }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
