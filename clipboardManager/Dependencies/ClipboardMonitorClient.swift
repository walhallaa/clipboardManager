//
//  ClipboardMonitorClient.swift
//  clipboardManager
//
//  Polls `NSPasteboard.general.changeCount` (there is no push API on macOS).
//  Only the integer is read on each tick; content is copied only on change.
//

import AppKit
import ComposableArchitecture

struct ClipboardMonitorClient: Sendable {
    var changes: @Sendable () -> AsyncStream<PasteboardSnapshot>
}

extension ClipboardMonitorClient: DependencyKey {
    static let liveValue = ClipboardMonitorClient {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let pasteboard = NSPasteboard.general
                var lastChangeCount = pasteboard.changeCount
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(350))
                    let current = pasteboard.changeCount
                    guard current != lastChangeCount else { continue }
                    lastChangeCount = current
                    if let snapshot = PasteboardSnapshot(pasteboard: pasteboard) {
                        // Newest-first insertion downstream keeps a multi-copy in its original order.
                        for item in snapshot.copiedItems.reversed() {
                            continuation.yield(item)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let previewValue = ClipboardMonitorClient { AsyncStream { _ in } }
}

extension DependencyValues {
    var clipboardMonitor: ClipboardMonitorClient {
        get { self[ClipboardMonitorClient.self] }
        set { self[ClipboardMonitorClient.self] = newValue }
    }
}
