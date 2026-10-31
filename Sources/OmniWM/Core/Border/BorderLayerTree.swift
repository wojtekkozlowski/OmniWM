// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMLayerCorners
import QuartzCore

/// The layers that draw a border: a rim layer for the plain border and the effect layers for
/// gradients, glows and sampled corner contours. The border panel is built from one, and the
/// scroll overlay draws one around the focused window's image while the windows move.
@MainActor
final class BorderLayerTree {
    let containerLayer = CALayer()
    let borderLayer = CALayer()
    let effects = BorderEffectLayers()

    static var isAvailable: Bool {
        omniwm_layer_border_available()
    }

    init() {
        borderLayer.cornerCurve = .continuous
        borderLayer.rimOpacity = 1
        borderLayer.actions = [
            "rimWidth": NSNull(), "rimColor": NSNull(), "rimOpacity": NSNull(), "cornerRadii": NSNull(),
            "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()
        ]
        containerLayer.actions = ["hidden": NSNull()]
        containerLayer.addSublayer(effects.root)
        containerLayer.addSublayer(borderLayer)
    }

    /// Places the rim around `targetFrame` and the effects over `surfaceFrame`, both given in
    /// the coordinate space whose origin is `origin`.
    func place(targetFrame: CGRect, surfaceFrame: CGRect, relativeTo origin: CGPoint) {
        let layerFrame = targetFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        let effectsFrame = surfaceFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        if borderLayer.frame != layerFrame {
            borderLayer.frame = layerFrame
        }
        if effects.root.frame != effectsFrame {
            effects.root.frame = effectsFrame
        }
    }

    func updateBorder(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        color: CGColor,
        scale: CGFloat
    ) {
        let radii = cornerRadii.normalized(to: geometry.targetFrame.size)
        let nativeRadii = CACornerRadii(
            topLeft: CGSize(width: radii.topLeft, height: radii.topLeft),
            topRight: CGSize(width: radii.topRight, height: radii.topRight),
            bottomRight: CGSize(width: radii.bottomRight, height: radii.bottomRight),
            bottomLeft: CGSize(width: radii.bottomLeft, height: radii.bottomLeft)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if containerLayer.contentsScale != scale { containerLayer.contentsScale = scale }
        if borderLayer.contentsScale != scale { borderLayer.contentsScale = scale }
        if borderLayer.rimWidth != geometry.width { borderLayer.rimWidth = geometry.width }
        if borderLayer.rimColor != color { borderLayer.rimColor = color }
        let currentRadii = borderLayer.cornerRadii
        if currentRadii.topLeft != nativeRadii.topLeft || currentRadii.topRight != nativeRadii.topRight
            || currentRadii.bottomRight != nativeRadii.bottomRight || currentRadii.bottomLeft != nativeRadii.bottomLeft
        {
            borderLayer.cornerRadii = nativeRadii
        }
        CATransaction.commit()
    }

    func updateEffects(
        geometry: BorderConfig.ResolvedGeometry,
        cornerRadii: WindowCornerRadii,
        config: BorderConfig,
        baseColor: CGColor,
        scale: CGFloat,
        cornerContour: WindowCornerContour? = nil
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effects.updateEffects(
            geometry: geometry,
            cornerRadii: cornerRadii,
            config: config,
            baseColor: baseColor,
            scale: scale,
            cornerContour: cornerContour
        )
        borderLayer.rimOpacity = config.gradient?.enabled == true || cornerContour != nil ? 0 : 1
        CATransaction.commit()
    }
}
