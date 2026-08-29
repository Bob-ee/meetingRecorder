import Crypto
import Fluent
import Foundation
import Vapor

/// Who is calling: resolved from a device token on every request.
struct Principal: Authenticatable {
    let user: UserModel
    let workspace: WorkspaceModel
    let token: DeviceTokenModel

    var userID: UUID { user.id! }
    var workspaceID: UUID { workspace.id! }
}

struct TokenAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        let hash = Tokens.hash(bearer.token)
        guard let token = try await DeviceTokenModel.query(on: request.db)
            .filter(\.$tokenHash == hash)
            .filter(\.$revokedAt == nil)
            .with(\.$user).with(\.$workspace)
            .first() else { return }
        if token.lastUsedAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            token.lastUsedAt = Date()
            try? await token.save(on: request.db)
        }
        request.auth.login(Principal(user: token.user, workspace: token.workspace, token: token))
    }
}

extension Request {
    var principal: Principal {
        get throws { try auth.require(Principal.self) }
    }
}

enum Tokens {
    /// 256 bits of randomness, URL-safe. Only the hash is stored.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "mh_" + b64
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// AES-GCM under a master key kept in the data directory (0600). Used for provider secrets in the database.
struct Secrets {
    let key: SymmetricKey

    static func load(from url: URL) throws -> Secrets {
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return Secrets(key: SymmetricKey(data: data))
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Secrets(key: key)
    }

    func seal(_ plaintext: String) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key)
        guard let combined = box.combined else { throw Abort(.internalServerError, reason: "encryption failed") }
        return "enc:" + combined.base64EncodedString()
    }

    func open(_ stored: String) throws -> String {
        guard stored.hasPrefix("enc:"), let data = Data(base64Encoded: String(stored.dropFirst(4))) else { return stored }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key)
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Only localhost, the tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) and configured CIDRs may talk to the hub —
/// even before authentication. A bearer token is still required for every API call.
struct RemoteAllowlistMiddleware: AsyncMiddleware {
    struct CIDR {
        let network: UInt32
        let mask: UInt32
        init?(_ s: String) {
            let parts = s.split(separator: "/")
            guard let ip = CIDR.ipv4(String(parts[0])) else { return nil }
            let bits = parts.count > 1 ? (Int(parts[1]) ?? 32) : 32
            mask = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
            network = ip & mask
        }
        func contains(_ ip: UInt32) -> Bool { ip & mask == network }
        static func ipv4(_ s: String) -> UInt32? {
            let p = s.split(separator: ".").compactMap { UInt32($0) }
            guard p.count == 4, p.allSatisfy({ $0 < 256 }) else { return nil }
            return (p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]
        }
    }

    let cidrs: [CIDR]

    init(config: HubConfig) {
        cidrs = (["127.0.0.0/8", "100.64.0.0/10"] + config.allowedCIDRs).compactMap(CIDR.init)
    }

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard var ip = request.remoteAddress?.ipAddress else {
            throw Abort(.forbidden, reason: "unknown remote address")
        }
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
        if ip == "::1" || ip.lowercased().hasPrefix("fd7a:115c:a1e0:") { return try await next.respond(to: request) }
        if let v4 = CIDR.ipv4(ip), cidrs.contains(where: { $0.contains(v4) }) { return try await next.respond(to: request) }
        request.logger.warning("rejected connection from \(ip)")
        throw Abort(.forbidden, reason: "the hub only accepts connections from localhost and your tailnet (add ranges to allowedCIDRs in config.json)")
    }
}
