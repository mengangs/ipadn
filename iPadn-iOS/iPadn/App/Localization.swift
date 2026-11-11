import Foundation

/// Text the app composes outside SwiftUI's literal-key lookup: messages in
/// models and services, notifications, exported files, and strings handed to
/// views as `String` values.
///
/// SwiftUI localizes its own `Text("…")` keys through the bundle. Everything
/// here resolves the same language explicitly, so the two never disagree, and
/// tests can pin a language instead of following the machine.
enum AppText {
    /// The language the interface is shown in: the localization Xcode bundled
    /// and the device picked.
    nonisolated(unsafe) static var locale: Locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    /// Numbers, dates and currency amounts follow the user's region, which can
    /// differ from the interface language.
    static var formattingLocale: Locale { .current }

    /// `String(localized:locale:)` only uses the locale for formatting; the
    /// language comes from the bundle. Look the table up ourselves so an
    /// explicit locale (a test, for example) selects its own language.
    static func text(_ value: String.LocalizationValue, in locale: Locale? = nil) -> String {
        let locale = locale ?? AppText.locale
        guard let table = table(for: locale) else {
            return String(localized: value, bundle: .main, locale: locale)
        }
        return String(localized: value, bundle: table, locale: locale)
    }

    /// The `.lproj` bundle for a locale, matched by exact identifier first,
    /// then by language and script, so `zh_CN` finds `zh-Hans` and `zh_TW`
    /// finds `zh-Hant` whatever order the bundle lists them in.
    private static func table(for locale: Locale) -> Bundle? {
        let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        let language = locale.language.languageCode?.identifier
        return tables.withLock { cache in
            if let cached = cache[identifier] { return cached }
            let available = Bundle.main.localizations
            let match = available.first { $0.caseInsensitiveCompare(identifier) == .orderedSame }
                ?? available.first { sameLanguageAndScript($0, locale) }
                ?? available.first { Locale(identifier: $0).language.languageCode?.identifier == language }
            let bundle = match.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:))
            cache[identifier] = bundle
            return bundle
        }
    }

    private static let tables = NSLockedValue<[String: Bundle?]>([:])

    static func sameLanguageAndScript(_ localization: String, _ locale: Locale) -> Bool {
        let a = Locale.Language(identifier: Locale.Language(identifier: localization).maximalIdentifier)
        let b = Locale.Language(identifier: locale.language.maximalIdentifier)
        return a.languageCode == b.languageCode && a.script == b.script
    }
}
