// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

struct AppAXEnhancedUITiming {
    let probeNs: UInt64
    let disableNs: UInt64
    let restoreNs: UInt64
}

struct AppAXEnhancedUIWriteScope {
    private let axApp: AXUIElement
    private let key: CFString
    private let tracing: Bool
    let wasEnabled: Bool
    private let probeNs: UInt64
    private let disableNs: UInt64

    init(axApp: AXUIElement, pid: pid_t, tracing: Bool) {
        self.axApp = axApp
        self.tracing = tracing
        key = "AXEnhancedUserInterface" as CFString
        var enabled = false
        var value: CFTypeRef?
        let probeStartNs = tracing ? DispatchTime.now().uptimeNanoseconds : 0
        if let cached = LockedEnhancedUIStateMap.shared.state(for: pid) {
            enabled = cached
        } else {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            if AXUIElementCopyAttributeValue(axApp, key, &value) == .success,
               let boolValue = value as? Bool
            {
                enabled = boolValue
                LockedEnhancedUIStateMap.shared.store(boolValue, for: pid)
            }
        }
        let probeEndNs = tracing ? DispatchTime.now().uptimeNanoseconds : 0
        wasEnabled = enabled
        let disableStartNs = tracing && enabled ? DispatchTime.now().uptimeNanoseconds : 0
        if enabled {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            AXUIElementSetAttributeValue(axApp, key, kCFBooleanFalse)
        }
        let disableEndNs = tracing && enabled ? DispatchTime.now().uptimeNanoseconds : 0
        probeNs = AppAXFrameWriteTrace.elapsedNanoseconds(from: probeStartNs, to: probeEndNs)
        disableNs = AppAXFrameWriteTrace.elapsedNanoseconds(from: disableStartNs, to: disableEndNs)
    }

    var openingTiming: AppAXEnhancedUITiming {
        AppAXEnhancedUITiming(probeNs: probeNs, disableNs: disableNs, restoreNs: 0)
    }

    func restore() -> AppAXEnhancedUITiming {
        let restoreStartNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        if wasEnabled {
            AppAXContextRuntimeMetrics.shared.noteEnhancedUICalls(1)
            AXUIElementSetAttributeValue(axApp, key, kCFBooleanTrue)
        }
        let restoreEndNs = tracing && wasEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        return AppAXEnhancedUITiming(
            probeNs: probeNs,
            disableNs: disableNs,
            restoreNs: AppAXFrameWriteTrace.elapsedNanoseconds(from: restoreStartNs, to: restoreEndNs)
        )
    }
}

// Keeps Enhanced UI off across consecutive drains so a motion toggles it once rather than
// around every write. Only the app's AX thread touches this, and that thread's run loop
// delivers the restore once drains stop arriving.
final class AppAXEnhancedUIHold: @unchecked Sendable {
    static let idleInterval: TimeInterval = 0.12

    private var scope: AppAXEnhancedUIWriteScope?
    private var restoreTimer: Timer?

    func acquire(axApp: AXUIElement, pid: pid_t, tracing: Bool) -> (wasEnabled: Bool, timing: AppAXEnhancedUITiming) {
        restoreTimer?.invalidate()
        restoreTimer = nil
        if let scope {
            return (scope.wasEnabled, AppAXEnhancedUITiming(probeNs: 0, disableNs: 0, restoreNs: 0))
        }
        let opened = AppAXEnhancedUIWriteScope(axApp: axApp, pid: pid, tracing: tracing)
        if opened.wasEnabled {
            scope = opened
        }
        return (opened.wasEnabled, opened.openingTiming)
    }

    func scheduleRestore() {
        guard scope != nil else { return }
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: Self.idleInterval, repeats: false) { [weak self] _ in
            self?.restoreNow()
        }
    }

    func restoreNow() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        guard let scope else { return }
        self.scope = nil
        _ = scope.restore()
    }
}
