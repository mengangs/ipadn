import BackgroundTasks
import UserNotifications

/// Checks downloaded apps for newer store versions, and followed apps for
/// version, price and removal changes, while iPadn is in the background.
/// iOS decides when the check actually runs.
enum UpdateCheckScheduler {
    static let identifier = "app.local.iPadn.update-check"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                let store = AppContainer.shared
                // iOS allows about half a minute: the checks run side by side,
                // and each notifies as soon as it is done.
                await withTaskGroup(of: Void.self) { group in
                    if store.settings.watchNotifications {
                        group.addTask { @MainActor in
                            let changes = await store.checkWatched(force: true)
                            if !Task.isCancelled { store.notifyWatchChanges(changes) }
                        }
                    }
                    if store.settings.updateNotifications {
                        group.addTask { @MainActor in
                            await store.checkForUpdates(force: true)
                            if !Task.isCancelled { store.notifyNewUpdates() }
                        }
                    }
                    if store.settings.appUpdateCheck {
                        group.addTask { @MainActor in
                            await store.checkAppUpdate()
                            if !Task.isCancelled { store.notifyAppUpdate() }
                        }
                    }
                }
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
