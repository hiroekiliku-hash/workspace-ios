import Foundation

/// Display preferences stay on this device and never change workspace content or wire values.
enum WorkspaceLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"
    static let preferenceKey = "appLanguage"
    static let sharedDefaults = "group.org.example.workspace"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: WorkspaceLocalization.string("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
    static var current: Self {
        let defaults = Bundle.main.bundleURL.pathExtension == "appex"
            ? UserDefaults(suiteName: sharedDefaults) ?? .standard : .standard
        return Self(rawValue: defaults.string(forKey: preferenceKey) ?? "system") ?? .system
    }
    func resolvedIdentifier(preferredLanguages: [String]) -> String {
        guard self == .system else { return rawValue }
        return Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: preferredLanguages).first ?? "zh-Hans"
    }
}

/// SwiftUI uses the same locale via its environment. Foundation/UIKit labels use this lookup
/// against Apple's compiled String Catalog, including the app's in-app language override.
enum WorkspaceLocalization {
    static var identifier: String {
        WorkspaceLanguage.current.resolvedIdentifier(preferredLanguages: Locale.preferredLanguages)
    }
    static var locale: Locale { Locale(identifier: identifier) }
    static func string(_ key: String) -> String {
        string(key, language: identifier, bundle: .main)
    }
    static func string(_ key: String, language: String, bundle: Bundle) -> String {
        guard let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) else {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return localized.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}
