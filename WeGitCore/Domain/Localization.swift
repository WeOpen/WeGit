import Foundation
import Observation
import Synchronization

public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for preferred in preferredLanguages {
            if preferred.lowercased().hasPrefix("zh") { return .simplifiedChinese }
            if preferred.lowercased().hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// Interpolation keeps repository data as arguments, outside the translation key.
public struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable {
    let key: String
    let arguments: [String]

    public init(stringLiteral value: String) {
        key = value.replacingOccurrences(of: "%", with: "%%")
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            arguments.append(String(describing: value))
            key += "%\(arguments.count)$@"
        }
    }
}

/// Observed by view bodies, safe to read from Git worker tasks. Changing language
/// invalidates text without rebuilding windows, sessions, sheets or draft state.
private final class LanguageSelection: Observable, Sendable {
    private let registrar = ObservationRegistrar()
    private let storage = Mutex(AppLanguage.simplifiedChinese)

    var language: AppLanguage {
        get {
            registrar.access(self, keyPath: \.language)
            return storage.withLock { $0 }
        }
        set {
            registrar.withMutation(of: self, keyPath: \.language) {
                storage.withLock { $0 = newValue }
            }
        }
    }
}

public enum L10n {
    private static let selection = LanguageSelection()
    private static let resources: Bundle = {
        // The embedded command-line helper lives in Contents/Helpers, while
        // Xcode installs the shared package resources in Contents/Resources.
        if let directory = Bundle.main.executableURL?.deletingLastPathComponent(),
            directory.lastPathComponent == "Helpers",
            let bundle = Bundle(
                url: directory.deletingLastPathComponent()
                    .appending(path: "Resources/WeGit_WeGitCore.bundle"))
        {
            return bundle
        }
        return .module
    }()
    private static let english = localizedBundle("en")
    private static let chinese = localizedBundle("zh-Hans")

    public static var language: AppLanguage {
        get { selection.language }
        set { selection.language = newValue }
    }

    public static var locale: Locale { locale(for: language.resolved()) }

    public static func text(_ message: LocalizedMessage, language: AppLanguage? = nil) -> String {
        let resolved = (language ?? self.language).resolved()
        let format = bundle(for: resolved).localizedString(
            forKey: message.key, value: message.key, table: nil)
        return String(format: format, locale: locale(for: resolved), arguments: message.arguments)
    }

    /// For stable enum raw values used as display titles, never for arbitrary Git data.
    public static func key(_ key: String, language: AppLanguage? = nil) -> String {
        text(LocalizedMessage(stringLiteral: key), language: language)
    }

    /// Standard menu titles have their own context, such as File versus Files.
    public static func menuTitle(_ key: String, language: AppLanguage? = nil) -> String {
        bundle(for: (language ?? self.language).resolved()).localizedString(
            forKey: key, value: key, table: "MenuTitles")
    }

    public static func count(_ key: String, _ count: Int, language: AppLanguage? = nil) -> String {
        let resolved = (language ?? self.language).resolved()
        let format = bundle(for: resolved).localizedString(forKey: key, value: key, table: nil)
        return String(format: format, locale: locale(for: resolved), arguments: [Int64(count)])
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        language == .simplifiedChinese ? chinese : english
    }

    private static func locale(for language: AppLanguage) -> Locale {
        Locale(identifier: language == .simplifiedChinese ? "zh-Hans" : "en")
    }

    private static func localizedBundle(_ language: String) -> Bundle {
        resources.url(forResource: language, withExtension: "lproj")
            .flatMap(Bundle.init(url:)) ?? resources
    }
}
