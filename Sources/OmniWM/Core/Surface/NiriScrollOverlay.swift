// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore
import ScreenCaptureKit

// Experiment: draws a Niri viewport scroll from captured window images in one layer tree, so
// every column lands in the same frame however slowly its app answers Accessibility writes.
// The real windows settle behind the panel, which is removed once they have arrived.
@MainActor
final class NiriScrollOverlay {
    struct Item {
        let handle: WindowHandle
        let windowId: Int
        let frame: CGRect
        let presented: CGRect
        let hiddenAtRest: Bool

        var keepsSize: Bool {
            abs(frame.width - presented.width) <= 1 && abs(frame.height - presented.height) <= 1
        }

        var remainingTravel: CGFloat {
            abs(frame.minX - presented.minX)
        }

        // The motion runs from `presented` to `frame`, so this is everywhere the window passes.
        func isSwept(in visible: CGRect) -> Bool {
            frame.union(presented).intersects(visible)
        }
    }

    /// The focused window's border, drawn around its image while the windows move.
    struct FocusBorder: Equatable {
        let handle: WindowHandle
        let config: BorderConfig
        let cornerRadii: WindowCornerRadii
        let cornerContour: WindowCornerContour?
    }

    private static let updateTimeout: TimeInterval = 0.4
    private static let handoffTimeout: TimeInterval = 0.3
    private static let handoffTolerance: CGFloat = 3
    private static let desktopRefreshInterval: TimeInterval = 30
    private static let clipOpeningDistance: CGFloat = 200
    private static let previewRefreshInterval: TimeInterval = 20
    private static let maximumShapeMismatch: CGFloat = 2

    private let ownedWindowRegistry: OwnedWindowRegistry
    private let capture: OverviewThumbnailCapture
    private let backdrop: WorkspaceSwipeBackdrop
    private let hasCaptureAccess: @MainActor () -> Bool
    private let windowBounds: @MainActor (UInt32) -> CGRect?
    private var panel: WorkspaceSwipePreviewPanel?
    private var panelFrame: CGRect = .zero
    private var layers: [WindowHandle: CALayer] = [:]
    private var openContainer: CALayer?
    private var clippedContainer: CALayer?
    private var clipMask: CALayer?
    private var focusBorder: BorderLayerTree?
    private var drawnFocusBorder: FocusBorder?
    private var drawnFocusBorderSize: CGSize = .zero
    private var lastPresentedAt: TimeInterval = 0
    private var watchdog: Task<Void, Never>?
    private var handoff: Task<Void, Never>?
    private var previewRequestedAt: [WindowHandle: TimeInterval] = [:]
    private var capturedImages: [WindowHandle: CGImage] = [:]
    private let captureWindow: @MainActor (UInt32) -> CGImage?
    private var desktopImage: CGImage?
    private var desktopCapturedAt: TimeInterval = -.infinity
    private var desktopCapture: Task<Void, Never>?

    var isVisible: Bool {
        panel != nil
    }

    init(
        ownedWindowRegistry: OwnedWindowRegistry,
        previewCapture: OverviewThumbnailCapture? = nil,
        backdrop: WorkspaceSwipeBackdrop = WorkspaceSwipeBackdrop(),
        hasCaptureAccess: @escaping @MainActor () -> Bool = { ScreenCapturePermissionMonitor.shared.isGranted },
        windowBounds: @escaping @MainActor (UInt32) -> CGRect? = { SkyLight.shared.getWindowBounds($0) },
        captureWindow: @escaping @MainActor (UInt32) -> CGImage? = { SkyLight.shared.captureOnScreenWindow($0) }
    ) {
        self.captureWindow = captureWindow
        self.ownedWindowRegistry = ownedWindowRegistry
        self.backdrop = backdrop
        self.hasCaptureAccess = hasCaptureAccess
        self.windowBounds = windowBounds
        capture = previewCapture ?? OverviewThumbnailCapture(
            consumer: .workspaceSwipe,
            hasCaptureAccess: hasCaptureAccess,
            adoptsProvisionalPreviews: false,
            maximumRetainedBytes: 512 * 1_024 * 1_024
        )
        capture.onPreview = { [weak self] handle, frame in
            self?.updatePreview(frame, for: handle)
        }
    }

    isolated deinit {
        stop()
    }

    // A window can change shape after its capture, for example by moving to a display with
    // another resolution, and stretching that image to the new frame would visibly squash it.
    static func imageFits(imageSize: CGSize, frame: CGRect) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else { return false }
        let aspect = imageSize.width / imageSize.height
        return abs(frame.height * aspect - frame.width) <= maximumShapeMismatch
            && abs(frame.width / aspect - frame.height) <= maximumShapeMismatch
    }

    private func image(for item: Item) -> (contents: Any, contentsRect: CGRect)? {
        if let captured = capturedImages[item.handle],
           Self.imageFits(imageSize: CGSize(width: captured.width, height: captured.height), frame: item.frame)
        {
            return (captured, CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        guard let preview = capture.preview(for: item.handle) else { return nil }
        let imageSize = CGSize(
            width: CGFloat(preview.surface.width) * preview.contentsRect.width,
            height: CGFloat(preview.surface.height) * preview.contentsRect.height
        )
        return Self.imageFits(imageSize: imageSize, frame: item.frame) ? (preview.surface, preview.contentsRect) : nil
    }

    // A window fully on screen can show anything by now, so it is captured as the motion
    // starts. Keeping the image means it still looks current if it returns after parking.
    private func captureOnScreenWindows(_ items: [Item], in visible: CGRect) {
        for item in items where visible.contains(item.presented) {
            if let captured = captureWindow(UInt32(item.windowId)),
               Self.imageFits(imageSize: CGSize(width: captured.width, height: captured.height), frame: item.frame)
            {
                capturedImages[item.handle] = captured
            }
        }
    }

    // Columns the settled layout hides would otherwise peek into the screen edges until the
    // handoff. Their clip opens towards where they finish over the end of the scroll, so they
    // slide to the real screen edge and the last frame still matches the real desktop.
    static func clipRect(for items: [Item], in visible: CGRect, offset: CGFloat) -> CGRect {
        let inset = max(0, 1 - abs(offset) / clipOpeningDistance)
        var minX = visible.minX
        var maxX = visible.maxX
        for item in items where item.hiddenAtRest && item.frame.intersects(visible) {
            if item.frame.midX < visible.midX {
                minX = max(minX, visible.minX + (item.frame.maxX - visible.minX) * inset)
            } else {
                maxX = min(maxX, visible.maxX - (visible.maxX - item.frame.minX) * inset)
            }
        }
        return CGRect(x: minX, y: visible.minY, width: max(0, maxX - minX), height: visible.height)
    }

    func warm(_ items: [Item], monitor: Monitor) {
        guard panel == nil, hasCaptureAccess() else { return }
        refreshDesktop(monitor: monitor)
        // macOS badges every window while it is captured, so scrolls use existing images and
        // they are only refreshed occasionally between scrolls.
        let now = CACurrentMediaTime()
        let visible = monitor.visibleFrame
        let due = items.filter {
            !visible.contains($0.presented) && (
                image(for: $0) == nil
                    || (capturedImages[$0.handle] == nil
                        && now - (previewRequestedAt[$0.handle] ?? -.infinity) >= Self.previewRefreshInterval)
            )
        }
        for item in due {
            previewRequestedAt[item.handle] = now
        }
        request(due, monitor: monitor, firstFrameOnly: true)
    }

    func remove(token: WindowToken) {
        previewRequestedAt = previewRequestedAt.filter { $0.key.token != token }
        capturedImages = capturedImages.filter { $0.key.token != token }
        capture.remove(token: token)
    }

    func present(_ items: [Item], monitor: Monitor, focus: FocusBorder? = nil) -> Bool {
        let visible = monitor.visibleFrame
        let swept = items.filter { $0.isSwept(in: visible) }
        if panel == nil {
            guard hasCaptureAccess(), let backdropImage = desktopImage ?? backdrop.image(for: monitor) else {
                return false
            }
            let parked = swept.filter { !visible.contains($0.presented) }
            guard parked.allSatisfy({ image(for: $0) != nil }) else {
                request(parked.filter { image(for: $0) == nil }, monitor: monitor, firstFrameOnly: true)
                return false
            }
            captureOnScreenWindows(swept, in: visible)
            guard swept.allSatisfy({ image(for: $0) != nil }) else { return false }
            show(backdropImage: backdropImage, monitor: monitor)
        } else if !swept.allSatisfy({ image(for: $0) != nil }) {
            return false
        }
        handoff?.cancel()
        handoff = nil
        lastPresentedAt = CACurrentMediaTime()
        let travel = items.map(\.remainingTravel).max() ?? 0
        place(
            swept, keeping: items, atFinalFrames: false,
            clip: Self.clipRect(for: items, in: visible, offset: travel), focus: focus
        )
        return true
    }

    func finish(settling items: [Item], focus: FocusBorder? = nil) {
        guard panel != nil else { return }
        watchdog?.cancel()
        watchdog = nil
        let expected = items.filter { $0.frame.intersects(panelFrame) }
        guard expected.allSatisfy({ image(for: $0) != nil }) else {
            stop()
            return
        }
        place(
            expected, keeping: items, atFinalFrames: true,
            clip: Self.clipRect(for: items, in: panelFrame, offset: 0), focus: focus
        )
        handoff?.cancel()
        handoff = Task { [weak self] in
            let deadline = CACurrentMediaTime() + Self.handoffTimeout
            while !Task.isCancelled, CACurrentMediaTime() < deadline {
                guard let self, !arrived(expected) else { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        handoff?.cancel()
        handoff = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let panel {
            ownedWindowRegistry.unregister(panel)
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        layers.removeAll()
        openContainer = nil
        clippedContainer = nil
        clipMask = nil
        focusBorder = nil
        drawnFocusBorder = nil
        drawnFocusBorderSize = .zero
        CATransaction.commit()
    }

    func release() {
        stop()
        capture.clear()
        desktopCapture?.cancel()
        desktopCapture = nil
        desktopImage = nil
        backdrop.clear()
        capture.releaseCache(reason: .shutdown)
    }

    private func refreshDesktop(monitor: Monitor) {
        guard desktopCapture == nil,
              CACurrentMediaTime() - desktopCapturedAt >= Self.desktopRefreshInterval
        else { return }
        desktopCapture = Task { [weak self] in
            let image = await Self.captureDesktop(monitor: monitor)
            guard let self else { return }
            desktopCapture = nil
            desktopCapturedAt = CACurrentMediaTime()
            if let image {
                desktopImage = image
            }
        }
    }

    // The desktop layers include widgets and the darkening macOS draws under the menu bar,
    // neither of which is in the wallpaper window's own image.
    private static func captureDesktop(monitor: Monitor) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == monitor.displayId }) else {
                return nil
            }
            let scale = Self.scale(for: monitor)
            let config = SCStreamConfiguration()
            config.width = Int(ceil(monitor.frame.width * scale))
            config.height = Int(ceil(monitor.frame.height * scale))
            config.showsCursor = false
            config.capturesAudio = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(
                    display: display,
                    including: content.windows.filter { $0.windowLayer < 0 }
                ),
                configuration: config
            )
        } catch {
            ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
            return nil
        }
    }

    private func arrived(_ items: [Item]) -> Bool {
        items.allSatisfy { item in
            guard let bounds = windowBounds(UInt32(item.windowId)) else { return true }
            let target = ScreenCoordinateSpace.toWindowServer(rect: item.frame)
            return abs(bounds.minX - target.minX) <= Self.handoffTolerance
                && abs(bounds.minY - target.minY) <= Self.handoffTolerance
        }
    }

    private func request(_ items: [Item], monitor: Monitor, firstFrameOnly: Bool) {
        let scale = Self.scale(for: monitor)
        capture.reconcile(
            represented: Set(items.map(\.handle)),
            visible: items.map {
                OverviewPreviewRequest(
                    handle: $0.handle,
                    pixelWidth: Int(ceil($0.frame.width * scale)),
                    pixelHeight: Int(ceil($0.frame.height * scale))
                )
            },
            retainingUnrepresentedPreviews: true,
            firstFrameOnly: firstFrameOnly
        )
    }

    private func show(backdropImage: CGImage, monitor: Monitor) {
        let requested = monitor.visibleFrame
        let panel = WorkspaceSwipePreviewPanel(frame: requested)
        // Above managed windows but under the Dock, menu bar and workspace bar, which can sit
        // inside this frame on a secondary display.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        // Everything is placed relative to where the panel really is, so a frame AppKit adjusted
        // would still show the images over the windows they stand for.
        let frame = panel.frame
        if frame != requested {
            FallbackFiringRecorder.shared.note(.monitor, "niriScrollOverlayPanelFrameAdjusted")
        }
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: frame.size)
        root.masksToBounds = true
        let view = NSView(frame: root.frame)
        view.wantsLayer = true
        view.layer = root
        panel.contentView = view

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let backdropLayer = CALayer()
        backdropLayer.frame = monitor.frame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.contents = backdropImage
        root.addSublayer(backdropLayer)
        let open = CALayer()
        open.frame = root.bounds
        let clipped = CALayer()
        clipped.frame = root.bounds
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = root.bounds
        clipped.mask = mask
        root.addSublayer(clipped)
        root.addSublayer(open)
        openContainer = open
        clippedContainer = clipped
        clipMask = mask
        CATransaction.commit()

        self.panel = panel
        panelFrame = frame
        ownedWindowRegistry.register(
            panel,
            surfaceId: "niri-scroll-overlay-\(monitor.displayId)",
            policy: SurfacePolicy(
                kind: .workspaceSwipe,
                hitTestPolicy: .passthrough,
                capturePolicy: .included,
                suppressesManagedFocusRecovery: false
            )
        )
        panel.orderFrontRegardless()
        startWatchdog()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                if CACurrentMediaTime() - lastPresentedAt > Self.updateTimeout {
                    stop()
                    return
                }
            }
        }
    }

    private func place(
        _ items: [Item], keeping known: [Item], atFinalFrames: Bool, clip: CGRect, focus: FocusBorder?
    ) {
        guard let root = panel?.contentView?.layer, let openContainer, let clippedContainer else { return }
        let scale = root.contentsScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask?.frame = clip.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        let knownHandles = Set(known.map(\.handle))
        for (handle, layer) in layers where !knownHandles.contains(handle) {
            layer.removeFromSuperlayer()
            layers.removeValue(forKey: handle)
        }
        for item in items {
            let layer: CALayer
            if let existing = layers[item.handle] {
                layer = existing
            } else {
                guard let image = image(for: item) else { continue }
                layer = CALayer()
                layer.contentsGravity = .resize
                layer.contentsScale = scale
                layer.contents = image.contents
                layer.contentsRect = image.contentsRect
                layers[item.handle] = layer
            }
            let container = item.hiddenAtRest ? clippedContainer : openContainer
            if layer.superlayer !== container {
                container.addSublayer(layer)
            }
            layer.frame = (atFinalFrames ? item.frame : item.presented)
                .offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY)
        }
        placeFocusBorder(focus, scale: scale)
        CATransaction.commit()
    }

    // The real border is a panel ordered just under the focused window, so this panel covers it
    // while the images move, and it only reappears once the windows have arrived. Drawing the
    // border around the focused image keeps it in view through the whole motion.
    private func placeFocusBorder(_ focus: FocusBorder?, scale: CGFloat) {
        guard let focus, let layer = layers[focus.handle], let container = layer.superlayer else {
            focusBorder?.containerLayer.removeFromSuperlayer()
            drawnFocusBorder = nil
            return
        }
        let tree: BorderLayerTree
        if let focusBorder {
            tree = focusBorder
        } else {
            guard BorderLayerTree.isAvailable else { return }
            tree = BorderLayerTree()
            tree.containerLayer.zPosition = 1
            focusBorder = tree
        }
        if tree.containerLayer.superlayer !== container {
            container.addSublayer(tree.containerLayer)
        }
        let geometry = focus.config.resolvedGeometry(for: layer.frame, scale: scale)
        let local = geometry.localized()
        tree.containerLayer.frame = geometry.surfaceFrame
        tree.place(targetFrame: local.targetFrame, surfaceFrame: local.surfaceFrame, relativeTo: .zero)
        guard drawnFocusBorder != focus || drawnFocusBorderSize != geometry.surfaceFrame.size else { return }
        let color = BorderEffectLayers.cgColor(focus.config.color)
        tree.updateBorder(geometry: local, cornerRadii: focus.cornerRadii, color: color, scale: scale)
        tree.updateEffects(
            geometry: local, cornerRadii: focus.cornerRadii, config: focus.config,
            baseColor: color, scale: scale, cornerContour: focus.cornerContour
        )
        drawnFocusBorder = focus
        drawnFocusBorderSize = geometry.surfaceFrame.size
    }

    private func updatePreview(_ frame: OverviewPreviewFrame?, for handle: WindowHandle) {
        guard let frame, capturedImages[handle] == nil, let layer = layers[handle] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = frame.surface
        layer.contentsRect = frame.contentsRect
        CATransaction.commit()
    }

    private static func scale(for monitor: Monitor) -> CGFloat {
        NSScreen.screens.first(where: { $0.displayId == monitor.displayId })?.backingScaleFactor ?? 1
    }
}
