import Foundation

/// A blocked startup has no persistent preference destination.
final class FailedMigrationPreferences: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    override func object(forKey name: String) -> Any? { lock.withLock { values[name] ?? registered[name] } }
    override func set(_ value: Any?, forKey name: String) { lock.withLock { values[name] = value } }
    override func removeObject(forKey name: String) { _ = lock.withLock { values.removeValue(forKey: name) } }
    override func register(defaults: [String: Any]) {
        lock.withLock { registered.merge(defaults) { _, new in new } }
    }
    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { _, new in new } }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? { nil }
    override func setPersistentDomain(_ domain: [String: Any], forName name: String) {}
    override func removePersistentDomain(forName name: String) {}
    override func synchronize() -> Bool { true }
}
