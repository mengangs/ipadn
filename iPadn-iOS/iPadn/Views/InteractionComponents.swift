import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ActionConfirmationView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let confirmTitle: LocalizedStringKey
    var destructive = true
    var showsCancel = true
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView { confirmation }.scrollBounceBehavior(.basedOnSize)
                    .accessibilityIdentifier("confirmation.scroll")
            } else { confirmation }
        }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(showsCancel ? 320 : 280), .large])
        .presentationDragIndicator(.visible).presentationCornerRadius(28)
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader).accessibilityIdentifier("confirmation.title")
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("confirmation.message") }
            VStack(spacing: 10) {
                Button(role: destructive ? .destructive : nil) { action(); dismiss() } label: {
                    Text(confirmTitle).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 24)
                }.buttonStyle(MonochromeButtonStyle()).accessibilityIdentifier("confirmation.confirm")
                if showsCancel {
                    Button { dismiss() } label: { Text("取消").frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityIdentifier("confirmation.cancel")
                }
            }
        }.padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
    }
}

private struct ActionConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let confirmTitle: LocalizedStringKey
    let destructive: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ActionConfirmationView(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, action: action)
                // A presented sheet can reset the parent's SwiftUI override.
                // Keep its text size aligned with the page that opened it.
                .environment(\.dynamicTypeSize, typeSize)
        }
    }
}
extension View {
    func actionConfirmation(isPresented: Binding<Bool>, title: LocalizedStringKey, message: LocalizedStringKey? = nil, confirmTitle: LocalizedStringKey, destructive: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(ActionConfirmationModifier(isPresented: isPresented, title: title, message: message, confirmTitle: confirmTitle, destructive: destructive, action: action))
    }
}

struct PackageDocumentPicker: UIViewControllerRepresentable {
    let completion: (Result<[URL], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Providers disagree about the IPA UTI. Allow files here, then validate the
        // extension and archive contents in the import service instead of disabling IPAs.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .archive], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<[URL], Error>) -> Void
        init(completion: @escaping (Result<[URL], Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(.success(urls)) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(.success([])) }
    }
}
