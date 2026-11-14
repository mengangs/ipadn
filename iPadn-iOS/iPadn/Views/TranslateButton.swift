import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// The system sheet is the default on all supported versions. Users may opt
/// into on-device, in-place translation on iOS 18+ from Settings.
struct TranslateButton: View {
    let text: String
    @Binding var translation: String?
    @EnvironmentObject private var store: ToolStore
    @State private var presented = false

    static var available: Bool {
        if #available(iOS 17.4, *) { return true }
        return false
    }

    static func isForeign(_ text: String) -> Bool {
        let sample = String(text.prefix(600))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let found = DetectedLanguageCache.shared.dominantLanguage(for: sample) else { return false }
        let mine = AppText.locale.language.languageCode?.identifier ?? "en"
        return !found.hasPrefix(mine)
    }

    static func offered(for text: String, translation: String?) -> Bool {
        translation != nil || (available && isForeign(text))
    }

    var body: some View {
        if translation != nil {
            Button { withAnimation(.easeOut(duration: 0.2)) { translation = nil } } label: {
                Label("显示原文", systemImage: "character.bubble")
            }
            .accessibilityIdentifier("translation.original")
        } else if #available(iOS 18.0, *), store.settings.directTranslation {
            DirectTranslationButton(text: text, translation: $translation)
        } else if #available(iOS 17.4, *) {
            Button { presented = true } label: { Label("翻译", systemImage: "translate") }
                .accessibilityIdentifier("translation.start")
                .translationPresentation(isPresented: $presented, text: text) { translated in
                    withAnimation(.easeOut(duration: 0.2)) { translation = translated }
                }
        }
    }
}

@available(iOS 18.0, *)
private struct DirectTranslationButton: View {
    let text: String
    @Binding var translation: String?
    @EnvironmentObject private var store: ToolStore
    @State private var configuration: TranslationSession.Configuration?
    @State private var busy = false
    @State private var requestID = UUID()

    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            requestID = UUID()
            if configuration != nil {
                configuration?.invalidate()
            } else {
                configuration = TranslationSession.Configuration(source: nil, target: AppText.locale.language)
            }
        } label: {
            if busy {
                HStack(spacing: 6) { ProgressView(); Text("正在翻译…") }
            } else {
                Label("翻译", systemImage: "translate")
            }
        }
        .disabled(busy)
        .accessibilityIdentifier("translation.start")
        .translationTask(configuration) { session in
            let source = text, request = requestID
            do {
                let response = try await session.translate(source)
                try Task.checkCancellation()
                await MainActor.run {
                    guard requestID == request, text == source, translation == nil else { return }
                    busy = false
                    withAnimation(.easeOut(duration: 0.2)) { translation = response.targetText }
                }
            } catch is CancellationError {
                await MainActor.run { if requestID == request { busy = false } }
            } catch {
                await MainActor.run {
                    guard requestID == request, text == source else { return }
                    busy = false
                    store.errorMessage = AppText.text("翻译失败：\(error.localizedDescription)")
                }
            }
        }
        .compatibleOnChange(of: text) { _ in
            // Invalidate the result, not the session: it belongs to translationTask.
            requestID = UUID()
            configuration = nil
            busy = false
        }
        .onDisappear { requestID = UUID() }
    }
}

/// Opening settings does not start a language download. Old systems never
/// instantiate a session: the system translation sheet remains available.
struct TranslationSettingsSections: View {
    @EnvironmentObject private var store: ToolStore
    var body: some View {
        Section {
            if #available(iOS 18.0, *) {
                Toggle("直接替换翻译", isOn: $store.settings.directTranslation)
                    .accessibilityIdentifier("settings.translation.direct")
            }
        } header: { Text("翻译") } footer: {
            Text("默认使用系统翻译面板。开启后，点击翻译会直接替换正文，并可显示原文。")
            if #unavailable(iOS 18.0) {
                Text("直接替换翻译需要 iOS 18 或更高版本。")
            }
        }
        if #available(iOS 18.0, *), store.settings.directTranslation {
            TranslationLanguageResources()
        }
    }
}

private final class DetectedLanguageCache: @unchecked Sendable {
    static let shared = DetectedLanguageCache()
    private let lock = NSLock()
    private var entries: [String: String] = [:]

    func dominantLanguage(for sample: String) -> String? {
        lock.lock()
        if let cached = entries[sample] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let detected = recognizer.dominantLanguage?.rawValue

        lock.lock()
        if entries.count >= 256 { entries.removeAll(keepingCapacity: true) }
        entries[sample] = detected ?? ""
        lock.unlock()
        return detected
    }
}

@available(iOS 18.0, *)
private struct TranslationLanguageResources: View {
    @State private var languages: [Locale.Language] = []
    @State private var source = ""
    @State private var loaded = false
    private var target: Locale.Language { AppText.locale.language }
    private func name(_ language: Locale.Language) -> String {
        AppText.locale.localizedString(forIdentifier: language.minimalIdentifier)
            ?? AppText.locale.localizedString(forIdentifier: language.maximalIdentifier)
            ?? language.minimalIdentifier
    }
    private func sameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        let ma = Locale.Language(identifier: a.maximalIdentifier)
        let mb = Locale.Language(identifier: b.maximalIdentifier)
        guard ma.languageCode == mb.languageCode else { return false }
        return ma.script == nil || mb.script == nil || ma.script == mb.script
    }
    var body: some View {
        Section {
            if !loaded {
                ProgressView().accessibilityLabel("正在加载…")
            } else if languages.isEmpty {
                Text("不支持这组语言")
            } else {
                Picker("原文语言", selection: $source) {
                    ForEach(languages, id: \.maximalIdentifier) { language in
                        Text(verbatim: name(language)).tag(language.maximalIdentifier)
                    }
                }
                .accessibilityIdentifier("settings.translation.source")
                LabeledContent { Text(verbatim: name(target)) } label: { Text("译文语言") }
                TranslationResourcePreparation(source: Locale.Language(identifier: source), target: target)
                    // A changed pair gets a new view-bound session; late results
                    // from its predecessor cannot update the new status.
                    .id(source + "|" + target.maximalIdentifier)
            }
        } header: { Text("翻译语言包") } footer: {
            Text("译文使用 iPadn 的界面语言。选择需要翻译的原文语言，再准备语言包；其他语言首次使用时仍可能需要下载。")
        }
        .id("settings.translation.resources")
        .task {
            let supported = await LanguageAvailability().supportedLanguages
            guard !Task.isCancelled else { return }
            languages = supported
                .filter { !sameLanguage($0, target) }
                .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
            source = (languages.first { $0.languageCode?.identifier == "en" }
                ?? languages.first)?.maximalIdentifier ?? ""
            loaded = true
        }
    }
}

@available(iOS 18.0, *)
private struct TranslationResourcePreparation: View {
    let source: Locale.Language
    let target: Locale.Language
    @EnvironmentObject private var store: ToolStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: LanguageAvailability.Status?
    @State private var configuration: TranslationSession.Configuration?
    @State private var busy = false

    var body: some View {
        HStack {
            Group {
                switch status {
                case .installed: Label("语言包已就绪", systemImage: "checkmark.circle")
                case .supported: Text("需要下载语言包")
                case .unsupported: Text("不支持这组语言")
                case nil: Text("检查语言包…")
                @unknown default: Text("不支持这组语言")
                }
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings.translation.status")
            Spacer()
            if busy { ProgressView().accessibilityLabel("正在准备…") }
        }
        // Status checks cannot trigger downloads. Only the button below creates
        // or invalidates a configuration. Sessions never escape this closure.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refresh()
        }
        .translationTask(configuration) { session in
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
            } catch is CancellationError {
                // Dismissing Apple's resource sheet is not an app error.
            } catch {
                guard !Task.isCancelled else { return }
                store.errorMessage = AppText.text("语言包准备失败：\(error.localizedDescription)")
            }
            guard !Task.isCancelled else { return }
            busy = false
            await refresh()
        }
        if status == .supported {
            Button("准备语言包") {
                guard !busy else { return }
                busy = true
                if configuration != nil { configuration?.invalidate() }
                else { configuration = .init(source: source, target: target) }
            }
            .disabled(busy)
            .accessibilityIdentifier("settings.translation.prepare")
        }
    }

    private func refresh() async {
        let current = await LanguageAvailability().status(from: source, to: target)
        guard !Task.isCancelled else { return }
        status = current
    }
}
