import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ActionConfirmationView: View {
    let title: String
    let message: String
    let confirmTitle: String
    var destructive = true
    var showsCancel = true
    let action: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader).accessibilityIdentifier("confirmation.title")
            if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("confirmation.message") }
            VStack(spacing: 6) {
                Button(role: destructive ? .destructive : nil, action: action) {
                    Text(confirmTitle).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 24)
                }.buttonStyle(MonochromeButtonStyle(compact: true)).accessibilityIdentifier("confirmation.confirm")
                if showsCancel {
                    Button(action: cancel) { Text("取消").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityIdentifier("confirmation.cancel")
                }
            }
        }.padding(20)
    }
}

private struct ActionConfirmationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        content.compactPopup(isPresented: $isPresented, preferredWidth: CompactPopupSizing.width(title: title, message: message, button: confirmTitle)) { dismiss in
            ActionConfirmationView(title: title, message: message, confirmTitle: confirmTitle, destructive: destructive,
                                   action: { dismiss(then: action) }, cancel: { dismiss() })
        }
    }
}

private struct CompactPopupRequest { let operation: () -> Void }

struct CompactPopupDismiss {
    fileprivate let handler: (CompactPopupRequest) -> Void
    func callAsFunction(then operation: @escaping () -> Void = {}) { handler(CompactPopupRequest(operation: operation)) }
}

private enum CompactPopupSizing {
    static func width(title: String, message: String, button: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .title3)]).width
        let buttonWidth = (button as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width
        let messageWidth = message.split(separator: "\n").map {
            (String($0) as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline)]).width
        }.max() ?? 0
        return max(240, max(titleWidth, max(buttonWidth, messageWidth)) + 40)
    }
}

/// A small, content-sized modal; native full-screen presentation supplies the
/// modal focus and blocks the tab bar without forcing a full-width sheet.
private struct CompactPopupSurface<Popup: View>: View {
    let preferredWidth: CGFloat
    let finished: (CompactPopupRequest) -> Void
    let popup: (CompactPopupDismiss) -> Popup
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 0
    @State private var visible = false
    @State private var closing = false
    @State private var closeTask: Task<Void, Never>?
    private var animation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

    var body: some View {
        GeometryReader { geometry in
            let maximumWidth = min(typeSize.isAccessibilitySize ? 420 : 340, max(1, geometry.size.width - 32))
            let width = min(maximumWidth, max(min(240, maximumWidth), preferredWidth))
            let maximumHeight = max(1, geometry.size.height - 32)
            ZStack(alignment: .bottom) {
                Color.black.opacity(visible ? 0.25 : 0).ignoresSafeArea()
                    .animation(animation, value: visible)
                    .onTapGesture { close(CompactPopupRequest(operation: {})) }
                    .accessibilityHidden(true)
                ScrollView {
                    popup(CompactPopupDismiss(handler: close))
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if abs(contentHeight - height) > 0.5 { contentHeight = height }
                            if !closing && !visible { visible = true }
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: width, height: min(maximumHeight, max(1, contentHeight)))
                .accessibilityIdentifier("compact.popup")
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .simultaneousGesture(TapGesture().onEnded { })
                .allowsHitTesting(!closing)
                .animation(animation) { panel in panel.opacity(visible ? 1 : 0).offset(y: visible ? 0 : 18) }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityAction(.escape) { close(CompactPopupRequest(operation: {})) }
        .onDisappear { closeTask?.cancel() }
    }
    private func close(_ request: CompactPopupRequest) {
        guard !closing else { return }
        closing = true; visible = false
        closeTask = Task { @MainActor in
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            finished(request)
        }
    }
}

private struct CompactPopupModifier<Popup: View>: ViewModifier {
    @Binding var isPresented: Bool
    let preferredWidth: CGFloat
    let onDismiss: () -> Void
    let popup: (CompactPopupDismiss) -> Popup
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hosted = false
    @State private var dismissing = false
    @State private var completion: CompactPopupRequest?
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $hosted, onDismiss: {
            let operation = completion; completion = nil
            // Operations may read the original presentation binding (for
            // example, the account awaiting removal), so clear it afterward.
            operation?.operation()
            isPresented = false
            onDismiss()
            dismissing = false
        }) {
            CompactPopupSurface(preferredWidth: preferredWidth, finished: { request in
                completion = request
                dismissing = true
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { hosted = false }
            }, popup: popup)
            .environment(\.dynamicTypeSize, typeSize)
            .presentationBackground(.clear)
            .interactiveDismissDisabled()
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            guard !presented || !dismissing else { return }
            guard hosted != presented else { return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { hosted = presented }
        }
    }
}

extension View {
    func compactPopup<Popup: View>(isPresented: Binding<Bool>, preferredWidth: CGFloat = 300,
                                  onDismiss: @escaping () -> Void = {},
                                  @ViewBuilder content: @escaping (CompactPopupDismiss) -> Popup) -> some View {
        modifier(CompactPopupModifier(isPresented: isPresented, preferredWidth: preferredWidth, onDismiss: onDismiss, popup: content))
    }
}
extension View {
    func actionConfirmation(isPresented: Binding<Bool>, title: String, message: String = "", confirmTitle: String, destructive: Bool = true, action: @escaping () -> Void) -> some View {
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
