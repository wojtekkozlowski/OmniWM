// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class AnimationDriverTests: XCTestCase {
    private let workspaceId = WorkspaceDescriptor.ID()

    private func state(viewOffset: CGFloat) -> ViewportState {
        var state = ViewportState()
        state.viewOffset = viewOffset
        return state
    }

    private func commit(
        _ driver: AnimationDriver,
        previous: CGFloat?,
        mutate: (inout ViewportState) -> Void
    ) -> ViewportState {
        var next = state(viewOffset: previous ?? 0)
        mutate(&next)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: previous.map(state(viewOffset:)),
            next: next,
            transition: next.offsetTransition
        )
        return next
    }

    func testScrollOverlaySweepsWindowsThatEnterDuringTheScroll() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let entering = CGRect(x: 1200, y: 0, width: 500, height: 800)
        XCTAssertTrue(NiriScrollOverlay.isSwept(entering, offset: -300, in: visible))
        XCTAssertFalse(NiriScrollOverlay.isSwept(entering, offset: 100, in: visible))
        XCTAssertEqual(
            NiriScrollOverlay.presentedFrame(entering, offset: -300),
            CGRect(x: 900, y: 0, width: 500, height: 800)
        )
    }

    func testSpringHoldsItsStartUntilTheFirstDisplayTick() throws {
        let driver = AnimationDriver()
        var next = state(viewOffset: 0)
        next.springOffset(to: 900)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: state(viewOffset: 0),
            next: next,
            transition: next.offsetTransition,
            at: 100
        )
        func offset(at time: TimeInterval) throws -> CGFloat {
            try XCTUnwrap(driver.renderOffsets(in: workspaceId, semanticOffset: 900, at: time).liveOffset)
        }

        XCTAssertEqual(try offset(at: 100.065), 0, accuracy: 0.001)

        let firstTick = 100.07
        XCTAssertEqual(driver.tickResult(in: workspaceId, at: firstTick), .running)
        XCTAssertEqual(try offset(at: firstTick), 0, accuracy: 0.001)

        let secondTick = firstTick + 1.0 / 120.0
        XCTAssertEqual(driver.tickResult(in: workspaceId, at: secondTick), .running)
        let second = try offset(at: secondTick)
        XCTAssertGreaterThan(second, 0)
        XCTAssertLessThan(second, 45)
    }

    func testSpringNeverReadsBehindItsLatestDisplayTick() throws {
        let driver = AnimationDriver()
        var next = state(viewOffset: 0)
        next.springOffset(to: 900)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: state(viewOffset: 0),
            next: next,
            transition: next.offsetTransition,
            at: 100
        )
        _ = driver.tickResult(in: workspaceId, at: 100)
        _ = driver.tickResult(in: workspaceId, at: 100.05)
        let ticked = try XCTUnwrap(driver.renderOffsets(in: workspaceId, semanticOffset: 900, at: 100.05).liveOffset)

        let between = try XCTUnwrap(driver.renderOffsets(in: workspaceId, semanticOffset: 900, at: 100.04).liveOffset)

        XCTAssertEqual(between, ticked, accuracy: 0.001)
    }

    func testScrollOverlayClipsColumnsHiddenAtRestWhereTheyFinish() {
        func item(_ windowId: Int, _ frame: CGRect, hiddenAtRest: Bool) -> NiriScrollOverlay.Item {
            NiriScrollOverlay.Item(
                handle: WindowHandle(id: WindowToken(pid: 1, windowId: windowId)),
                windowId: windowId,
                frame: frame,
                hiddenAtRest: hiddenAtRest
            )
        }
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let items = [
            item(1, CGRect(x: -800, y: 0, width: 808, height: 800), hiddenAtRest: true),
            item(2, CGRect(x: 20, y: 0, width: 960, height: 800), hiddenAtRest: false),
            item(3, CGRect(x: 992, y: 0, width: 800, height: 800), hiddenAtRest: true),
            item(4, CGRect(x: 2000, y: 0, width: 800, height: 800), hiddenAtRest: true)
        ]

        XCTAssertEqual(
            NiriScrollOverlay.clipRect(for: items, in: visible, offset: 0),
            CGRect(x: 8, y: 0, width: 984, height: 800)
        )
        XCTAssertEqual(
            NiriScrollOverlay.clipRect(for: items, in: visible, offset: 100),
            CGRect(x: 4, y: 0, width: 992, height: 800)
        )
        XCTAssertEqual(NiriScrollOverlay.clipRect(for: items, in: visible, offset: -500), visible)
    }

    func testHeldSpringStaysAtItsStartUntilTheHoldEnds() throws {
        let driver = AnimationDriver()
        var next = state(viewOffset: 0)
        next.springOffset(to: 900)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: state(viewOffset: 0),
            next: next,
            transition: next.offsetTransition,
            at: 100
        )
        _ = driver.tickResult(in: workspaceId, at: 100)
        driver.holdMotionStart(in: workspaceId, until: 100.05)

        let held = try XCTUnwrap(driver.renderOffsets(in: workspaceId, semanticOffset: 900, at: 100.04).liveOffset)
        let moving = try XCTUnwrap(driver.renderOffsets(in: workspaceId, semanticOffset: 900, at: 100.06).liveOffset)

        XCTAssertEqual(held, 0, accuracy: 0.001)
        XCTAssertGreaterThan(moving, 0)
    }

    func testSpringResumesWhenNoDisplayTickArrives() throws {
        let driver = AnimationDriver()
        var next = state(viewOffset: 0)
        next.springOffset(to: 900)
        driver.reconcileViewportCommit(
            workspaceId: workspaceId,
            previous: state(viewOffset: 0),
            next: next,
            transition: next.offsetTransition,
            at: 100
        )

        let offset = try XCTUnwrap(driver.renderOffsets(in: workspaceId, semanticOffset: 900, at: 105).liveOffset)

        XCTAssertEqual(offset, 900, accuracy: 0.001)
    }

    func testOffsetMutatorsAccumulateRebaseAndLastKindWins() {
        var state = state(viewOffset: 10)

        state.rebaseOffset(by: 5)
        XCTAssertEqual(state.viewOffset, 15)
        XCTAssertEqual(state.offsetTransition.rebaseDelta, 5)
        XCTAssertNil(state.offsetTransition.kind)

        state.springOffset(to: 100)
        XCTAssertEqual(state.viewOffset, 100)
        XCTAssertTrue(state.hasPendingOffsetAnimation)

        state.rebaseOffset(by: -3)
        XCTAssertEqual(state.viewOffset, 97)
        XCTAssertEqual(state.offsetTransition.rebaseDelta, 2)
        XCTAssertTrue(state.hasPendingOffsetAnimation)

        state.jumpOffset(to: 40)
        XCTAssertEqual(state.offsetTransition.kind, .jump)
        XCTAssertFalse(state.hasPendingOffsetAnimation)

        state.clearOffsetTransition()
        XCTAssertEqual(state.offsetTransition, OffsetTransition())
    }

    func testJumpCommitClearsMotion() {
        let driver = AnimationDriver()
        _ = commit(driver, previous: 0) { $0.springOffset(to: 200) }
        XCTAssertTrue(driver.hasMotion(in: workspaceId))

        _ = commit(driver, previous: 200) { $0.jumpOffset(to: 50) }
        XCTAssertFalse(driver.hasMotion(in: workspaceId))
    }

    func testSpringCommitFromIdleStartsAtPreviousSemanticOffset() {
        let driver = AnimationDriver()
        _ = commit(driver, previous: 10) { $0.springOffset(to: 110) }

        let live = driver.liveViewOffset(in: workspaceId, semanticOffset: 110, at: CACurrentMediaTime())!
        XCTAssertEqual(live, 10, accuracy: 1.0)
    }

    func testRebaseCommitShiftsLiveSpring() {
        let driver = AnimationDriver()
        _ = commit(driver, previous: 0) { $0.springOffset(to: 100) }
        let time = CACurrentMediaTime()
        let before = driver.liveViewOffset(in: workspaceId, semanticOffset: 100, at: time)!

        _ = commit(driver, previous: 100) { $0.rebaseOffset(by: 30) }
        let after = driver.liveViewOffset(in: workspaceId, semanticOffset: 130, at: time)!
        XCTAssertEqual(after - before, 30, accuracy: 0.001)
        XCTAssertTrue(driver.hasMotion(in: workspaceId))
    }

    func testSpringCommitRetargetsLiveSpringContinuously() {
        let driver = AnimationDriver()
        _ = commit(driver, previous: 0) { $0.springOffset(to: 100) }
        let liveBefore = driver.liveViewOffset(in: workspaceId, semanticOffset: 100)!

        _ = commit(driver, previous: 100) { $0.springOffset(to: 300) }
        let liveAfter = driver.liveViewOffset(in: workspaceId, semanticOffset: 300)!
        XCTAssertEqual(liveAfter, liveBefore, accuracy: 1.0)
        XCTAssertTrue(driver.hasMotion(in: workspaceId))
    }

    func testGestureRidesSemanticRebaseAndSurvivesPlainCommits() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true)
        driver.updateGesture(
            in: workspaceId,
            delta: 60,
            timestamp: 1.0,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        XCTAssertEqual(driver.liveViewOffset(in: workspaceId, semanticOffset: 0)!, 60, accuracy: 0.001)

        _ = commit(driver, previous: 0) { $0.rebaseOffset(by: -20) }
        XCTAssertTrue(driver.hasGesture(in: workspaceId))
        XCTAssertEqual(driver.liveViewOffset(in: workspaceId, semanticOffset: -20)!, 40, accuracy: 0.001)
    }

    func testSpringCommitConvertsGestureWithPositionContinuity() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true)
        driver.updateGesture(
            in: workspaceId,
            delta: 60,
            timestamp: 1.0,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        let sample = driver.sampleGestureEnd(
            in: workspaceId,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement,
            timestamp: 1.1
        )
        XCTAssertEqual(sample!.relativeOffset, 60, accuracy: 0.001)
        XCTAssertTrue(driver.hasGesture(in: workspaceId))

        _ = commit(driver, previous: 0) { state in
            state.rebaseOffset(by: -10)
            state.springOffset(to: 120)
        }
        XCTAssertTrue(driver.hasMotion(in: workspaceId))
        XCTAssertFalse(driver.hasGesture(in: workspaceId))
        let live = driver.liveViewOffset(in: workspaceId, semanticOffset: 110)!
        XCTAssertEqual(live, 50, accuracy: 1.0)
    }

    func testGestureEndAfterStillTailProjectsCurrentOffset() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true)
        driver.updateGesture(
            in: workspaceId,
            delta: 120,
            timestamp: 1.00,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        driver.updateGesture(
            in: workspaceId,
            delta: 0,
            timestamp: 1.04,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )

        let sample = driver.sampleGestureEnd(
            in: workspaceId,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement,
            timestamp: 1.09
        )!

        XCTAssertEqual(sample.relativeOffset, 120, accuracy: 0.001)
        XCTAssertEqual(sample.relativeProjectedOffset, sample.relativeOffset, accuracy: 0.001)
    }

    func testBelowFloorGestureEndCommitsCompletedDeceleration() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true)
        driver.updateGesture(
            in: workspaceId,
            delta: 4,
            timestamp: 1.00,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )

        let sample = driver.sampleGestureEnd(
            in: workspaceId,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement,
            timestamp: 1.05
        )!

        XCTAssertEqual(sample.relativeProjectedOffset, sample.relativeOffset, accuracy: 0.001)

        _ = commit(driver, previous: 0) { state in
            state.decelerateOffset(to: CGFloat(sample.relativeProjectedOffset))
        }

        XCTAssertFalse(driver.tick(in: workspaceId, at: CACurrentMediaTime()))
        XCTAssertFalse(driver.hasMotion(in: workspaceId))
    }

    func testFlingGestureEndProjectsAndCommitsDeceleration() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true)
        driver.updateGesture(
            in: workspaceId,
            delta: 120,
            timestamp: 1.00,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )

        let sample = driver.sampleGestureEnd(
            in: workspaceId,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement,
            timestamp: 1.04
        )!
        let expectedVelocity = 120.0 / 0.04

        XCTAssertEqual(
            sample.relativeProjectedOffset - sample.relativeOffset,
            -expectedVelocity / DecelerationAnimation.decayRate,
            accuracy: 0.001
        )

        _ = commit(driver, previous: 0) { state in
            state.decelerateOffset(to: CGFloat(sample.relativeProjectedOffset))
        }

        XCTAssertTrue(driver.tick(in: workspaceId, at: CACurrentMediaTime()))
    }

    func testJumpThenSpringCommitStartsAtJumpedOffset() {
        let driver = AnimationDriver()
        _ = commit(driver, previous: 0) { state in
            state.jumpOffset(to: 80)
            state.springOffset(to: 200)
        }
        let live = driver.liveViewOffset(in: workspaceId, semanticOffset: 200)!
        XCTAssertEqual(live, 80, accuracy: 1.0)
    }

    func testJumpCommitClearsActiveGesture() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true)
        _ = commit(driver, previous: 0) { $0.jumpOffset(to: 25) }
        XCTAssertFalse(driver.hasGesture(in: workspaceId))
        XCTAssertNil(driver.liveViewOffset(in: workspaceId, semanticOffset: 25))
    }

    func testTickExpiresGestureOneSecondAfterLastUpdateAndCompletesSpring() throws {
        let driver = AnimationDriver()
        let livenessClock = GestureLivenessTestClock(time: 10)
        driver.gestureLivenessNow = { livenessClock.time }
        let sessionID = try XCTUnwrap(
            driver.beginGesture(in: workspaceId, isTrackpad: true, timestamp: 10)
        )
        livenessClock.time = 10.25
        driver.updateGesture(
            in: workspaceId,
            delta: 10,
            timestamp: 10.25,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        XCTAssertTrue(driver.tick(in: workspaceId, at: 11.249))
        XCTAssertEqual(
            driver.tickResult(in: workspaceId, at: 11.25),
            .expiredGesture(relativeOffset: 10, sessionID: sessionID)
        )
        XCTAssertFalse(driver.hasGesture(in: workspaceId))

        _ = commit(driver, previous: 0) { $0.springOffset(to: 100) }
        XCTAssertTrue(driver.tick(in: workspaceId, at: CACurrentMediaTime()))
        XCTAssertFalse(driver.tick(in: workspaceId, at: CACurrentMediaTime() + 600))
        XCTAssertFalse(driver.hasMotion(in: workspaceId))
    }

    func testNonfiniteGestureInputFailsClosed() {
        let driver = AnimationDriver()
        driver.beginGesture(in: workspaceId, isTrackpad: true, timestamp: .nan)
        XCTAssertFalse(driver.hasGesture(in: workspaceId))

        driver.beginGesture(in: workspaceId, isTrackpad: true, timestamp: 1)
        driver.gestureLivenessNow = { .nan }
        driver.updateGesture(
            in: workspaceId,
            delta: .infinity,
            timestamp: 1.1,
            isTrackpad: true,
            viewportWidth: AnimationDriver.gestureWorkingAreaMovement
        )
        XCTAssertEqual(driver.liveViewOffset(in: workspaceId, semanticOffset: 50), 50)
        XCTAssertFalse(driver.tick(in: workspaceId, at: .nan))
        XCTAssertFalse(driver.hasGesture(in: workspaceId))
    }

    func testRemoveMotionsDropsWorkspaceState() {
        let driver = AnimationDriver()
        _ = commit(driver, previous: 0) { $0.springOffset(to: 100) }
        driver.removeMotions(for: [workspaceId])
        XCTAssertFalse(driver.hasMotion(in: workspaceId))
        XCTAssertFalse(driver.tick(in: workspaceId, at: CACurrentMediaTime()))
    }
}

@MainActor
private final class GestureLivenessTestClock {
    var time: TimeInterval

    init(time: TimeInterval) {
        self.time = time
    }
}
