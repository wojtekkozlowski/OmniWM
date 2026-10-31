// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriPreviewLayoutTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let monitor: Monitor
        let area: WorkingAreaContext
    }

    func testPreviewLayoutLeavesStoredFramesAndHiddenStateAlone() throws {
        let fixture = makeFixture()
        let real = layout(fixture, animationTime: 100)
        XCTAssertFalse(real.hiddenHandles.isEmpty, "the fixture needs parked columns")
        let storedWindows = fixture.engine.captureWindowFrames(in: fixture.workspaceId, excluding: [])
        let storedColumns = fixture.engine.columns(in: fixture.workspaceId).map { ($0.frame, $0.renderedFrame) }

        fixture.engine.previewsLayout = true
        fixture.engine.revealsAllColumns = true
        let preview = layout(fixture, animationTime: NiriLayoutHandler.afterAnyMotion, offset: -1000)
        fixture.engine.revealsAllColumns = false
        fixture.engine.previewsLayout = false

        XCTAssertTrue(preview.hiddenHandles.isEmpty, "revealed columns keep their strip positions")
        XCTAssertNotEqual(preview.frames, real.frames)
        XCTAssertEqual(fixture.engine.captureWindowFrames(in: fixture.workspaceId, excluding: []), storedWindows)
        for (column, stored) in zip(fixture.engine.columns(in: fixture.workspaceId), storedColumns) {
            XCTAssertEqual(column.frame, stored.0)
            XCTAssertEqual(column.renderedFrame, stored.1)
        }

        let again = layout(fixture, animationTime: 100)
        XCTAssertEqual(again.frames, real.frames)
        XCTAssertEqual(again.hiddenHandles, real.hiddenHandles)
    }

    private func layout(
        _ fixture: Fixture,
        animationTime: TimeInterval,
        offset: CGFloat = 0
    ) -> (frames: [WindowToken: CGRect], hiddenHandles: [WindowToken: HideSide]) {
        fixture.engine.calculateCombinedLayoutUsingPools(
            in: fixture.workspaceId,
            monitor: fixture.monitor,
            gaps: LayoutGaps(horizontal: 0, vertical: 0),
            state: ViewportState(),
            workingArea: fixture.area,
            animationTime: animationTime,
            viewOffsetOverride: offset
        )
    }

    private func makeFixture() -> Fixture {
        let engine = NiriLayoutEngine()
        let workspaceId = WorkspaceDescriptor.ID()
        for index in 0 ..< 6 {
            _ = engine.addWindow(token: WindowToken(pid: 731, windowId: index + 1), to: workspaceId, afterSelection: nil)
        }
        for column in engine.columns(in: workspaceId) {
            column.cachedWidth = 1000
            column.cachedHeight = 1000
        }
        let frame = CGRect(x: -1000, y: -800, width: 1000, height: 800)
        let monitor = Monitor(
            id: .init(displayId: 992),
            displayId: 992,
            frame: frame,
            visibleFrame: frame,
            hasNotch: false,
            name: "Preview Layout Test"
        )
        _ = engine.ensureMonitor(for: monitor.id, monitor: monitor, orientation: .horizontal)
        let area = WorkingAreaContext(workingFrame: frame, viewFrame: frame, scale: 2)
        return Fixture(engine: engine, workspaceId: workspaceId, monitor: monitor, area: area)
    }
}
