import Foundation

public enum GitSignatureObject: String, Sendable {
    case commit, tag
}

public enum GitSignatureState: String, Sendable {
    case verified, unsigned, missingPublicKey, unverifiable, invalid, untrusted
    public var title: String {
        switch self {
        case .verified: L10n.text("签名验证通过")
        case .unsigned: L10n.text("没有签名")
        case .missingPublicKey: L10n.text("缺少公钥")
        case .unverifiable: L10n.text("无法验证签名")
        case .invalid: L10n.text("签名无效")
        case .untrusted: L10n.text("签名有效，信任不足")
        }
    }
}

public struct GitSignatureReport: Sendable {
    public let objectID: String
    public let object: GitSignatureObject
    public let state: GitSignatureState
    public let cryptographicallyValid: Bool
    public let identityTrusted: Bool
    public let format: String?
    public let fingerprint: String?
    public let signer: String?
    public let details: String
}
