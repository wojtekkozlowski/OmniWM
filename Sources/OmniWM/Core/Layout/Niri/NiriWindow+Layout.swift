// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension NiriWindow {
    func applyLayout(
        _ layout: NiriWindowLayout,
        storesLayout: Bool = true,
        sizingMode: SizingMode,
        within geometry: NiriContainerLayoutFrames,
        at time: TimeInterval
    ) -> CGRect {
        switch sizingMode {
        case .fullscreen,
             .maximized:
            applyUnanimatedLayout(layout, within: geometry, storesLayout: storesLayout)
        case .normal:
            applyAnimatedLayout(layout, within: geometry, at: time, storesLayout: storesLayout)
        }
    }

    private func applyUnanimatedLayout(
        _ layout: NiriWindowLayout,
        within geometry: NiriContainerLayoutFrames,
        storesLayout: Bool
    ) -> CGRect {
        if storesLayout { applyResolvedLayout(layout, orientation: geometry.orientation) }
        return applyRenderedFrame(layout.renderedBaseFrame, within: geometry, storesLayout: storesLayout)
    }

    private func applyAnimatedLayout(
        _ layout: NiriWindowLayout,
        within geometry: NiriContainerLayoutFrames,
        at time: TimeInterval,
        storesLayout: Bool
    ) -> CGRect {
        if storesLayout { applyResolvedLayout(layout, orientation: geometry.orientation) }
        let frame = animatedFrame(
            from: layout.renderedBaseFrame,
            within: geometry.renderedRect,
            at: time,
            orientation: geometry.orientation
        )
        return applyRenderedFrame(frame, within: geometry, storesLayout: storesLayout)
    }

    private func applyResolvedLayout(_ layout: NiriWindowLayout, orientation: Monitor.Orientation) {
        frame = layout.frame
        switch orientation {
        case .horizontal:
            resolvedHeight = layout.resolvedSpan
        case .vertical:
            resolvedWidth = layout.resolvedSpan
        }
    }

    private func applyRenderedFrame(
        _ frame: CGRect,
        within geometry: NiriContainerLayoutFrames,
        storesLayout: Bool
    ) -> CGRect {
        let clampedFrame = NiriMonitorPlaneGeometry.clampedFrame(
            frame,
            screenClampRect: geometry.viewFrame,
            orientation: geometry.orientation
        )
        let roundedFrame = clampedFrame.roundedToPhysicalPixels(scale: geometry.scale)
        if storesLayout { renderedFrame = roundedFrame }
        return roundedFrame
    }

    private func animatedFrame(
        from renderedBaseFrame: CGRect,
        within containerRect: CGRect,
        at time: TimeInterval,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let windowOffset = renderOffset(at: time)
        var offsetFrame = renderedBaseFrame.offsetBy(dx: windowOffset.x, dy: windowOffset.y)
        switch orientation {
        case .horizontal:
            let minY = containerRect.minY
            let maxY = containerRect.maxY - offsetFrame.height
            if maxY >= minY {
                offsetFrame.origin.y = min(max(offsetFrame.origin.y, minY), maxY)
            }
        case .vertical:
            let minX = containerRect.minX
            let maxX = containerRect.maxX - offsetFrame.width
            if maxX >= minX {
                offsetFrame.origin.x = min(max(offsetFrame.origin.x, minX), maxX)
            }
            if let containmentFrame = moveYContainmentFrame,
               renderedBaseFrame.minY >= containmentFrame.minY,
               renderedBaseFrame.maxY <= containmentFrame.maxY
            {
                let minY = containmentFrame.minY
                let maxY = containmentFrame.maxY - offsetFrame.height
                if maxY >= minY {
                    offsetFrame.origin.y = min(max(offsetFrame.origin.y, minY), maxY)
                }
            }
        }
        return offsetFrame
    }
}
