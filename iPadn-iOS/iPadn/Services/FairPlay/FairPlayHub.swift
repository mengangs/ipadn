import Foundation
import Combine

/// One decryption at a time for the whole app: the download page, the lab and
/// the UI test hook all drive the same service, so two runs can never overlap
/// and a run started outside the page still shows its sheet.
@MainActor
final class FairPlayHub: ObservableObject {
    static let shared = FairPlayHub()

    let service = FairPlayService()

    /// Set when something outside the sheet (auto mode, UI test) starts a run.
    @Published var presentSheet = false

    private init() {
        // Forward the service's changes so views observing the hub update.
        service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func start(source: URL, displayName: String, present: Bool = true) {
        service.start(source: source, displayName: displayName)
        if present { presentSheet = true }
    }
}
