// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum NiriDisplayNeighbors {
    nonisolated(unsafe) static var displayFrames: [CGRect] = []

    static func edges(of workingFrame: CGRect) -> (minimum: Bool, maximum: Bool) {
        var minimum = false
        var maximum = false
        for frame in displayFrames where !frame.contains(CGPoint(x: workingFrame.midX, y: workingFrame.midY)) {
            guard frame.maxY > workingFrame.minY, frame.minY < workingFrame.maxY else { continue }
            if frame.maxX <= workingFrame.minX + 1, frame.maxX >= workingFrame.minX - workingFrame.width {
                minimum = true
            }
            if frame.minX >= workingFrame.maxX - 1, frame.minX <= workingFrame.maxX + workingFrame.width {
                maximum = true
            }
        }
        return (minimum, maximum)
    }
}
