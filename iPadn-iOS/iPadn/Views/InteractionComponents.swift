import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct ActionConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let detail: String?
    let confirmTitle: LocalizedStringKey
    let destructive: Bool
    let action: () -> Void
    @State private var presentationToken = 0

    func body(content: Content) -> some View {
        let alertBinding = Binding<Bool>(
            get: { isPresented },
            set: { newValue in
                guard !newValue else { return }
                let token = presentationToken
                // Defer clearing the caller's binding by one main-actor turn so bindings backed
                // by optional state (`deleting != nil`) stay populated while the confirm button's
                // action closure runs, even if SwiftUI clears `isPresented` before firing it.
                Task { @MainActor in
                    if presentationToken == token && isPresented {
                        isPresented = false
                    }
                }
            }
        )
        content
            .compatibleOnChange(of: isPresented) { shown in
                if shown { presentationToken += 1 }
            }
            .alert(title, isPresented: alertBinding) {
                Button("取消", role: .cancel) {
                    presentationToken += 1
                    isPresented = false
                }
                Button(confirmTitle, role: destructive ? .destructive : nil) {
                    presentationToken += 1
                    action()
                    isPresented = false
                }
            } message: {
                alertMessage
            }
    }

    @ViewBuilder
    private var alertMessage: some View {
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let message, !trimmedDetail.isEmpty {
            Text(message) + Text(verbatim: "\n\n" + trimmedDetail)
        } else if let message {
            Text(message)
        } else if !trimmedDetail.isEmpty {
            Text(verbatim: trimmedDetail)
        }
    }
}
extension View {
    func actionConfirmation(isPresented: Binding<Bool>, title: LocalizedStringKey, message: LocalizedStringKey? = nil, detail: String? = nil, confirmTitle: LocalizedStringKey, destructive: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(ActionConfirmationModifier(isPresented: isPresented, title: title, message: message, detail: detail, confirmTitle: confirmTitle, destructive: destructive, action: action))
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
