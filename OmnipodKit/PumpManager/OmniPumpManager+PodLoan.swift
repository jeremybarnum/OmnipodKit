//
//  OmniPumpManager+PodLoan.swift
//  OmnipodKit
//
//  PODLOAN — the single ringfenced pod-loan seam file for OmnipodKit (RULINGS.md R11:
//  hardware-module deviations live in ONE +Feature extension file per module; audit =
//  read this file + `grep -rn "// PODLOAN" OmnipodKit/`). Loop-side consumer:
//  Loop/docs/DESIGN_LOAN_PROTOCOL_V2.md §10 (PodLoanWatchController).
//
//  Watch-side surface (this commit): a forced status read and an uncertain-command
//  verdict, exposing to app code what stock computes internally. Stock's own recovery
//  (PodCommsSession.recoverUnacknowledgedCommand, PodCommsSession.swift:1109-1123) runs
//  lazily inside any getStatus and already materializes the dose consequences into
//  UnfinalizedDose/finalizedDoses -> hasNewPumpEvents; what it does NOT do is report
//  the delivered/refuted verdict outward, proactively chase it, or know anything about
//  the loan journal's provenance tags. This file adds ONLY the outward report; the
//  chase timing and journal consequences live in app code (never in the driver).
//
//  Phone-side surface: the PumpConnectionLendable conformance below (ported from the
//  OmniBLE fork's pod-loan branch @ eb8f6c3/c6c37f9) — the phone deliberately stops
//  bidding for the pod's single BLE connection at grant and re-arms at reclaim, with
//  the C5 record truncation at the handover stamp (R2).
//
//  COMPLETE FOOTPRINT — audit the whole feature with:  grep -rn "PODLOAN" OmnipodKit/
//   • This file — all behavior.
//   • OmniPumpManagerState.swift — persisted `podConnectionReleased` (declaration,
//     decode, encode) + podState promoted private(set)→internal(set) for C5. Tagged.
//   • OmniPumpManager.swift — podComms and setState promoted private→internal;
//     init-time restore of a persisted release. Tagged.
//   • Bluetooth/BlePodComms.swift — releaseConnection()/rearmConnection(): the
//     BLE-layer disarm/re-arm of the standing auto-connect. Tagged.
//   • (LoopKit) DeviceManager/PumpManager.swift — the PumpConnectionLendable
//     protocol the Loop app talks to. Tagged.
//

import Foundation
import LoopKit

extension OmniPumpManager {

    /// The command kinds a pending (unacknowledged) pod command can have, as app code
    /// needs to reason about them (journal event kinds, alert wording).
    public enum PodLoanPendingKind: String {
        case bolus
        case tempBasal
        case resume          // .program(.basalProgram) — reinstating the stored schedule
        case suspend         // .stopProgram containing .basal
        case cancelTempBasal
        case cancelBolus
    }

    public enum PodLoanUncertaintyVerdict {
        /// Nothing pending — either never uncertain, or stock recovery already ran on a
        /// prior contact and the dose consequences are in hasNewPumpEvents.
        case noPendingCommand
        /// The pod executed the lost command (seq match or delivered-only corroboration).
        case delivered(PodLoanPendingKind)
        /// The pod never received it — the max-exposure assumption should be annulled.
        case refuted(PodLoanPendingKind)
        /// The pod could not be reached; the assumption stands, try again later.
        case unreachable
    }

    /// Kind of the command whose fate is currently unknown, if any. App code uses this
    /// to detect non-bolus uncertainty: enactTempBasal/suspend/resume report a generic
    /// .communication error for an unacknowledged outcome (OmniPumpManager.swift:2795,
    /// :2381) — only enactBolus returns .uncertainDelivery (:2578).
    public var podLoanPendingCommandKind: PodLoanPendingKind? {
        guard let pending = state.podState?.unacknowledgedCommand else { return nil }
        return Self.podLoanKind(of: pending)
    }

    /// The pod's cumulative-delivered odometer as last reported (R12: the audit, never
    /// the source). Freshen with podLoanReadStatus before snapshotting (OQ-5).
    public var podLoanInsulinDelivered: Double? {
        return state.podState?.lastInsulinMeasurements?.delivered
    }

    /// True while a pod fault is active — rides StatusReport.podFault (spec §6).
    public var podLoanFaultDescription: String? {
        guard let fault = state.podState?.fault else { return nil }
        return String(describing: fault.faultEventCode)
    }

    /// PODLOAN: begin a cross-device loan takeover. The granted pod state's
    /// `bleIdentifier` is the PHONE's per-device CoreBluetooth UUID and is useless here,
    /// so we scan for the pod by its (global) message address and adopt the peripheral
    /// THIS device discovers. The session then re-establishes from the granted keys.
    /// Call once, right after constructing the manager from the grant, before reading
    /// status. Returns false if there's no address to scan for.
    @discardableResult
    public func podLoanBeginTakeover() -> Bool {
        guard let address = state.podState?.address else { return false }
        // The grant snapshot was serialized AFTER the phone released the connection, so
        // it arrives stamped podConnectionReleased=true. On THIS device that stamp is a
        // lie — the takeover is about to own the pod — and leaving it set both replays
        // the init-time disarm on every relaunch mid-loan and (with autoConnectIDs
        // emptied by that disarm) starves the poweredOn scan trigger.
        setState { (state) in
            state.podConnectionReleased = false
        }
        (podComms as? BlePodComms)?.beginLoanTakeover(podId: address)
        return true
    }

    /// PODLOAN E4 (157): escalate a stalled reclaim to the takeover-grade recovery path.
    /// The reclaim's bare pending-connect proved probabilistic in the field while the
    /// scan-adopt takeover landed 4/4 from arbitrary idle — when the connect hasn't
    /// settled mid-ladder, drop the central and scan for the pod by address instead.
    /// No-op if there's no pod address. watchOS only; iOS never reclaims a loan.
    public func podLoanEscalateReclaim() {
        #if os(watchOS)
        guard let address = state.podState?.address else { return }
        (podComms as? BlePodComms)?.escalateLoanReclaim(podId: address)
        #endif
    }

    /// A REAL status read, bypassing the freshness optimization (getPodStatus is
    /// internal and ensureCurrentPumpData skips the read unless data is stale — neither
    /// serves a takeover-proof or a verdict chase). Completion: true when a status
    /// round-trip succeeded.
    public func podLoanReadStatus(completion: @escaping (Bool) -> Void) {
        getPodStatus(canOptimize: false) { result in
            if case .success(let status) = result, status != nil {
                completion(true)
            } else {
                completion(false)
            }
        }
    }

    /// Chases the verdict on the pending command NOW: one forced status read, then the
    /// same rules stock applies internally — seq equality with the lost command
    /// (PodCommsSession.swift:1113) OR delivered-only corroboration from the delivery-
    /// status flags (checkCommandAgainstStatus, PodCommsSession.swift:1057-1107). The
    /// status read itself triggers stock recovery, so by the time the completion runs
    /// the dose consequences are already flowing to hasNewPumpEvents; this method's
    /// only addition is telling the caller WHICH way it resolved.
    public func podLoanResolveUncertainty(completion: @escaping (PodLoanUncertaintyVerdict) -> Void) {
        guard let pending = state.podState?.unacknowledgedCommand else {
            completion(.noPendingCommand)
            return
        }
        let kind = Self.podLoanKind(of: pending)
        let sequence = pending.sequence

        getPodStatus(canOptimize: false) { result in
            switch result {
            case .failure:
                completion(.unreachable)
            case .success(let statusOrNil):
                guard let status = statusOrNil else {
                    completion(.unreachable)
                    return
                }
                let seqMatch = Int(status.lastProgrammingMessageSeqNum) == sequence
                let corroborated = Self.podLoanStatusCorroboratesDelivery(of: pending, status: status)
                completion(seqMatch || corroborated ? .delivered(kind) : .refuted(kind))
            }
        }
    }

    // MARK: - PumpConnectionLendable (the phone half)

    /// True while the pod's connection is deliberately released (on loan).
    public var isConnectionReleased: Bool {
        return state.podConnectionReleased
    }

    /// True once the reclaimed connection is truly back — the pod peripheral is connected.
    /// `reclaimConnection()` only re-arms the bid (rearmConnection); the actual BLE reconnect
    /// lands seconds-to-minutes later, so post-hand-back UI keeps "Reclaiming…" up until this
    /// turns true (distinct from `isConnectionReleased`, the loan flag, which clears at reclaim).
    public var isConnectionReady: Bool {
        return podLoanConnectionStateDescription == "connected"
    }

    /// The pod peripheral's ACTUAL CoreBluetooth state, for diagnosing reclaim failures.
    /// `podLoanReadStatus` returns a bare Bool, so a run of failed reads could not
    /// distinguish "peripheral wedged in .disconnecting" (the E4-v1 poisoning signature)
    /// from "never reached .connected" from "connected but the status read failed" —
    /// three different bugs that look identical from outside (2026-07-22: three theories
    /// raised and falsified against exactly this blind spot). Read-only.
    public var podLoanConnectionStateDescription: String {
        guard let peripheral = (podComms as? BlePodComms)?.manager?.peripheral else {
            return "no-peripheral"
        }
        switch peripheral.state {
        case .disconnected:  return "disconnected"
        case .connecting:    return "connecting"
        case .connected:     return "connected"
        case .disconnecting: return "DISCONNECTING(wedged?)"
        @unknown default:    return "unknown(\(peripheral.state.rawValue))"
        }
    }

    /// Deliberately stop bidding for the pod's BLE connection so another controller
    /// (the watch) can hold it uncontested. Pod state, pairing and keys are untouched;
    /// persisted across relaunches. Reverse: reclaimConnection().
    public func releaseConnection() {
        let handedOverAt = Date()
        setState { (state) in
            state.podConnectionReleased = true
            // C5 (loan-boundary accounting, R2): close this phone's RECORD of a running
            // temp basal at the handover stamp. The pod keeps physically running the
            // temp until the watch's first command supersedes it — that gap window is
            // deliberately unjournaled and covered by the hand-back odometer audit.
            // Without this truncation the mutable dose entry finalizes at its full
            // programmed extent and OVERLAPS the watch journal's entries for the same
            // wall-clock window, double-counting the deviation.
            if let tempBasal = state.podState?.unfinalizedTempBasal, !tempBasal.isFinished(at: handedOverAt) {
                state.podState?.unfinalizedTempBasal?.cancel(at: handedOverAt)
            }
        }
        (podComms as? BlePodComms)?.releaseConnection()
    }

    /// Resume bidding for the pod's BLE connection after a loan ends. The standing
    /// connect re-arms; the session re-establishes on next contact and the next
    /// status poll resynchronizes state.
    public func reclaimConnection() {
        setState { (state) in
            state.podConnectionReleased = false
        }
        (podComms as? BlePodComms)?.rearmConnection()
    }

    private static func podLoanKind(of pending: PendingCommand) -> PodLoanPendingKind {
        switch pending {
        case .program(let program, _, _, _):
            switch program {
            case .bolus: return .bolus
            case .tempBasal: return .tempBasal
            case .basalProgram: return .resume
            }
        case .stopProgram(let deliveryType, _, _, _):
            if deliveryType.contains(.basal) { return .suspend }
            if deliveryType.contains(.tempBasal) { return .cancelTempBasal }
            return .cancelBolus
        }
    }

    /// Mirror of PodCommsSession.checkCommandAgainstStatus (PodCommsSession.swift:
    /// 1057-1107): corroboration can only ADD a delivered verdict, never refute a seq
    /// match. A rate-0 temp IS a running temp (tempBasalRunning) — the R3 suspend
    /// resolves through the tempBasal row.
    private static func podLoanStatusCorroboratesDelivery(of pending: PendingCommand, status: StatusResponse) -> Bool {
        let delivery = status.deliveryStatus
        switch pending {
        case .program(let program, _, _, _):
            switch program {
            case .bolus: return delivery.bolusing
            case .tempBasal: return delivery.tempBasalRunning
            case .basalProgram: return !delivery.suspended
            }
        case .stopProgram(let deliveryType, _, _, _):
            if deliveryType.contains(.basal) { return delivery.suspended }
            if deliveryType.contains(.tempBasal) { return !delivery.tempBasalRunning }
            if deliveryType.contains(.bolus) { return !delivery.bolusing }
            return false
        }
    }
}

// PODLOAN: the optional capability the Loop app discovers by conditional cast
// ((pumpManager as? PumpConnectionLendable)?.releaseConnection()). The audit surface
// forwards to the seam accessors above — the app never names OmnipodKit types
// (pumps load as plugins).
extension OmniPumpManager: PumpConnectionLendable {
    public var lentDeviceInsulinDelivered: Double? {
        return podLoanInsulinDelivered
    }

    public func refreshLentDeviceStatus(completion: @escaping (Bool) -> Void) {
        podLoanReadStatus(completion: completion)
    }
}
