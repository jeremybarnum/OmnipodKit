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

    /// The pod's cumulative-delivered odometer as last reported (R12: the audit, never
    /// the source). Freshen with podLoanReadStatus before snapshotting (OQ-5).
    public var podLoanInsulinDelivered: Double? {
        return state.podState?.lastInsulinMeasurements?.delivered
    }

    /// When `podLoanInsulinDelivered` was actually read off the pod (the status response's
    /// validTime). The pair (delivered, asOf) is what makes a mid-loan odometer reading a
    /// checkpoint the phone's audit can anchor to.
    public var podLoanInsulinDeliveredAt: Date? {
        return state.podState?.lastInsulinMeasurements?.validTime
    }

    /// True while a pod fault is active — rides StatusReport.podFault (spec §6).
    public var podLoanFaultDescription: String? {
        guard let fault = state.podState?.fault else { return nil }
        return String(describing: fault.faultEventCode)
    }

    /// PODLOAN: begin a cross-device loan takeover. Call once, right after constructing the
    /// manager from the grant, before reading status. `discover` arms the scan-adopt for a pod
    /// this device holds no CoreBluetooth handle for; with a handle of its own already in the
    /// snapshot the driver's ordinary connect path dials on the first read and nothing is armed.
    /// The decision is the caller's — it patched the handle in and must not be second-guessed by
    /// a CoreBluetooth lookup that races the central to poweredOn (field 2026-09-16 08:13: the
    /// lookup said no, the scan fallback heard nothing for 5.5 min, the lease expired).
    /// Returns false if there's no pod address.
    @discardableResult
    public func podLoanBeginTakeover(discover: Bool) -> Bool {
        guard let address = state.podState?.address else { return false }
        if discover {
            (podComms as? BlePodComms)?.beginLoanTakeover(podId: address)
        }
        return true
    }

    /// PODLOAN: the lender's reclaim escalation. A hand-back settle, a lost grant or the escape-hatch
    /// force-reclaim sits on a bare pending-connect that proved probabilistic against an idle pod
    /// (measured at 224 s on a settle); this arms the scan-adopt that actually finds it.
    /// No-op if there's no pod address. Compiles on both platforms; the watch has no caller.
    public func podLoanEscalateReclaim() {
        guard let address = state.podState?.address else { return }
        (podComms as? BlePodComms)?.escalateLoanReclaim(podId: address)
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

    // MARK: - PumpConnectionLendable (the phone half)

    /// PumpConnectionLendable: go LOOKING for the pod instead of waiting to hear it.
    ///
    /// The default reclaim re-arms a bare pending-connect, which the E4 work found to be
    /// probabilistic against an idle pod (caught a 578s-idle pod, missed a 518s-idle one), while
    /// the takeover's scan-and-adopt landed 4/4 from arbitrary state. The phone had no way to
    /// reach that path — the escalation was gated watchOS-only — so a hand-back settle sat on the
    /// bare connect: measured at 224.2s and 237.0s on consecutive evenings, on the escape hatch.
    /// Compiles on both platforms; the watch has no caller.
    @discardableResult
    public func escalateConnectionReclaim() -> String? {
        guard let address = state.podState?.address else {
            return "no pod address on this phone — nothing to escalate"
        }
        // Escalating IS the owner asserting the pod back: lift the session gate before dialling.
        setState { $0.podConnectionReleased = false }
        podLoanEscalateReclaim()
        return String(format: "scan-adopt armed for pod 0x%X", address)
    }


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
    /// them is on the pre-production list) — deleting outright would leave a bolus
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
    /// PumpConnectionLendable. The protocol default returns nil, which is what produced
    /// "ble: no diagnostics from the pump manager" on both phone settle-ceiling failures.
    public func connectionDiagnostics() -> String? {
        guard let ble = (podComms as? BlePodComms)?.bluetoothManager else { return nil }
        return "\(ble.loanBleDiagnostics) pod=\(podLoanConnectionStateDescription)"
    }

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
        setState { (state) in
            state.podConnectionReleased = true
        }
        (podComms as? BlePodComms)?.releaseConnection()
    }

    /// Resume bidding for the pod's BLE connection after a loan ends. The standing
    /// connect re-arms; the session re-establishes on next contact and the next
    /// status poll resynchronizes state.
    public func reclaimConnection() {
        // Another controller ran the pod while it was released, so the delivery status last
        // received here no longer describes it. The driver keeps that status only while the last
        // thing that happened to the pod was a reply it received (it clears it before every send,
        // and never persists it); a loan breaks that without a send or a relaunch. Cleared BEFORE
        // commands are let back in: nil makes tryToValidateComms read the pod first, and a running
        // temp basal is then cancelled before a new one is set. 2026-09-19: the first command
        // after a hand-back was a temp basal over the watch's running one — pod fault 0x31.
        (podComms as? BlePodComms)?.forgetLastDeliveryStatus()
        setState { (state) in
            state.podConnectionReleased = false
        }
        (podComms as? BlePodComms)?.rearmConnection()
    }

    /// The most recent EAP SQN resync as (when, how many sessions another controller made
    /// since our last contact) — the trust-chain fingerprint the seize and wake-resume
    /// ladders key on ("did someone else run this pod while I was dark"). nil = no resync
    /// this process. During ordinary loans the "other controller" is the expected one:
    /// the watch (from the phone's view) at reclaim, the phone (from the watch's view)
    /// at takeover — interpretation belongs to the caller, this is the primitive.
    public var podLoanLastSqnResync: (at: Date, foreignSessions: Int)? {
        (podComms as? BlePodComms)?.lastSqnResync.map { ($0.at, max(0, $0.pods - $0.ours)) }
    }

    /// PumpConnectionLendable's books-dirty primitive (phone mirror, R40(a)): the SQN
    /// resync stamp, protocol-shaped so Loop reads it without importing OmnipodKit.
    public var podLoanLastForeignSessionAt: Date? {
        podLoanLastSqnResync?.at
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
    /// When a CBErrorDomain#11 ("maximum number of connections") was last recorded, by either
    /// a refused connect or a disconnect. Timestamped separately from the trail because the
    /// trail entries carry no clock and the wedge test below needs "during THIS attempt".
    private static var _lastCode11At: Date?

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

    private static func isCode11(_ error: Error?) -> Bool {
        guard let ns = error as NSError? else { return false }
        return ns.domain == "CBErrorDomain" && ns.code == 11
    }

    public static func noteDisconnect(error: Error? = nil) {
        let d = describe(error), st = stateTag()
        lock.lock()
        if isCode11(error) { _lastCode11At = Date() }
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
        if isCode11(error) { _lastCode11At = Date() }
        _lastReason = d
        _lastCensus = census ?? _lastCensus
        _reasons.append("x\(d)@\(st)")
        if _reasons.count > 12 { _reasons.removeFirst() }
        lock.unlock()
    }

    public static func reset() {
        lock.lock()
        _lastConnectAt = nil; _lastDisconnectAt = nil; _connectCount = 0
        _lastReason = nil; _reasons = []; _lastCensus = nil; _lastDisconnectReason = nil
        _lastCode11At = nil
        lock.unlock()
    }

    // MARK: The BLE-wedge signature (2026-08-22, from the pure/SportMode line's field case)

    /// The decision as a pure function, so it is testable without touching the statics.
    ///
    /// A takeover attempt carries the WEDGE signature when either:
    ///  - a `CBErrorDomain#11` (connection limit) landed during the attempt — the system refused
    ///    a slot while the pod advertised beside us; or
    ///  - no connect EVER landed in the attempt. At takeover the pod is known-present (the phone
    ///    was talking to it seconds ago and released it for us), so a whole attempt with zero
    ///    didConnect is our radio's problem, not the pod's absence.
    ///
    /// Why the caller cares: CoreBluetooth connect requests are SYSTEM-level and outlive the app
    /// that issued them. A force-quit mid-retry leaves pending connects no living process can
    /// cancel; slots stay consumed and each retry round makes the radio blinder (measured on a
    /// real user's watch: refused-with-#11 escalated to zero adverts in 108 s across retries,
    /// while the phone reconnected to the same pod in 6.6 s; a WATCH Bluetooth toggle cleared it
    /// first try). So on a wedge, "try again" is actively harmful advice — the remedy is the
    /// toggle, and the failure text must say so.
    ///
    /// SCOPE: designed for the TAKEOVER failure path only. For reclaims mid-loan the second arm
    /// is too loose — a quiet pod also produces zero connects — so do not surface this verdict
    /// there; the `lastFail=` field in `summary(since:)` carries the raw evidence instead.
    public static func isWedge(lastCode11At: Date?, lastConnectAt: Date?, since: Date) -> Bool {
        if let c11 = lastCode11At, c11 >= since { return true }
        let connectedThisAttempt = lastConnectAt.map { $0 >= since } ?? false
        return !connectedThisAttempt
    }

    public static func wedgeSignature(since start: Date?) -> Bool {
        guard let start = start else { return false }
        lock.lock()
        let c11 = _lastCode11At, c = _lastConnectAt
        lock.unlock()
        return isWedge(lastCode11At: c11, lastConnectAt: c, since: start)
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
