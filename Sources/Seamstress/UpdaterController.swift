import Cocoa
import Combine
import Sparkle

@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool = false
    @Published var automaticallyChecksForUpdates: Bool = false

    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController
    private var cancellable: AnyCancellable?

    init() {
        let publicKey = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let configured = isAppBundle && !publicKey.isEmpty && !feedURL.isEmpty
        self.isConfigured = configured

        self.controller = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        if configured {
            self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
            self.cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] canCheck in
                    self?.canCheckForUpdates = canCheck
                }
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
