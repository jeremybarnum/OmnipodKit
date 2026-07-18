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
//  Phone-side surface (releaseConnection/rearmConnection, C5 handover semantics,
//  ported from the OmniBLE fork's pod-loan branch @ eb8f6c3) lands in this same file
//  with the phone controller work — one file per module, per R11.
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
