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
    public func podLoanBeginTakeover(liveTempStart: Date? = nil, liveTempEnd: Date? = nil) -> Bool {
        guard let address = state.podState?.address else { return false }
        // The grant snapshot was serialized AFTER the phone released the connection, so
        // it arrives stamped podConnectionReleased=true. On THIS device that stamp is a
        // lie — the takeover is about to own the pod — and leaving it set both replays
        // the init-time disarm on every relaunch mid-loan and (with autoConnectIDs
        // emptied by that disarm) starves the poweredOn scan trigger.
        var rearmedTemp: UnfinalizedDose?
        setState { (state) in
            state.podConnectionReleased = false
            // PODLOAN #72 (2026-07-28): the phone's C5 record-close cancelled the running temp
            // at the handover stamp INSIDE this blob (releaseConnection runs before rawValue is
            // serialized), so the inherited copy arrives finished-at-handover and this device's
            // re-reports would freeze IOB there while the pod keeps delivering. Re-arm it: the
            // C5 cancel is exactly reversible (cancel(at:) stamps scheduledUnits = programmed
            // total and scheduledTempRate = original rate, and NOTHING else ever sets those on
            // an unfinalizedTempBasal). This device then tracks the LIVE temp: mutable
            // re-reports every status read (IOB climbs with delivery), and updateDeliveryStatus
            // books the truth at the end. The PHONE's own copy stays cancelled, so R2's
            // record-close-at-handover and the hand-back accounting are untouched; this watch
            // never journals the inherited temp.
            //
            // GUARD (adversarial review): re-arm ONLY when the grant's dose history ALSO says
            // the temp is live (liveTempStart matches the record's start). The C5 signature can
            // outlive ground truth across back-to-back loans (the phone's copy lingers finished-
            // with-signature while a NEWER watch temp runs, because the prune branch needs
            // !tempBasalRunning) — the phone's BOOKS distinguish the cases: a genuinely-live
            // temp rides doseHistory as a mutable full-span record; a superseded one arrives
            // finished. liveTempEnd doubles as the rate-0 restore (a 0 U/hr temp's programmed
            // span is unrecoverable from the cancel math — 0/0 — but the record carries it).
            if let recordStart = liveTempStart {
                rearmedTemp = state.podState?.podLoanRearmInheritedTempBasal(liveTempStart: recordStart, liveTempEnd: liveTempEnd)
            }
        }
        if let tempBasal = rearmedTemp {
            log.default("PODLOAN #72: re-armed inherited running temp — %{public}@", String(describing: tempBasal))
            // PODLOAN #72 copy-divergence fix (2026-07-29, first shadow-ledger field session):
            // the setState above mutates only the MANAGER's PodState copy, but every
            // PodCommsSession is built from podComms' OWN copy — which still carries the C5
            // cancel. Without this push the first status read reports the inherited temp
            // finished-truncated (immutable), that row tombstones the raw in the DoseStore
            // (store-trump merge; the mutable-only purge never removes it), and the first
            // session write-back reverts the manager copy too — the re-arm was dead ~15s
            // after this log line, freezing IOB at the handover stamp while the pod kept
            // running the temp (observed as Δ(store−ledger) growing at exactly the unbooked
            // remaining span). Same shared transform, applied under podStateLock BEFORE any
            // connection exists.
            if let blePodComms = podComms as? BlePodComms {
                if let recordStart = liveTempStart,
                   blePodComms.podLoanRearmInheritedTempBasal(liveTempStart: recordStart, liveTempEnd: liveTempEnd) {
                    log.default("PODLOAN #72: re-arm propagated to comms copy — sessions report the live temp mutable")
                } else {
                    // Should be unreachable: both copies were value-copied from the same
                    // rawState and the transform is deterministic — a genuine divergence
                    // here means a mutation path we don't know about. Tripwire, keep loud.
                    log.error("PODLOAN #72: comms-copy re-arm FAILED — copies diverged; store will freeze the inherited temp at the handover stamp")
                }
            } else {
                log.error("PODLOAN #72: podComms is not BlePodComms — loan re-arm not applicable to this pod type; inherited temp stays closed at handover")
            }
        } else if state.podState?.unfinalizedTempBasal?.scheduledUnits != nil {
            log.default("PODLOAN #72: inherited temp NOT re-armed (no matching live record — phone books say it finished); record stays closed at handover")
        }
        (podComms as? BlePodComms)?.beginLoanTakeover(podId: address)
        return true
    }

    /// PODLOAN #72 (instrumentation): the inherited/live running temp this device now tracks,
    /// if any — for the watch controller's SportLog line at takeover.
    public var podLoanLiveTempBasalDescription: String? {
        guard let tempBasal = state.podState?.unfinalizedTempBasal, !tempBasal.isFinished() else { return nil }
        guard let finishTime = tempBasal.finishTime else { return nil }
        return String(format: "%.2f U/hr, %.0f min remaining", tempBasal.rate, finishTime.timeIntervalSinceNow / 60)
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
        #if targetEnvironment(simulator)
        // SIM LOAN HARNESS (#61, 2026-08-07). The simulator has no radio, so a real status
        // round-trip can never complete and every loan died at the takeover ladder — which made
        // the entire loan lifecycle (glance during a loan, carb flow during a loan, hand-back)
        // untestable off-wrist. Three of 2026-08-07's field failures lived exactly there.
        //
        // This is the ONE seam a simulated takeover needs: complete the read after a plausible
        // connect latency, and stamp the odometer measurement the ACTIVE transition requires
        // (`podLoanInsulinDelivered` must be non-nil — the granted mock pod has never had a real
        // status read, so it arrives nil). Everything else — grant intake, seeds, phase machine,
        // glance, dosing books — runs the REAL code. Same pattern as upstream's jumpStartPod:
        // fabricate the radio's answer, never the bookkeeping.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return completion(false) }
            self.setState { state in
                if state.podState?.lastInsulinMeasurements == nil {
                    let delivered = state.podState?.setupUnitsDelivered ?? Pod.primeUnits
                    state.podState?.lastInsulinMeasurements = PodInsulinMeasurements(
                        insulinDelivered: delivered,
                        reservoirLevel: nil,
                        validTime: Date())
                }
            }
            self.log.default("SIM LOAN: podLoanReadStatus simulated OK (no radio in the simulator)")
            completion(true)
        }
        #else
        getPodStatus(canOptimize: false) { result in
            if case .success(let status) = result, status != nil {
                completion(true)
            } else {
                completion(false)
            }
        }
        #endif
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

    /// True when a MANUAL bolus will make the POD beep — acknowledgement when it accepts the
    /// command, completion when delivery ends (OmniPumpManager :2552-2558; completionBeep is
    /// manual-only, so automatic loop doses beep once, not twice).
    ///
    /// The watch's success haptic fires on enactBolus's completion, which is the SAME instant
    /// as the acknowledgement beep and carries the same information. Jeremy, 2026-08-05: "let's
    /// eliminate these silent haptic bolus confirmations that overlap with beeps." Conditional
    /// rather than deleted, because beeps are still suppressed in the sport build (re-enabling
    /// them for Caitlin is on the pre-production list) — deleting outright would leave a bolus
    /// confirming with nothing at all until that flips. The watch inherits these settings from
    /// the phone in the grant's pumpManagerRawState, so this tracks the phone automatically.
    public var podLoanBeepsOnManualBolus: Bool {
        guard !silencePod else { return false }
        return beepPreference.shouldBeepForCommand(automatic: false)
    }

    /// True once the reclaimed connection is truly back — the pod peripheral is connected.
    /// `reclaimConnection()` only re-arms the bid (rearmConnection); the actual BLE reconnect
    /// lands seconds-to-minutes later, so post-hand-back UI keeps "Reclaiming…" up until this
    /// turns true (distinct from `isConnectionReleased`, the loan flag, which clears at reclaim).
    public var isConnectionReady: Bool {
        #if targetEnvironment(simulator)
        // SIM LOAN HARNESS (#61): no radio -> no peripheral ever reaches .connected, which
        // starves the phone's reclaim verification (PodLoanPhoneController gates the verifying
        // status read on this) and pins every post-loan settle window at its 5-minute ceiling.
        // A jump-started sim pod is by definition "home", so say so.
        return state.podState != nil
        #else
        return podLoanConnectionStateDescription == "connected"
        #endif
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

    /// PODLOAN #72 (E4 fix, 2026-07-28 adversarial review): drop the pod's BLE connection
    /// WITHOUT the C5 record-close. The C5 cancel in `releaseConnection()` is HANDOVER
    /// accounting — this device stops being the controller, so its record of the running temp
    /// closes at the stamp (R2). The watch's E4 orphaning between doses is NOT a handover:
    /// the watch remains the controller and its books must keep tracking the running temp
    /// (its own enacted temps AND a re-armed inherited one) across every release/reclaim
    /// cycle. Before this split, each E4 release silently re-truncated the running temp at
    /// the release stamp — killing live IOB tracking ~90s after takeover and quietly
    /// under-booking long-running temps under NO-CHANGE verdicts.
    public func podLoanOrphanConnection() {
        setState { (state) in
            state.podConnectionReleased = true
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

extension PodState {
    /// PODLOAN #72: the single guarded re-arm transform, shared by BOTH PodState copies
    /// (the manager's lockedState and BlePodComms' session-facing copy — see
    /// `podLoanRearmInheritedTempBasal` on BlePodComms for why both must be hit).
    ///
    /// GUARD (adversarial review, unchanged from the setState original): re-arm ONLY when the
    /// grant's dose history ALSO says the temp is live (liveTempStart matches the record's
    /// start ±2s). The C5 signature can outlive ground truth across back-to-back loans; the
    /// phone's BOOKS distinguish the cases. liveTempEnd doubles as the rate-0 restore.
    ///
    /// Returns the re-armed dose, or nil when the guard rejects (no temp, start mismatch,
    /// or no C5 signature — the transform is idempotent, so a second call is a clean nil).
    ///
    /// KNOWN CORNER (2026-07-29 adversarial review, accepted): after a FAILED hand-back, the
    /// phone's books can still carry the temp as a live mutable row (no phone-pod contact to
    /// correct them), so a re-grant re-arms a temp the watch itself superseded in the prior
    /// epoch — overbooking its undelivered tail until the first status read finalizes it.
    /// Deliberately NOT guarded away: refusing elapsed/stale spans would break the legitimate
    /// natural-completion case (temp finished during the handover gap — its full span WAS
    /// delivered and must book). The corner needs failed-hand-back + re-grant with zero
    /// phone-pod contact, errs conservative (IOB high → less dosing), is watch-local, is
    /// erased by the next takeover wipe, and the hand-back odometer audit bounds it.
    mutating func podLoanRearmInheritedTempBasal(liveTempStart: Date, liveTempEnd: Date?) -> UnfinalizedDose? {
        guard var tempBasal = unfinalizedTempBasal,
              abs(liveTempStart.timeIntervalSince(tempBasal.startTime)) < 2.0,
              tempBasal.podLoanRearmHandoverCancel(programmedEnd: liveTempEnd) else {
            return nil
        }
        unfinalizedTempBasal = tempBasal
        return tempBasal
    }
}

extension UnfinalizedDose {
    /// PODLOAN #72: reverse the C5 handover cancel on an INHERITED running temp, restoring its
    /// programmed extent so the inheriting device tracks the live delivery.
    ///
    /// Exactly reversible because `cancel(at:)` stamps `scheduledUnits` = programmed total units
    /// and `scheduledTempRate` = original rate before shortening — and nothing else ever sets
    /// those fields on a temp basal, so their presence IS the C5 signature. Restoring clears
    /// them, which also restores `uniqueKey` identity (`scheduledUnits ?? units` yields the same
    /// programmed-total value either way) and makes the re-arm idempotent (second call finds
    /// nil `scheduledUnits` and no-ops). Non-temps and never-cancelled temps are untouched.
    ///
    /// - Parameter programmedEnd: the grant dose record's programmed end — the ONLY way to
    ///   restore a 0 U/hr temp (cancel leaves scheduledUnits=0, scheduledTempRate=0, so the
    ///   span is unrecoverable as 0/0), and a cross-check fallback otherwise.
    /// - Returns: true when a C5-cancelled temp was re-armed.
    mutating func podLoanRearmHandoverCancel(programmedEnd: Date? = nil) -> Bool {
        guard doseType == .tempBasal,
              let programmedUnits = scheduledUnits,
              let programmedRate = scheduledTempRate else {
            return false
        }
        if programmedRate > 0 {
            units = programmedUnits
            duration = programmedUnits / programmedRate * 3600.0   // hours → seconds, exact inverse of units = rate × duration.hours
        } else if let end = programmedEnd, end > startTime {
            // Rate-0 temp (Loop's standard predicted-low): restore the span from the grant
            // record; delivered units are 0 by definition.
            units = 0
            duration = end.timeIntervalSince(startTime)
        } else {
            return false   // rate-0 with no record end: span unrecoverable, leave closed
        }
        scheduledUnits = nil
        scheduledTempRate = nil
        return true
    }
}

// MARK: - PODLOAN #86: an independent clock for BLE connect/disconnect

/// The takeover ladder polls `podLoanConnectionStateDescription` from a timer it schedules
/// itself. On 2026-07-31 that turned out to be unfalsifiable as a diagnostic: watchOS defers a
/// non-frontmost app's timers — measured stretching an `asyncAfter(3s)` to 8, 60, 9, 51 and 39
/// seconds — so a read at +68 s reporting "connecting" could mean either the connection was
/// still forming, or that it completed at +10 s and nobody looked until the timer finally fired.
/// Those two have OPPOSITE fixes (make the ladder event-driven vs. hold a keepalive across the
/// connect), and the log could not tell them apart because the instrument and the suspect shared
/// a clock.
///
/// So stamp the CoreBluetooth callbacks themselves. `didConnect` fires from the BLE stack, not
/// from our polling, which makes "connected at +12 s, first observed at +68 s" distinguishable
/// from "connected at +200 s". Pure observation: nothing here influences connection behaviour.
public enum PodLoanConnectClock {
    private static let lock = NSLock()
    private static var _lastConnectAt: Date?
    private static var _lastDisconnectAt: Date?
    private static var _connectCount = 0
    private static var _lastReason: String?
    private static var _reasons: [String] = []
    private static var _lastCensus: String?
    /// #86: kept SEPARATE from _lastReason. In a retry storm didFailToConnect fires >=4x/sec and
    /// both overwrote one field + flooded the 12-slot trail, evicting the one datum that says why
    /// an ESTABLISHED link died (observed 2026-08-01: epoch 111's trail was 12x "x#11" and the
    /// disconnect reasons were unrecoverable). Disconnects are rare; failures are the flood.
    private static var _lastDisconnectReason: String?

    /// Set by the app so every BLE event can record what execution state we were in when it
    /// fired. #86: the flapping and the polling deferral were BOTH only ever observed overnight,
    /// wrist-down. Sport Mode is the opposite regime — awake, moving, wrist live — and watchOS
    /// schedules a moving workout app differently. Without this stamp we cannot tell whether a
    /// drop belongs to the regime that actually matters.
    /// #86 (2026-08-03): the pod BLE stack's own "encrypted session is live" event, republished
    /// for the watch takeover. THE point of this hook is that it fires from
    /// BlePodComms.completeConfiguration AFTER sendHello / enableNotifications /
    /// establishNewSession have all succeeded — i.e. it is the stack telling us the link is
    /// genuinely usable, rather than us inferring it from CBPeripheral.state.
    ///
    /// Why that matters: the takeover ladder polled peripheral.state from the loan controller's
    /// queue, but CBPeripheral state is only valid on the central's queue. Field 2026-08-03
    /// epoch 143, with the app running perfectly (max inter-read gap 3.3 s), every read
    /// contradicted the connect callbacks — read 4 said "disconnected" 0.3 s after didConnect,
    /// read 9 said "connecting" 0.5 s after didConnect. The session guard bailed on that stale
    /// value, so nothing was ever sent, and the pod hung up on the silent link after its idle
    /// timeout — seven connections, each 3.5-3.6 s, metronomic.
    ///
    /// The pre-stock build never hit this because it never polled: it parked the takeover
    /// completion and finished on exactly this callback. This restores that contract.
    public static var podLoanOnSessionEstablished: (() -> Void)?

    /// #86 (2026-08-03): a sink so the BLE layer can reach the WATCH's mirrored log.
    ///
    /// OmnipodKit logs via os_log, which goes to the system log and is invisible in the
    /// g7watch file log the field analysis actually reads. A [CONFIG] diagnostic added on
    /// 2026-08-03 to settle "did we ever talk to the pod" produced ZERO lines in the field for
    /// exactly that reason — the instrument meant to end the ambiguity could not be seen.
    /// The watch installs this at startup; the phone leaves it nil and keeps os_log only.
    public static var podLoanLogSink: ((String) -> Void)?

    /// Emit to BOTH os_log (via the caller) and the watch's mirrored log, if wired.
    public static func podLoanLog(_ line: String) {
        podLoanLogSink?(line)
    }

    public static var appStateProbe: (() -> String)?

    public static var lastConnectAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastConnectAt }
    public static var lastDisconnectAt: Date? { lock.lock(); defer { lock.unlock() }; return _lastDisconnectAt }
    public static var connectCount: Int { lock.lock(); defer { lock.unlock() }; return _connectCount }

    private static func stateTag() -> String { appStateProbe?() ?? "?" }

    /// CoreBluetooth's own account of why a link ended. THIS is the field that separates
    /// "the pod dropped us" from "something else took the connection" from "we never had it":
    ///   CBError.peripheralDisconnected (6)     — the peer terminated
    ///   CBError.connectionTimeout (6/…)        — link supervision timeout, i.e. out of range
    ///   CBError.connectionFailed               — never established
    ///   nil                                    — WE cancelled it (our own code)
    /// A nil reason on a drop we did not initiate is itself a finding.
    private static func describe(_ error: Error?) -> String {
        guard let error = error else { return "reason=nil(local-cancel?)" }
        let ns = error as NSError
        return "reason=\(ns.domain)#\(ns.code)"
    }

    public static func noteConnect() {
        lock.lock()
        _lastConnectAt = Date(); _connectCount += 1
        _reasons.append("+\(_connectCount)@\(stateTag())")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    public static func noteDisconnect(error: Error? = nil) {
        let d = describe(error), st = stateTag()
        lock.lock()
        _lastDisconnectAt = Date(); _lastDisconnectReason = d
        _reasons.append("-\(d)@\(st)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    /// `census` is the caller's snapshot of what THIS process holds (see
    /// BluetoothManager.peripheralCensus). Only recorded on failures — it is the field that
    /// separates our own retry storm from slots consumed elsewhere on the device.
    public static func noteFailToConnect(error: Error? = nil, census: String? = nil) {
        let d = describe(error), st = stateTag()
        lock.lock()
        _lastReason = d
        _lastCensus = census ?? _lastCensus
        _reasons.append("x\(d)@\(st)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    /// The failed-takeover message branches on this. A Code-11 refusal anywhere in the attempt,
    /// or an attempt that never once connected, is the orphaned-pending-connect signature:
    /// CoreBluetooth connect requests are system-level and OUTLIVE the app that issued them, so
    /// a force-quit mid-retry-storm leaves pending connects no living process can cancel — the
    /// slots stay consumed and the radio goes blind. Field 2026-08-22, twice: takeover refused
    /// with #11, then a second attempt that saw zero adverts in 108 s while the phone reconnected
    /// to the same pod in 6.6 s. "Try again" WORSENS this state (each force-quit-and-retry
    /// orphans more); a watch Bluetooth toggle flushes it — confirmed same night, first try.
    public static var wedgeSignature: Bool {
        lock.lock(); defer { lock.unlock() }
        if let r = _lastReason, r.contains("#11") { return true }
        return _connectCount == 0
    }

    public static func reset() {
        lock.lock()
        _lastConnectAt = nil; _lastDisconnectAt = nil; _connectCount = 0
        _lastReason = nil; _reasons = []; _lastCensus = nil; _lastDisconnectReason = nil
        lock.unlock()
    }

    /// Compact summary for a takeover/reclaim log line, relative to the attempt's start.
    /// The trail is the whole point: "+1@active -reason=CBErrorDomain#6@inactive +2@inactive …"
    /// reads the flap sequence, its reasons, and the execution state at each edge, in one field.
    public static func summary(since start: Date?) -> String {
        lock.lock()
        let c = _lastConnectAt, d = _lastDisconnectAt, n = _connectCount
        let r = _lastReason, trail = _reasons, cen = _lastCensus, dr = _lastDisconnectReason
        lock.unlock()
        guard let start = start else { return "cb: (no anchor)" }
        func rel(_ t: Date?) -> String { t.map { String(format: "+%.1fs", $0.timeIntervalSince(start)) } ?? "never" }
        let why = r.map { " · lastFail=\($0)" } ?? ""
        let dwhy = dr.map { " · lastDrop=\($0)" } ?? ""
        let tr = trail.isEmpty ? "" : " · trail[\(trail.joined(separator: " "))]"
        let cz = cen.map { " · held[\($0)]" } ?? ""
        return "cb: didConnect \(rel(c)) (n=\(n)) · didDisconnect \(rel(d))\(dwhy)\(why)\(cz)\(tr)"
    }
}
