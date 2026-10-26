import Foundation
import OSLog
#if os(macOS)
import AppKit
#else
import BackgroundTasks
import UIKit
#endif

#if os(iOS)
@MainActor enum WorkspaceBackgroundSync {
    static let taskIdentifier = "org.example.workspace.native.ios.refresh"

    static func updateSchedule(for store: WorkspaceStore?) {
        guard store?.isDemoMode != true, store?.demoStore == nil else { return }
        guard let store, store.canAutomaticallySync else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func perform(_ store: WorkspaceStore?) async {
        guard store?.isDemoMode != true, store?.demoStore == nil else { return }
        guard let store, store.canAutomaticallySync else {
            updateSchedule(for: store)
            return
        }
        // Schedule the next opportunity before starting so cancellation does not
        // silently disable future refreshes. The system decides the actual time.
        updateSchedule(for: store)
        guard !store.syncing else { return }
        try? await store.synchronize()
    }
}
#endif

fileprivate enum WorkspaceRemoteSyncResult { case newData, noData, failed }

#if os(iOS)
@MainActor private final class WorkspaceBackgroundFetchCompletion {
    private var completed = false
    private let handler: (UIBackgroundFetchResult) -> Void
    init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) { self.handler = handler }
    var isCompleted: Bool { completed }
    func finish(_ result: WorkspaceRemoteSyncResult) {
        guard !completed else { return }
        completed = true
        switch result {
        case .newData: handler(.newData)
        case .noData: handler(.noData)
        case .failed: handler(.failed)
        }
    }
}
#endif

@MainActor final class RemotePushBridge {
    static let shared = RemotePushBridge()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.example.workspace", category: "RemoteSync")
    weak var store: WorkspaceStore?
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RemotePushEnabled") as? Bool == true
    }
    static func registerWithApple() throws {
        guard shared.store?.isDemoMode != true, shared.store?.demoStore == nil else { return }
        guard isEnabled else {
            throw WorkspaceFailure.invalid("请先在 Xcode 为目标添加 Push Notifications，并将 Info.plist 的 RemotePushEnabled 改为 YES。当前本地通知不需要此能力。")
        }
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
    }
    func registered(_ token: Data) {
        guard store?.isDemoMode != true, store?.demoStore == nil else { return }
        logger.notice("APNs device token received")
        Task {
            guard let store, !store.isDemoMode, store.demoStore == nil else { return }
            do {
                try await store.backend.registerDevice(token)
                guard !store.isDemoMode, store.demoStore == nil else { return }
                store.information = "APNs 设备已向你的服务器注册。"
            } catch {
                guard !store.isDemoMode, store.demoStore == nil else { return }
                store.errorMessage = error.localizedDescription
            }
        }
    }
    func failed(_ error: Error) {
        guard store?.isDemoMode != true, store?.demoStore == nil else { return }
        store?.errorMessage = "APNs 注册失败：\(error.localizedDescription)。请检查签名与 Push Notifications 能力。"
    }
    fileprivate func receivedWorkspaceChange(revision: Int?) async -> WorkspaceRemoteSyncResult {
        guard let revision, revision >= 0, let store, !store.isDemoMode, store.demoStore == nil, store.shouldAutomaticallySync(remoteRevision: revision), !store.syncing else {
            logger.debug("Ignored workspace revision hint \(revision ?? -1, privacy: .public)")
            return .noData
        }
        do {
            try await store.synchronize()
            logger.notice("Applied workspace revision hint \(revision, privacy: .public)")
            return .newData
        } catch {
            logger.error("Workspace revision hint failed \(revision, privacy: .public)")
            return .failed
        }
    }
}
#if os(macOS)
@MainActor final class NativePlatformDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushBridge.shared.registered(deviceToken)
    }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemotePushBridge.shared.failed(error)
    }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard userInfo["kind"] as? String == "WORKSPACE_SYNC" else { return }
        let revision = (userInfo["revision"] as? NSNumber)?.intValue
        Task { _ = await RemotePushBridge.shared.receivedWorkspaceChange(revision: revision) }
    }
}
#else
@MainActor final class NativePlatformDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushBridge.shared.registered(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemotePushBridge.shared.failed(error)
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard userInfo["kind"] as? String == "WORKSPACE_SYNC" else { completionHandler(.noData); return }
        let revision = (userInfo["revision"] as? NSNumber)?.intValue
        let completion = WorkspaceBackgroundFetchCompletion(completionHandler)
        let work = Task {
            completion.finish(await RemotePushBridge.shared.receivedWorkspaceChange(revision: revision))
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, !completion.isCompleted else { return }
            work.cancel()
            completion.finish(.failed)
        }
    }
}
#endif
