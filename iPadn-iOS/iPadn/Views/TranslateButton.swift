import NaturalLanguage
import SwiftUI
import Translation

/// Opens the system translation sheet (iOS 17.4 or later) for text written in
/// another language. Choosing “Replace with Translation” there hands the
/// translation to the caller, which shows it until “Show Original”.
struct TranslateButton: View {
    let text: String
    @Binding var translation: String?
    @State private var presented = false

    static var available: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    /// Whether the text is mostly in a language other than the app's.
    static func isForeign(_ text: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(600)))
        guard let found = recognizer.dominantLanguage?.rawValue else { return false }
        let mine = AppText.locale.language.languageCode?.identifier ?? "en"
        return !found.hasPrefix(mine)
    }

    /// Whether to show the button at all for this text.
    static func offered(for text: String, translation: String?) -> Bool {
        translation != nil || (available && isForeign(text))
    }

    var body: some View {
        if translation != nil {
            Button { withAnimation(.easeOut(duration: 0.2)) { translation = nil } } label: {
                Label("显示原文", systemImage: "character.bubble")
            }
        } else if #available(iOS 17.4, *) {
            Button { presented = true } label: { Label("翻译", systemImage: "translate") }
                .translationPresentation(isPresented: $presented, text: text) { translated in
                    withAnimation(.easeOut(duration: 0.2)) { translation = translated }
                }
        }
    }
}
