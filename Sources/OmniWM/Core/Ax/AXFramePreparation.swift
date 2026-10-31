// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

@MainActor
struct AXFramePreparation {
    struct Options {
        let isRetry: Bool
        let verify: Bool
        let terminalObserver: AXFrameApplicationTerminalObserver?
        let traceOrigin: FrameEffectTraceOrigin
        let parentTraceRequestId: UInt64
    }

    let target: AXFrameApplicationTarget
    let options: Options
    let cachedState: AXAppliedFrameState?
    let pendingWrite: AXPendingFrameWrite?
    let components: AXFrameComponents
    let verify: Bool
    let traceRequestId: UInt64

    init(
        target: AXFrameApplicationTarget,
        options: Options,
        cachedState: AXAppliedFrameState?,
        pendingWrite: AXPendingFrameWrite?
    ) {
        self.target = target
        self.options = options
        self.cachedState = cachedState
        self.pendingWrite = pendingWrite
        traceRequestId = options.traceOrigin.effectId != 0 || options.parentTraceRequestId != 0
            ? FrameEffectTraceContext.makeRequestTraceId(parentTraceId: options.parentTraceRequestId)
            : 0
        let carriedWrite = pendingWrite.flatMap { pending in
            sameAXWindowIdentity(pending.expectedWindow, target.expectedWindow)
                && !Self.motionFrameReplaces(
                    pending, target: target, verify: options.verify, trustedSize: cachedState?.verifiedSize
                )
                ? pending : nil
        }
        var components = target.components
        if let carriedWrite {
            components.formUnion(carriedWrite.components)
        }
        self.components = components
        verify = options.verify || carriedWrite?.verify == true
    }

    // A motion frame keeps a verified size, so a pending write for that same size has
    // nothing left to carry, and the settling frame verifies. An app slower than the display
    // always has a write pending, so carrying it would keep every frame a size write plus a
    // readback until the motion ends.
    private static func motionFrameReplaces(
        _ pending: AXPendingFrameWrite,
        target: AXFrameApplicationTarget,
        verify: Bool,
        trustedSize: CGSize?
    ) -> Bool {
        guard !verify, target.components == .position, let trustedSize else { return false }
        return [pending.frame.size, target.frame.size].allSatisfy {
            abs($0.width - trustedSize.width) < FrameTolerance.frameWrite
                && abs($0.height - trustedSize.height) < FrameTolerance.frameWrite
        }
    }

    var matchesPendingWrite: Bool {
        pendingWrite?.matches(target: target, components: components, verify: verify) == true
    }

    var matchesVerifiedFrame: Bool {
        guard let cachedState else { return false }
        return cachedState.matches(target: target.frame, components: components)
            && (!verify || cachedState.verifiedComponents.contains(components))
    }

    func matchesTerminalRefusal(_ failure: AXRecentFrameWriteFailure) -> Bool {
        failure.matchesTerminalRefusal(
            expectedWindow: target.expectedWindow,
            frame: target.frame,
            components: components
        )
    }

    func coalescedDecision(observers: AXFrameObserverRegistry) -> AXFrameEnqueueDecision? {
        if let terminalObserver = options.terminalObserver, !options.isRetry,
           !observers.append(
               terminalObserver,
               for: target.windowId,
               expectedWindow: target.expectedWindow,
               targetFrame: target.frame,
               components: components
           )
        {
            return nil
        }
        if traceRequestId != 0 {
            record(
                requestId: 0,
                outcome: "ledger-coalesced/pending",
                relatedTraceRequestId: pendingWrite?.traceRequestId ?? 0
            )
        }
        return AXFrameEnqueueDecision()
    }

    func refusedDecision(_ failure: AXRecentFrameWriteFailure, requestId: AXFrameRequestId) -> AXFrameEnqueueDecision {
        record(requestId: requestId, outcome: "ledger-refused/\(failure.reason.traceDescription)")
        guard let terminalObserver = options.terminalObserver else { return AXFrameEnqueueDecision() }
        return AXFrameEnqueueDecision(deliveries: [AXFrameTerminalDelivery(
            result: AXFrameApplyResult.refusedFrameApplyResult(
                requestId: requestId, target: target, currentFrameHint: cachedState?.frame,
                refusal: failure, traceRequestId: traceRequestId
            ),
            observers: [terminalObserver]
        )])
    }

    func noOpDecision(requestId: AXFrameRequestId) -> AXFrameEnqueueDecision {
        if traceRequestId != 0 {
            record(requestId: requestId, outcome: "ledger-noop/applied/terminal")
        }
        guard let terminalObserver = options.terminalObserver, let cachedState else { return AXFrameEnqueueDecision() }
        return AXFrameEnqueueDecision(deliveries: [AXFrameTerminalDelivery(
            result: AXFrameApplyResult.successfulNoOpFrameApplyResult(
                requestId: requestId, target: target, observedFrame: cachedState.frame,
                components: components, traceRequestId: traceRequestId
            ),
            observers: [terminalObserver]
        )])
    }

    func request(id: AXFrameRequestId) -> AXFrameApplicationRequest {
        AXFrameApplicationRequest(
            requestId: id,
            pid: target.pid,
            windowId: target.windowId,
            expectedWindow: target.expectedWindow,
            frame: target.frame,
            currentFrameHint: cachedState?.frame,
            components: components,
            verify: verify,
            traceRequestId: traceRequestId
        )
    }

    func recordPrepared(requestId: AXFrameRequestId) {
        if traceRequestId != 0 {
            record(requestId: requestId, outcome: options.isRetry ? "ledger-prepared/retry" : "ledger-prepared")
        }
    }

    private func record(requestId: AXFrameRequestId, outcome: String, relatedTraceRequestId: UInt64 = 0) {
        options.traceOrigin.recordFrameDecision(
            traceRequestId: traceRequestId, parentTraceRequestId: options.parentTraceRequestId,
            requestId: requestId, target: target, outcome: outcome, relatedTraceRequestId: relatedTraceRequestId
        )
    }
}
