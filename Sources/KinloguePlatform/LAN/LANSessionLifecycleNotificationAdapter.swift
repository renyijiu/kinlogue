import AppKit
import Foundation

/// Bridges only documented AppKit/NSWorkspace notifications into the reusable
/// lifecycle contract. It deliberately does not observe private lock or screen
/// saver notification names.
@MainActor
public final class LANSessionLifecycleNotificationAdapter {
    public typealias EventObserver = @Sendable (LANSessionLifecycleEvent) -> Void

    private let monitor: LANSessionLifecycleMonitor
    private let workspaceCenter: NotificationCenter
    private let applicationCenter: NotificationCenter
    private weak var primaryWindow: NSWindow?
    private let eventObserver: EventObserver
    private var observers: [NSObjectProtocol] = []

    public init(
        monitor: LANSessionLifecycleMonitor,
        primaryWindow: NSWindow?,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationCenter: NotificationCenter = .default,
        eventObserver: @escaping EventObserver = { _ in }
    ) {
        self.monitor = monitor
        self.primaryWindow = primaryWindow
        self.workspaceCenter = workspaceCenter
        self.applicationCenter = applicationCenter
        self.eventObserver = eventObserver
    }

    public func start() {
        guard observers.isEmpty else { return }
        observe(
            center: workspaceCenter,
            name: NSWorkspace.willSleepNotification,
            event: .systemWillSleep
        )
        observe(
            center: workspaceCenter,
            name: NSWorkspace.screensDidSleepNotification,
            event: .screenLocked
        )
        observe(
            center: workspaceCenter,
            name: NSWorkspace.sessionDidResignActiveNotification,
            event: .userSessionResigned
        )
        observe(
            center: workspaceCenter,
            name: NSWorkspace.didWakeNotification,
            event: .systemDidWake
        )
        observe(
            center: applicationCenter,
            name: NSApplication.willTerminateNotification,
            event: .applicationWillTerminate
        )
        observe(
            center: applicationCenter,
            name: NSApplication.didResignActiveNotification,
            event: .focusLost
        )
        if let primaryWindow {
            observe(
                center: applicationCenter,
                name: NSWindow.willCloseNotification,
                object: primaryWindow,
                event: .lastPrimaryWindowClosed
            )
        }
    }

    public func stop() {
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            applicationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        object: Any? = nil,
        event: LANSessionLifecycleEvent
    ) {
        let monitor = monitor
        let eventObserver = eventObserver
        observers.append(center.addObserver(
            forName: name,
            object: object,
            queue: .main
        ) { _ in
            eventObserver(event)
            Task { await monitor.handle(event) }
        })
    }
}
