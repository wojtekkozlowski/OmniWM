// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import QuartzCore

@MainActor
class BorderLayerPanel: NSPanel {
    private let tree = BorderLayerTree()
    var borderLayer: CALayer {
        tree.borderLayer
    }

    var glowColorLayer: CAGradientLayer {
        tree.effects.glowColorLayer
    }

    var glowMaskLayer: CALayer {
        tree.effects.glowMaskLayer
    }

    var gradientStrokeLayer: CAGradientLayer {
        tree.effects.gradientStrokeLayer
    }

    var gradientRingMaskLayer: CAShapeLayer {
        tree.effects.gradientRingMaskLayer
    }

    init?(frame: CGRect) {
        guard BorderLayerTree.isAvailable else { return nil }
        super.init(
            contentRect: frame.integral,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isRestorable = false

        let view = NSView(frame: CGRect(origin: .zero, size: frame.integral.size))
        view.wantsLayer = true
        view.layer = tree.containerLayer
        contentView = view
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func constrainFrameRect(_ frameRect: NSRect, to _: NSScreen?) -> NSRect {
        frameRect
    }

    func applyFrame(targetFrame: CGRect, surfaceFrame: CGRect) {
        let panelFrame = surfaceFrame.integral
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != panelFrame {
            setFrame(panelFrame, display: false)
        }
        tree.place(targetFrame: targetFrame, surfaceFrame: surfaceFrame, relativeTo: panelFrame.origin)
        CATransaction.commit()
    }

    func updateBorder(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        color: CGColor,
        scale: CGFloat
    ) {
        tree.updateBorder(geometry: geometry, cornerRadii: cornerRadii, color: color, scale: scale)
    }
}

extension BorderLayerPanel {
    func updateEffects(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        config: BorderConfig,
        baseColor: CGColor,
        scale: CGFloat,
        cornerContour: WindowCornerContour? = nil
    ) {
        tree.updateEffects(
            geometry: geometry,
            cornerRadii: cornerRadii,
            config: config,
            baseColor: baseColor,
            scale: scale,
            cornerContour: cornerContour
        )
    }

    static func cgColor(_ color: SettingsColor) -> CGColor {
        BorderEffectLayers.cgColor(color)
    }
}
