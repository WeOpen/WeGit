import Foundation

/// The application and its independent installer compile the same public trust roots.
/// Release preparation supplies public keys here; clients never create private keys.
public enum UpdateTrustConfiguration {
    private static let productionKeys: [UpdatePublicKey] = []

    public static var isConfigured: Bool { !productionKeys.isEmpty }

    public static func productionRing() throws -> UpdateKeyRing {
        guard isConfigured else { throw UpdateFailure.configurationMissing }
        return UpdateKeyRing(keys: productionKeys)
    }
}
