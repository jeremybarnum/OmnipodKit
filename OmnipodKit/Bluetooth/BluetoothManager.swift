//
//  BluetoothManager.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/BluetoothManager.swift
//  Created by Randall Knutson on 10/10/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import LoopKit
import os.log
#if os(iOS)
import UIKit
#else
// watchOS has no UIKit. WatchKit carries the equivalent app-lifecycle notifications, which this
// file needs for foreground/background tracking — that tracking is not iOS-specific bookkeeping,
// it decides whether the pod link is held, so it is mapped rather than compiled out.
import WatchKit
#endif

enum BluetoothManagerError: Error {
    case bluetoothNotAvailable(CBManagerState)
}

extension BluetoothManagerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Bluetooth is powered off", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Bluetooth is resetting", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Bluetooth use is unauthorized", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Bluetooth use unsupported on this device", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            case .unknown:
                return LocalizedString("Bluetooth is unavailable for an unknown reason.", comment: "Error description for BluetoothManagerError.bluetoothNotAvailable(.unknown)")
            default:
                return String(format: LocalizedString("Bluetooth is unavailable: %1$@", comment: "The format string for BluetoothManagerError.bluetoothNotAvailable for unknown state (1: the unknown state)"), String(describing: state))
            }
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bluetoothNotAvailable(let state):
            switch state {
            case .poweredOff:
                return LocalizedString("Turn bluetooth on", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.poweredOff)")
            case .resetting:
                return LocalizedString("Try again", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.resetting)")
            case .unauthorized:
                return LocalizedString("Please enable bluetooth permissions for this app in system settings", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unauthorized)")
            case .unsupported:
                return LocalizedString("Please use a different device with bluetooth capabilities", comment: "recoverySuggestion for BluetoothManagerError.bluetoothNotAvailable(.unsupported)")
            default:
                return nil
            }
        }
    }
}

protocol OmniConnectionDelegate: AnyObject {

    /**
     Tells the delegate that a peripheral has been connected to

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralDidConnect(manager: PeripheralManager)

    /**
     Tells the delegate that a connected peripheral has been restored from session restoration

     - parameter manager: The manager for the peripheral that was connected
     */
    func omnipodPeripheralWasRestored(manager: PeripheralManager)


    /**
     Tells the delegate that a peripheral was disconnected

     - parameter peripheral: The peripheral that was disconnected
     */
    func omnipodPeripheralDidDisconnect(peripheral: CBPeripheral, error: Error?)

    /**
     Tells the delegate that a peripheral failed to connect

     - parameter peripheral: The peripheral that failed to connect
     */
    func omnipodPeripheralDidFailToConnect(peripheral: CBPeripheral, error: Error?)

    /// Write a message to Loop's persistent device log (survives background wakes / relaunch and is
    /// bundled in the issue report, unlike a live Console stream).
    func omnipodLogDeviceEvent(_ message: String)

    /// Tells the delegate a pump-provided heartbeat wake fired (a delayed-connect probe completed).
    /// The host (OmniPumpManager) turns this into pumpManagerBLEHeartbeatDidFire so Loop runs a cycle.
    func omnipodHeartbeatDidFire()

    /// Tells the delegate a pod alert was detected connectionlessly (from the advertisement). The host
    /// connects on demand and reads the real pod status, which surfaces the alert to Loop via the
    /// normal getPodStatus -> alertsChanged -> issueAlert path. `slots` is the decoded firing AlertSet.
    func omnipodDidDetectAlert(slots: AlertSet)

    /// PODLOAN: a loan takeover scan adopted the pod as `uuidString` (this device's own
    /// peripheral UUID). The delegate must record it as the pod's bleIdentifier so the
    /// connection/session path recognizes the peripheral.
    func omnipodDidAdoptLoanPod(uuidString: String)
}

extension OmniConnectionDelegate {
    func omnipodLogDeviceEvent(_ message: String) {}
    func omnipodHeartbeatDidFire() {}
    func omnipodDidDetectAlert(slots: AlertSet) {}
    func omnipodDidAdoptLoanPod(uuidString: String) {}   // PODLOAN: default no-op
}


class BluetoothManager: NSObject {

    weak var connectionDelegate: OmniConnectionDelegate?

    private let podType: PodType

    private let log = OSLog(category: "BluetoothManager")

    /// Isolated to `managerQueue`
    private var manager: CBCentralManager! = nil
    
    /// Isolated to `managerQueue`
    private var devices: [Omni] = []

    /// Last-seen DASH advertisement status word per peripheral, for connectionless alert detection.
    private var lastPodStatusWord: [String: Data] = [:]

    /// Re-wake quieting: true while a detected alert is being surfaced/active. A persisting alert keeps
    /// the pod advertising `C005`, so the alarm scan would keep waking us (harmless — re-processing is
    /// change-gated — but it churns the radio and nudges the heartbeat probe). We stop the alarm scan
    /// once an alert is surfaced and resume it when all alerts clear (via a connected status read).
    /// New faults are still caught within the heartbeat cadence while suppressed. managerQueue-isolated.
    private var alarmScanSuppressed = false

    /// Last advertisement timestamp per peripheral, to log inter-frame cadence (the DS-beacon-rate
    /// measurement the RE asked for — is there a usable periodic wake?).
    private var lastAdvSeen: [String: Date] = [:]

    /// Last full advert (svcUUIDs|mfg) device-logged per peripheral, so we record each DISTINCT advert
    /// once (captures the fault transition without flooding the device log).
    private var lastLoggedAdvKey: [String: String] = [:]

    /// Isolated to `managerQueue`
    private var discoveryModeEnabled: Bool = false

    /// Isolated to `managerQueue`
    private var autoConnectIDs: Set<String> = [] {
        didSet {
            updateConnections()
        }
    }

    /// PODLOAN: when a watch takes over a pod paired by another device (a loan), the
    /// phone's stored `bleIdentifier` is a per-device CoreBluetooth UUID that means
    /// nothing here — retrievePeripherals returns nothing. Instead we scan and adopt the
    /// pod by its advertised address (global). Set to the pod's address to arm takeover;
    /// cleared once adopted.
    /// The takeover/reclaim scan marker.
    ///
    /// INSTRUMENTED 2026-08-18 because it went nil underneath a live reclaim ladder and nobody
    /// could say who cleared it. connectOnDemand consults it (:881) to decide whether to leave a
    /// running scan alone or stop and replace it with its own 4-second one, so a silent clear
    /// hands the pod's discovery scan to a different owner mid-ladder. Three writers exist —
    /// `escalateLoanReclaim` on each platform, `cancelLoanScan`, and adoption — and the log had
    /// no way to tell them apart.
    private var loanTakeoverPodId: UInt32? = nil {
        didSet {
            guard oldValue != loanTakeoverPodId else { return }
            let from = oldValue.map { String(format: "0x%x", $0) } ?? "nil"
            let to = loanTakeoverPodId.map { String(format: "0x%x", $0) } ?? "nil"
            connectionDelegate?.omnipodLogDeviceEvent("[loan-scan] marker \(from) -> \(to) (\(loanScanMarkerReason))")
            // The watchdog lives exactly as long as the marker: armed scans with an expectation of
            // traffic are the only state it may police.
            if let id = loanTakeoverPodId { lastKnownLoanPodId = id }
            if loanTakeoverPodId != nil { armLoanScanWatchdog() } else { loanScanWatchdog?.cancel(); loanScanWatchdog = nil }
        }
    }

    /// The last pod id the loan marker ever held, and never cleared. The marker itself is nil for most
    /// of the gap BETWEEN reclaim ladders, and the advert census used to fall back to autoConnectIDs
    /// membership in that window — which `releaseConnection()` empties, so the census went blind at
    /// exactly the moment it was being read as evidence ("adverts=0 last=never" for two nights).
    /// The pod id is stable for the life of the pod, so matching against it is correct in every window
    /// and depends on nothing the release path mutates.
    private var lastKnownLoanPodId: UInt32?

    /// Why the marker last moved. Set immediately before each write; the didSet reports it.
    private var loanScanMarkerReason = "init"

    /// A pod whose advertisement matched the loan marker and which we are now connecting to.
    /// The marker stays armed until this peripheral actually connects — see the adopt block.
    private var pendingAdoptedLoanPod: String?

    /// The last connect failure, kept so a settle that never verifies can say WHY.
    private var lastConnectFailure: (id: String, code: String, at: Date)?

    // MARK: - Connect-intent ledger (instrumentation only — changes nothing)
    //
    // CoreBluetooth connect requests do not time out: a connect() that never resolves stays
    // pending until it is explicitly cancelled. The leading theory for the field Code=11
    // clusters ("maximum number of connections", hitting the pod AND the G7, cleared only by a
    // Bluetooth toggle) is that intents abandoned by central teardown accumulate at the system
    // level — recreateCentral drops the central commenting that this "clears the stalled
    // pending connect", and this ledger exists to test exactly that assumption.
    //
    // issued on every connect(); closed by didConnect / didFailToConnect / an explicit cancel;
    // ORPHANED when a central is dropped while intents are still open. If the theory is right,
    // orphaned climbs across a session and Code=11 clusters follow it; if orphaned stays flat
    // or Code=11 arrives without it, the theory is dead and we look elsewhere.
    private var openConnectIntents: Set<String> = []
    private var intentsIssued = 0
    private var intentsResolved = 0      // didConnect
    private var intentsRefused = 0       // didFailToConnect
    private var intentsCancelled = 0     // explicit cancelPeripheralConnection
    private var intentsOrphaned = 0      // open at central teardown — the leak candidate
    private var intentsSuppressed = 0    // duplicate connect() refused by us before CoreBluetooth saw it

    // ADVERT CENSUS (2026-08-19). The decisive gap: a reclaim ladder that fails today prints "14 reads,
    // never reconnected" and says NOTHING about what the radio heard. Every failed ladder in e132 issued
    // ZERO connects -- the pod never advertised, or we never heard it -- so the whole connect-side story
    // was about the wrong stage. A ladder that saw 3 adverts and did not connect is a DIFFERENT BUG from
    // one that saw 0, and right now those are indistinguishable.
    //
    // Cheap by construction: two Ints and a Date, written on a queue we are already on.
    /// Mirrors `OmniPumpManager.isConnectionReleased` down into the BLE layer, which otherwise has no
    /// concept of a loan at all. Diagnostics ONLY -- nothing branches on it. Set by the pump manager at
    /// release and reclaim; a connect issued while this is true is logged loudly and still allowed,
    /// because suppressing it would be a behaviour change dressed up as instrumentation.
    public var connectionReleasedForLoan = false

    /// Which callers tried to connect to a lent pod, and how often. Surfaced in `loanBleDiagnostics`
    /// so it rides the phone's existing 60 s census — the alarm itself goes to LoopKit's device-comms
    /// store, which is unreadable on the phone, and that is why the mechanism stayed unidentified for
    /// two days despite being instrumented.
    private var blockedWhileLoaned: [String: Int] = [:]

    var blockedSummary: String {
        blockedWhileLoaned.isEmpty ? "whileLoaned=none"
            : "whileLoaned=" + blockedWhileLoaned.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }

    /// The interlock, on by default. Off restores the pre-2026-08-19 behaviour (log only, still connect).
    static var loanInterlockEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.loanInterlockEnabled") as? Bool ?? true
    }

    // ANY-discovery census (H14 discriminator, 2026-08-20): a central that hears NOTHING AT ALL while
    // the Mac observer hears traffic is starved; one that hears others but not the pod is mis-filtered.
    // Different bugs, previously indistinguishable.
    /// Times we heard our own pod while the loan marker was armed but could NOT adopt it, because the
    /// peripheral was not `.disconnected`. Non-zero here means the pod was audible and we declined it.
    private var podHeardButNotAdopted = 0

    /// Which code path cancelled each connect. A connect we cancel ourselves mid-ladder is
    /// indistinguishable from a failed one in the outcome, but has an entirely different fix.
    private var cancelsByCaller: [String: Int] = [:]

    var cancelSummary: String {
        cancelsByCaller.isEmpty ? "cancels=none"
            : "cancels=" + cancelsByCaller.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }

    private var lastAnyDiscoveryAt: Date?
    private var anyDiscoveryCount = 0
    /// Baselines so the census reports THIS ladder rather than the session. See `advertCensus`.
    private var anyDiscoveryAtCensusReset = 0
    private var heardNotAdoptedAtCensusReset = 0
    /// The wildcard (unfiltered) probe: when it began, and the discovery count at that moment.
    /// Read live by `advertCensus`, so the ladder's own failure line carries the verdict.
    private var wildcardProbeStartedAt: Date?
    private var wildcardProbeBaseline = 0
    /// When each peripheral was first seen in a non-`.disconnected` state, so the adopt gate can tell
    /// a healthy in-flight adopt from a wedged one. See the `[adopt-gate]` line.
    private var nonDisconnectedSince: [String: Date] = [:]

    // SCAN WATCHDOG (H14 probe + remedy). Field 2026-08-20 01:15-01:21: settle scan-adopt armed,
    // isScanning=true, allowDuplicates=true, the Mac hearing the pod at -56 dBm every 2-7 s — and zero
    // didDiscover for six minutes. Whatever the root cause, stopScan + a fresh arm is correct under
    // every theory, and each firing is a measurement. Runs only while the loan marker is armed (the one
    // state in which the pod is expected free and advertising); 45 s of silence there is deafness — a
    // free pod advertises every ≤8 s.
    private var loanScanWatchdog: DispatchSourceTimer?
    private var scanWatchdogRestarts = 0

    private func armLoanScanWatchdog() {
        loanScanWatchdog?.cancel()
        let armedAt = Date()
        lastAnyDiscoveryAt = nil   // fresh baseline per arm; ages are per-window, never cumulative
        var restartsThisArm = 0
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        // CADENCE vs LADDER BUDGET (2026-08-20). This was 20 s / 20 s / 45 s of silence, which made
        // the watchdog STRUCTURALLY UNABLE to fire inside the failure it was built for: a reclaim
        // ladder is 14 reads x ~2 s = 28.2 s, so the earliest possible firing landed ~17 s after the
        // ladder had already given up and torn the marker down. That is the whole reason the wrist
        // read `scanWD=0` during failing reclaims — not "no deafness detected" but "never checked".
        // 5 s cadence / 15 s threshold fires at 15-20 s into a 28 s ladder, leaving 8-13 s for a
        // restarted scan to hear the pod and adopt it. 15 s is not arbitrary: a free pod advertises
        // every <=8 s, so 15 s of silence on an armed scan is already two missed windows.
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            // SCOPE (2026-08-20 fix): this used to require `loanTakeoverPodId != nil`, so it only
            // policed during an armed takeover. The marker is nil for most of the gap BETWEEN reclaim
            // ladders — which is exactly when this morning's failures happened, and why scanWD=0 was
            // read as "no deafness" when it actually meant "never checked". Police whenever we are
            // SCANNING FOR the pod at all: an armed scan that hears nothing is the condition,
            // regardless of which path armed it.
            guard let self, self.manager.isScanning else { return }
            // A CONNECTED POD DOES NOT ADVERTISE (2026-08-20 fix). The first cut policed silence
            // whenever the marker was armed — but the E4 reclaim path arms it while the pod is
            // already connected, so the absence of didDiscover was CORRECT and the watchdog read it
            // as deafness: 69 spurious firings in one session, every 20 s, churning stopScan + arm
            // for nothing. Only police while genuinely waiting to DISCOVER something.
            let podBusy = self.devices.contains {
                $0.manager.peripheral.state == .connected || $0.manager.peripheral.state == .connecting
            }
            guard !podBusy else { return }
            // ...and measure from when THIS arm began, not from a stale session-wide stamp; the same
            // bug let the reported age accumulate to 7777s across unrelated windows.
            let last = max(self.lastAnyDiscoveryAt ?? armedAt, armedAt)
            let age = -last.timeIntervalSinceNow
            guard age > 15 else { return }
            // Bounded. A restart that does not help must not become a 5 s churn loop for the life of
            // the arm — three attempts inside one ladder is already the whole budget, and beyond that
            // the diagnosis is "restarting does not fix it", which is a finding, not a reason to keep
            // hammering the radio.
            guard restartsThisArm < 3 else { return }
            self.scanWatchdogRestarts += 1
            self.connectionDelegate?.omnipodLogDeviceEvent(
                "[scan-watchdog] DEAF SCAN: isScanning=true but no didDiscover of ANYTHING for \(Int(age))s while scanning — stopScan + fresh arm (restart #\(self.scanWatchdogRestarts), \(restartsThisArm + 1)/3 this arm, filter=\((restartsThisArm + 1) % 2 == 1 ? "WILDCARD probe" : "pod service"))")
            // WILDCARD PROBE (2026-08-20). A filtered scan cannot tell us whether the radio is
            // receiving: didDiscover only fires for peripherals advertising the pod service, so a deaf
            // central and a pod whose frames never match look the same from inside. Every odd restart
            // therefore re-arms with NO service filter. Hearing anything at all proves the central is
            // receiving, which moves the fault to the frames or the filter and takes deafness off the
            // table; hearing nothing unfiltered, in a room with any BLE traffic in it, is deafness
            // demonstrated rather than inferred.
            //
            // It is not only a probe. A wildcard scan is a strict SUPERSET of the filtered one — the
            // adopt path matches the address out of the parsed advertisement and does not care which
            // filter surfaced it — so if the service filter is itself wrong for this pod, the wildcard
            // arm discovers it and the takeover recovers. Diagnostic and candidate fix in one.
            restartsThisArm += 1
            let wildcard = restartsThisArm % 2 == 1
            if wildcard {
                self.wildcardProbeBaseline = self.anyDiscoveryCount
                self.wildcardProbeStartedAt = Date()
            } else {
                self.wildcardProbeStartedAt = nil
            }
            self.manager.stopScan()
            self.manager.scanForPeripherals(withServices: wildcard ? nil : [self.podScanServiceUUID],
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        t.resume()
        loanScanWatchdog = t
    }

    private var ownPodAdvertsSeen = 0
    private var ownPodAdvertLastAt: Date?
    private var ownPodAdvertLastRSSI: Int?

    /// Interval between the last two adverts we heard, in seconds. H7 (2026-08-19) — "the pod's idle
    /// advertising interval exceeds our 28 s ladder budget" — could NOT be scored from the first
    /// census because the ladder stops as soon as it connects, so the counts measured how long we
    /// listened rather than how often the pod speaks. This is uncensored: it keeps updating whether or
    /// not a ladder is running, so a steady-state reading answers the question directly.
    private var lastAdvertGap: TimeInterval?

    /// Adverts heard from OUR pod since `resetAdvertCensus()`, for the ladder to print on completion.
    /// Any-queue safe: plain value reads, no locking, diagnostics only.
    public var advertCensus: String {
        let age = ownPodAdvertLastAt.map { String(format: "%.0fs", -$0.timeIntervalSinceNow) } ?? "never"
        let gap = lastAdvertGap.map { String(format: "%.1fs", $0) } ?? "-"
        // THE ONE BIT THE LADDER COULD NOT REPORT (2026-08-20). Field e13:00:16: scan armed at
        // 12:59:51.181, ladder ran 28.2 s / 14 reads, peripheral `.disconnected` throughout, verdict
        // "never reconnected" — while the Mac scanner heard that same pod every 2-7 s. Two
        // incompatible stories fit that line equally well and the log could not separate them:
        // the central heard NOTHING (deaf scan, wrong filter, radio wedged), or it heard the pod fine
        // and every frame was rejected at a gate. `adverts=` cannot arbitrate, because it counts only
        // frames that ALREADY passed the address match.
        //
        // `anySeen` counts didDiscover callbacks for ANY device since the ladder began.
        //   anySeen>0, adverts=0  → frames arrived and the address match rejected them.
        //   adverts>0, no adopt   → we heard our pod and failed to connect: connect-side fault.
        //
        // `anySeen=0` is DELIBERATELY NOT read as deafness. The takeover scan is FILTERED on the pod's
        // service UUID with allowDuplicates, so the only thing that can raise didDiscover at all is a
        // pod — which makes "the central is deaf" and "our pod's frames are not arriving/matching"
        // produce an identical anySeen=0. Separating those needs an UNFILTERED scan, which is what the
        // watchdog's wildcard probe runs; `wildcard=heard/elapsed` below is that answer, and it is the
        // only term here that can speak to deafness.
        // `skipped` is the adopt gate's own count over the same window, so a ladder that heard the pod
        // and refused to adopt it says so on the line that declares the failure.
        let anySeen = anyDiscoveryCount - anyDiscoveryAtCensusReset
        let skipped = podHeardButNotAdopted - heardNotAdoptedAtCensusReset
        let probe = wildcardProbeStartedAt.map {
            String(format: " wildcard=%d/%.0fs", anyDiscoveryCount - wildcardProbeBaseline, -$0.timeIntervalSinceNow)
        } ?? ""
        return "adverts=\(ownPodAdvertsSeen) anySeen=\(anySeen) skipped=\(skipped)\(probe) "
            + "last=\(age) rssi=\(ownPodAdvertLastRSSI.map(String.init) ?? "-") gap=\(gap)"
    }

    /// Zero the advert census. Called at ladder start so the count is per-ladder, not per-session.
    public func resetAdvertCensus() {
        managerQueue.async {
            self.ownPodAdvertsSeen = 0
            self.ownPodAdvertLastAt = nil
            self.ownPodAdvertLastRSSI = nil
            self.anyDiscoveryAtCensusReset = self.anyDiscoveryCount
            self.heardNotAdoptedAtCensusReset = self.podHeardButNotAdopted
            // Per-ladder, like everything else here — a probe left over from the LAST ladder would
            // print `wildcard=0/900s` against this one and read as a fresh negative result.
            self.wildcardProbeStartedAt = nil
        }
    }

    /// Registers a connect intent and reports whether the caller should actually issue `connect()`.
    ///
    /// FIELD 2026-08-19 12:56:53.974. `timedConnect` and `adopt-retry` both issued `connect()` for the
    /// same pod in the SAME MILLISECOND; CoreBluetooth answered `CBErrorDomain Code=11` ("maximum
    /// number of connections"), and a single connect 0.75 s later succeeded against an unchanged
    /// system. The ledger cleared the two competing explanations that session: `ORPHANED=1` was
    /// standing across connects that SUCCEEDED (so a leaked intent does not hold a slot), and the G7
    /// had disconnected 2.3 s earlier (so it was not holding the link). What was left was our own
    /// duplicate.
    ///
    /// A pending connect is already doing everything a duplicate would — `connect()` has no timeout
    /// and stays live until cancelled — so a second one buys nothing and can cost a refusal.
    /// G7SensorKit learned this as the #101 churn fix (`G7BluetoothManager.handleDiscoveredPeripheral`
    /// returns early on `.connecting`); the pod path never got the equivalent. This is that guard.
    ///
    /// Suppression is counted, not silent: if `SUPPRESSED` climbs while reclaims still fail, the
    /// duplicate was not the disease and the next suspect is watchOS releasing a slot lazily.
    /// `force` is for the deliberate cancel-then-reconnect (`freshConnect`), whose whole purpose is to
    /// replace a link that may still read `.connected`/`.disconnecting` for a moment after the cancel.
    /// Suppressing it would defeat the stale-flush; ignoring the return value instead would issue a
    /// connect the ledger never recorded, and the ledger is the instrument. So: register, don't block.
    private func noteConnectIssued(_ peripheral: CBPeripheral, via: String, force: Bool = false) -> Bool {
        let id = peripheral.identifier.uuidString
        // `.connecting` is checked alongside our own book because the peripheral can be in flight from
        // a path that never registered an intent, and CoreBluetooth counts that state either way.
        //
        // `.connected` is deliberately NOT guarded. Connecting an already-connected peripheral makes
        // CoreBluetooth re-deliver didConnect immediately, and a state machine somewhere may be leaning
        // on that re-delivery; this file compiles into the PHONE as well as the watch, so suppressing it
        // would risk wedging the phone's pod link to fix a watch symptom. The observed defect was two
        // connects racing while one was IN FLIGHT — that is what this guards, and no more.
        if !force, openConnectIntents.contains(id) || peripheral.state == .connecting {
            intentsSuppressed += 1
            let why = peripheral.state == .connecting ? "connect in flight" : "intent already open"
            connectionDelegate?.omnipodLogDeviceEvent(
                "[intent] connect via \(via) SUPPRESSED (\(why)) → \(intentSummary)")
            return false
        }
        // LOAN CONTENTION ALARM (2026-08-19). OmnipodKit has no concept of a loan -- isolation is
        // achieved indirectly, by emptying autoConnectIDs/devices so the automatic paths find nothing.
        // That covers the paths that consult them; it cannot cover a connect arriving any other way,
        // because there is no flag to consult. On 2026-08-19 the phone reported `link up +0.0s` after
        // 110 s of silence during a loan the watch was failing to take over -- a link it should not
        // have had, with no record of how it got one. This line is that record.
        // THE LOAN INTERLOCK (2026-08-19). Measured that day: the PHONE connected to the pod every
        // 2-3 minutes for the whole loan, released=true throughout, every connect SUCCEEDING -- and a
        // pod in a connection does not advertise, so the watch's reclaim ladders heard nothing and
        // failed. Phone ON: 0/13 ladders succeeded. Phone OFF: 7/9, flipping 44 s after power-down and
        // reverting 11 s after power-up.
        //
        // Isolation used to be INDIRECT -- empty autoConnectIDs and devices so the automatic paths find
        // nothing -- which covers the paths that consult them and cannot cover any other, because there
        // was no flag to consult. This is that flag, enforced.
        //
        // SAFETY. Every path that legitimately wants the pod back clears the flag FIRST:
        // reclaimConnection() sets podConnectionReleased = false before rearmConnection(), and the
        // escalation (the phone's escape hatch for a stranded pod) clears it in escalateLoanReclaim.
        // So this can refuse a contending connect but never a recovery.
        //
        // Reversible without a rebuild: set OmnipodKit.loanInterlockEnabled = false in UserDefaults.
        // iOS ONLY -- and this gate is the whole lesson. `releaseConnection()` means two DIFFERENT
        // things on the two devices: on the PHONE it means "I have lent this pod away"; on the WATCH
        // it is the routine POST-DOSE release, "done dosing for a moment, still mine". Setting one
        // flag from both made the watch refuse its OWN reconnects after its first dose — 18 REFUSED
        // takeover connects in the field within minutes of shipping it (2026-08-19 21:2x, timedConnect
        // and adopt-retry), stalling the ladder with didConnect never (n=0). The phone is the only
        // device that lends, so it is the only device this may guard.
        #if os(iOS)
        if connectionReleasedForLoan {
            blockedWhileLoaned[via, default: 0] += 1
            connectionDelegate?.omnipodLogDeviceEvent(
                "[intent] ** CONNECT WHILE ON LOAN ** via \(via) — \(BluetoothManager.loanInterlockEnabled ? "REFUSED" : "allowed (interlock off)") · \(blockedSummary)")
            if BluetoothManager.loanInterlockEnabled { return false }
        }
        #endif
        openConnectIntents.insert(id)
        intentsIssued += 1
        connectionDelegate?.omnipodLogDeviceEvent("[intent] connect via \(via) → \(intentSummary)")
        return true
    }

    /// Attributes a cancel of a LIVE link — one where the connect intent was already closed as
    /// `resolved` by didConnect, so `noteConnectClosed` is a no-op (its `guard remove != nil` returns
    /// immediately) and `cancels=` never names the site.
    ///
    /// Two sites were silently unattributed for this reason: `didConnect-dupe` (the delayed-probe wake
    /// that connects and immediately hangs up) and `enterBackground` (which cancels a `.connected`
    /// peripheral). Both are real hang-ups the ladder needs to see. `cancels=` is the instrument for
    /// "who let go of the pod", and an instrument with two holes in it answers `cancels=none` to a
    /// question whose true answer was one of the two.
    private func noteLinkTornDown(_ peripheral: CBPeripheral, by site: String) {
        cancelsByCaller[site, default: 0] += 1
        connectionDelegate?.omnipodLogDeviceEvent("[intent] live link torn down by \(site) → \(intentSummary)")
    }

    private func noteConnectClosed(_ peripheral: CBPeripheral, how: String) {
        let id = peripheral.identifier.uuidString
        guard openConnectIntents.remove(id) != nil else { return }
        switch how {
        case "resolved": intentsResolved += 1
        case "refused": intentsRefused += 1
        default:
            intentsCancelled += 1
            // WHICH call site cancelled (2026-08-20). Field L10: the ladder HEARD the pod (6 adverts,
            // last 6 s before it expired, -81 dBm), issued timedConnect, and the connect was then
            // CANCELLED BY US — not refused, not failed. The ledger recorded only "cancelled", and
            // there are nine call sites that can do it, so the culprit was unnameable. `how` now
            // carries the site, exactly as `via:` does for connects.
            if how.hasPrefix("cancelled:") { cancelsByCaller[String(how.dropFirst(10)), default: 0] += 1 }
        }
        connectionDelegate?.omnipodLogDeviceEvent("[intent] \(how) → \(intentSummary)")
    }

    var intentSummary: String {
        "open=\(openConnectIntents.count) issued=\(intentsIssued) ok=\(intentsResolved) refused=\(intentsRefused) cancelled=\(intentsCancelled) ORPHANED=\(intentsOrphaned) suppressed=\(intentsSuppressed)"
    }

    /// One line of BLE state for the loan's diagnostics.
    ///
    /// The phone's settle printed "ble: no diagnostics from the pump manager" on both of its
    /// ceiling failures (e124, e127) because `connectionDiagnostics()` has a default returning
    /// nil and nothing overrode it. So at the exact moment the phone could not reach a pod that
    /// nothing else was holding, its BLE layer said nothing at all — and any theory about the
    /// phone half was unfalsifiable.
    ///
    /// Reports the things that distinguish the candidates: whether the radio is on, whether we
    /// are scanning, how many peripherals we are holding, what the pod's own peripheral thinks,
    /// and the last connect refusal. `CBErrorDomain#11` here means the system connection table is
    /// full, which is a host state and not a pod fault — and it is the one a Bluetooth toggle
    /// clears.
    var loanBleDiagnostics: String {
        let radio: String
        switch manager.state {
        case .poweredOn:   radio = "on"
        case .poweredOff:  radio = "OFF"
        case .resetting:   radio = "resetting"
        case .unauthorized: radio = "unauthorized"
        case .unsupported: radio = "unsupported"
        case .unknown:     radio = "unknown"
        @unknown default:  radio = "unknown(\(manager.state.rawValue))"
        }
        let failure = lastConnectFailure.map {
            String(format: "lastFail=%@ @%.0fs ago", $0.code, Date().timeIntervalSince($0.at))
        } ?? "lastFail=none"
        return "radio=\(radio) scanning=\(manager.isScanning) devices=\(devices.count) intents[\(intentSummary)] "
            + "autoConnect=\(autoConnectIDs.count) marker=\(loanTakeoverPodId.map { String(format: "0x%x", $0) } ?? "nil") "
            + "pendingAdopt=\(pendingAdoptedLoanPod ?? "none") \(failure) \(advertCensus) anyDiscover=\(anyDiscoveryCount) heardNotAdopted=\(podHeardButNotAdopted) scanWD=\(scanWatchdogRestarts) \(cancelSummary) \(blockedSummary)"
    }

    /// The uuidPdmId is set after pairing...
    private var uuidPdmId: UInt32? = nil

    /// PODLOAN: arm loan-takeover — scan for the pod with this address and adopt the
    /// peripheral this device discovers (its own CoreBluetooth UUID), rather than the
    /// foreign identifier from the granted pod state.
    func beginLoanTakeover(podId: UInt32) {
        managerQueue.async {
            self.loanScanMarkerReason = "beginLoanTakeover"
            self.loanTakeoverPodId = podId
            if self.manager.state == .poweredOn {
                self.log.default("PODLOAN: begin takeover scan for pod 0x%x", podId)
                // RE-ARM, don't skip. A scan is almost always already running by now — the idle
                // fault-watch, armed microseconds earlier when the manager came up, filtering on
                // C00A/…02. `if !isScanning` therefore skipped this call every time and left the
                // takeover listening for a FAULT advertisement a healthy pod never sends, which is
                // the whole reason a takeover could never find its pod. The filter has to be
                // replaced, so stop the old scan first: scanForPeripherals does not merge filters,
                // and a running scan is not restarted by calling it again.
                if self.manager.isScanning {
                    self.log.default("PODLOAN: stopping the idle scan to re-arm with the takeover filter")
                    self.manager.stopScan()
                }
                self.startScanning()
            } else {
                // The common case: takeover arms milliseconds after the central is
                // created, before it reaches poweredOn. centralManagerDidUpdateState
                // starts the scan (its condition consults loanTakeoverPodId).
                self.log.default("PODLOAN: takeover armed for pod 0x%x; scan starts at poweredOn", podId)
            }
        }
    }

    /// The O5 changes its service advertisement uuid from using FFFFFFFE the pdmId after pairing.
    /// This func is called to set this value to be used in uuid after pairing and with a nil (or 0) to reset.
    func setUuidPdmId(_ pdmId: UInt32?) {
        managerQueue.async {
            if let pdmId = pdmId, pdmId != 0 {
                self.log.bleDebug("Setting uuidPdmId to 0x%x", pdmId)
                self.uuidPdmId = pdmId
            } else {
                self.uuidPdmId = nil
            }
        }
    }

    /// Isolated to `managerQueue`
    private var hasDiscoveredAllAutoConnectDevices: Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        return autoConnectIDs.isSubset(of: devices.map { $0.manager.peripheral.identifier.uuidString })
    }

    // MARK: - Synchronization
    private let managerQueue = DispatchQueue(label: "com.OmnipodKit.bluetoothManagerQueue", qos: .unspecified)

    /// Per-instance ID so multiple centrals under the shared "com.OmnipodKit" restore identifier
    /// can be told apart in the log. INIT/DEINIT + the central callbacks are all tagged with it:
    /// N distinct INITs with no matching DEINITs = leaked centrals (the suspected pairing-bug root).
    let instanceID = String(UUID().uuidString.prefix(8))

    /// Log each distinct pod advertisement ([ADV] → device log) so field Issue Reports capture what the
    /// pod broadcasts — raw material for decoding more fault/alert states — and enable allowDuplicates on
    /// the fallback monitor scan. Kept in production.
    static var advertisementMonitorEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.advertisementMonitorEnabled") as? Bool ?? true
    }

    /// The shipped "normally disconnected" model: the pod is NOT held connected; PeripheralManager
    /// connects on demand for each session and disconnects when idle, and we alarm-scan while
    /// disconnected. Every command pays a (fast fresh-discovery) connect first.
    static var connectOnDemandEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.connectOnDemandEnabled") as? Bool ?? true
    }

    /// Low-power fault-watch: the idle scan filters on the DASH FAULT service UUID(s) — `alarmServiceUUIDs`
    /// = [C00A] — with allowDuplicates OFF, so iOS wakes us only when the pod's 2nd service UUID flips to
    /// the fault value (C005→C00A). C00A isn't advertised in normal operation, so a fault is a fresh
    /// discovery → a fast (<1 min) background wake that survives suspension via State Restoration; zero
    /// wakes otherwise. Alerts (no service-UUID change) are NOT caught here — the heartbeat probe surfaces
    /// those. Coexists with the StartDelay heartbeat probe. See DASH_BEACON_FINDINGS.md.
    static var lowPowerMonitorEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.lowPowerMonitorEnabled") as? Bool ?? true
    }

    /// Master switch for the IDLE scan (startScanning). ON = run the C00A fault listener while
    /// disconnected (connectionless fault detection). OFF = no idle scan. Command connects use
    /// fresh-discovery either way; this only governs the idle listener. The idle scan COEXISTS with the
    /// StartDelay heartbeat probe — both run while idle: the probe provides the periodic heartbeat/alert
    /// wake, the scan provides fast fault wakes.
    static var scanningEnabled: Bool {
        UserDefaults.standard.object(forKey: "OmnipodKit.scanningEnabled") as? Bool ?? true
    }


    /// Fallback start delay (seconds) for the delayed-connect probe when Loop hasn't supplied a heartbeat
    /// schedule (no `heartbeatTargetDate`). Normally the delay is computed from the CGM reading schedule —
    /// see `issueDelayedConnectProbe`. Note the real wake lands at StartDelay + an iOS reacquisition tail
    /// (~40s observed), so 300 → wake ~340s.
    static var delayedConnectProbeSeconds: Int {
        (UserDefaults.standard.object(forKey: "OmnipodKit.delayedConnectProbeSeconds") as? Int) ?? 300
    }

    /// Buffer (seconds) added after the next expected CGM reading when scheduling the heartbeat, so a
    /// remote/network CGM value has time to be fetched and stored before the heartbeat drives a Loop cycle.
    static var heartbeatBufferSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.heartbeatBufferSeconds") as? Double) ?? 20
    }

    /// Floor (seconds) for the computed StartDelay, so a stale/overdue reading target can't produce a
    /// near-zero delay that immediately reconnects. Overdue targets retry at this cadence.
    static var heartbeatMinDelaySeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.heartbeatMinDelaySeconds") as? Double) ?? 60
    }

    /// Backoff (seconds) before re-arming the StartDelay probe after a connect FAILURE, so a
    /// persistently-failing connect can't re-issue in a tight loop.
    static var heartbeatFailureBackoffSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.heartbeatFailureBackoffSeconds") as? Double) ?? 30
    }

    /// Idle-disconnect delay (seconds) after the last command's session. Kept SHORT so that in the
    /// background a heartbeat-wake cycle disconnects promptly — before iOS suspends the app — which lets
    /// the StartDelay probe re-arm (it needs a DISCONNECTED pod). A long delay let the app suspend with the
    /// link still up and the timer frozen, so the probe never re-armed → a ~12-min missed loop (tester
    /// report). Foreground / Pod Keep Alive hold the connection separately (`shouldHoldConnection`), so this
    /// only takes effect while backgrounded. The status→dose burst still shares one connection: each session
    /// resets `idleStart`, so the disconnect lands this many seconds after the LAST command.
    static var idleDisconnectSeconds: TimeInterval {
        (UserDefaults.standard.object(forKey: "OmnipodKit.idleDisconnectSeconds") as? Double) ?? 4
    }

    /// Candidate DASH alarm-state service UUIDs to filter on in low-power mode.
    /// - `C005`: CONFIRMED 16-bit alarm 2nd-UUID on this pod (expiration reminder). Extend as more
    ///   alert/alarm types are captured.
    /// - `C00A`: CONFIRMED fault 2nd-UUID (captured occlusion 0x14 — the pod's 2nd service UUID went
    ///   C001(normal)→C005(alert)→C00A(fault)). Include it so a fault wakes the low-power scan.
    /// C00A-ONLY fault scan (the adopted design; validated 2026-07-08). scanForPeripherals(withServices:)
    /// is an OR filter, so including C005 kept the pod perpetually matched (a reminder is always
    /// configured → C005 always advertised) → iOS treated it as already-discovered and COALESCED the
    /// C005→C00A re-discovery (~7min deep-idle fault latency measured). Filtering on C00A ONLY means the
    /// pod does not match during normal operation, so a fault's C005→C00A flip is a genuinely NEW
    /// discovery — the event iOS wakes a suspended app for — giving <1min proactive deep-idle fault
    /// detection (measured, probe off). We forgo C005-based connectionless ALERT detection, which never
    /// worked in deep idle anyway (mfg-only change, no UUID change to wake on); alerts are surfaced by
    /// the heartbeat probe (~5min) and the foreground keep-alive connection.
    static let alarmServiceUUIDs: [CBUUID] = [
        CBUUID(string: "C00A"),
    ]

    /// Connect-request timestamps (by peripheral UUID) for measuring connect latency in didConnect.
    private var connectRequestedAt: [String: Date] = [:]

    /// Delayed-connect probe: true while a StartDelay connect is in flight (issued, awaiting didConnect),
    /// so didDiscover doesn't re-issue during the wait; the issue timestamp measures the true delay.
    private var delayedProbeInFlight = false
    private var delayedProbeIssuedAt: Date?
    /// StartDelay (seconds) of the probe currently in flight, for latency logging in didConnect.
    private var delayedProbeDelay: TimeInterval?

    /// Target time for the next pump-provided heartbeat: the probe's StartDelay is computed so the wake
    /// lands no earlier than this. Recomputed from Loop's `PumpHeartbeatRequest` each time it updates
    /// (i.e. after each CGM reading), so the cadence tracks the actual reading schedule. nil = no schedule
    /// supplied (fall back to `delayedConnectProbeSeconds`). managerQueue-isolated.
    private var heartbeatTargetDate: Date?

    /// The reading interval last supplied via `setHeartbeatRequest`, used to advance a chronically-stale
    /// target so it doesn't collapse onto the floor. managerQueue-isolated.
    private var heartbeatInterval: TimeInterval?

    /// When `heartbeatTargetDate` was last (re)set. A host that supplies a live reading schedule refreshes
    /// this every reading; a host that only calls the legacy `setMustProvideBLEHeartbeat` sets it once. That
    /// distinction is how `issueDelayedConnectProbe` tells a briefly-late reading (retry at the floor) from a
    /// target no host is refreshing (advance it). managerQueue-isolated.
    private var heartbeatTargetSetAt: Date?

    /// True while a real command's connect owns the link (connect-on-demand). The heartbeat probe and
    /// a command connect must never be outstanding together — a command preempts the probe and, while
    /// it's active, the probe is neither armed nor allowed to claim a didConnect. Cleared on the
    /// idle-disconnect (going idle) so the probe re-arms. managerQueue-isolated.
    private var commandConnectInFlight = false

    /// Set when a delayed-connect probe completes (a heartbeat wake): we disconnect the wake link and
    /// fire the heartbeat from the resulting didDisconnect, so Loop's commands start from a clean
    /// disconnected state via connect-on-demand. managerQueue-isolated.
    private var pendingHeartbeatFire = false

    /// True while the app is foregrounded. While foreground we keep the pod connected (skip the
    /// idle-disconnect, reconnect on an unintended drop) so connection-gated UI (test beeps, etc.) is
    /// live and in-app commands are instant. On background we disconnect and resume the heartbeat probe.
    private var isAppForeground = false
    /// Cross-queue read for PeripheralManager's idle-disconnect (benign bool race, like everForeground).
    var appIsForeground: Bool { isAppForeground }

    /// True when the pod should be HELD connected rather than idle/background-disconnected — the gate that
    /// suppresses connect-on-demand's disconnects. True while the app is foregrounded (foreground
    /// keep-alive), OR whenever a *background* Pod Keep Alive mode (silentTune / rileyLink — DASH only) is
    /// selected. Those modes exist for iPhone 16/17e + InPlay (Atlas) DASH pods where a disconnect→reconnect
    /// is unreliable, so the pod must stay connected and the keep-alive's periodic status refresh maintains
    /// the link. When Pod Keep Alive is `.disabled` (the default) OR `.whenOpen`, this collapses to exactly
    /// `isAppForeground` — i.e. no change from the validated connect-on-demand behavior. Read from
    /// managerQueue and cross-queue by PeripheralManager (benign bool race, like appIsForeground).
    var shouldHoldConnection: Bool {
        if isAppForeground { return true }
#if os(iOS)
        return podType.isDash && Storage.shared.podKeepAlive.value.keepsPodConnectedInBackground
#else
        // watchOS: the background Pod Keep Alive modes are an iOS-only user setting — `Storage`
        // lives in the UI layer, which the watch framework deliberately does not link. This
        // therefore collapses to exactly `isAppForeground`, which is both the validated
        // connect-on-demand behavior and precisely what an iPhone does with Pod Keep Alive at
        // its `.disabled` default. A watch host that needs the link held across background
        // holds it through its own session keep-alive, not through this setting.
        return false
#endif
    }

    /// True once this PROCESS has ever been foregrounded. A [delayedConnect] with everFg=false means
    /// iOS ran this process entirely in the background — proof of a background wake/relaunch the user
    /// did NOT initiate (a manual open would have foregrounded it). Set on the main queue via a
    /// lifecycle observer; read from managerQueue for logging (benign race for a bool).
    private var everForeground = false

    /// Runtime heartbeat request (from PumpManager.setMustProvideBLEHeartbeat via BlePodComms). When
    /// true, run the delayed-connect loop so the pump provides periodic background wakes — used only
    /// when the CGM can't (network CGM). Normally false: stay disconnected + alarm-scan, connect on
    /// demand. managerQueue-isolated.
    private var heartbeatEnabled = false

    /// The delayed-connect (StartDelay) heartbeat probe runs when Loop asks the pump to provide the BLE
    /// heartbeat (`heartbeatEnabled`, via PumpManager.setBLEHeartbeatRequest) AND we are NOT holding the pod
    /// connected. CBConnectPeripheralOptionStartDelayKey is a background-only mechanism — iOS ignores the
    /// delay while the app is foreground, so a foreground probe connects immediately, is treated as a wake,
    /// disconnects, re-arms, and churns. When we're holding the connection (foreground, or a background Pod
    /// Keep Alive mode) the pod is already connected and the heartbeat rides that link; the probe would
    /// fight it. Isolated to managerQueue (all probe call sites run there).
    private var delayedConnectProbeActive: Bool {
        heartbeatEnabled && !shouldHoldConnection
    }

    /// Enable/disable and schedule the pump-provided heartbeat (delayed-connect loop). Driven by
    /// PumpManager.setBLEHeartbeatRequest. `request == nil` disables it (fall back to connect-on-demand +
    /// alarm scan). When non-nil, the next-heartbeat target is (lastCGMReading + expectedInterval + buffer);
    /// this is refreshed on every call (e.g. after each CGM reading) so the cadence tracks the reading
    /// schedule. Refreshing the target while a probe is already in flight does NOT churn it — the in-flight
    /// probe completes and the next one picks up the new target.
    func setHeartbeatRequest(_ request: PumpHeartbeatRequest?) {
        managerQueue.async {
            let enabled = request != nil
            if let request = request {
                let base = request.lastCGMReadingDate ?? Date()
                self.heartbeatTargetDate = base.addingTimeInterval(request.expectedCGMReadingInterval + BluetoothManager.heartbeatBufferSeconds)
                self.heartbeatInterval = request.expectedCGMReadingInterval
                self.heartbeatTargetSetAt = Date()
            } else {
                self.heartbeatTargetDate = nil
                self.heartbeatInterval = nil
                self.heartbeatTargetSetAt = nil
            }
            let wasEnabled = self.heartbeatEnabled
            self.heartbeatEnabled = enabled
            let pid = ProcessInfo.processInfo.processIdentifier
            let targetDesc = self.heartbeatTargetDate.map { String(format: "%.0fs", $0.timeIntervalSinceNow) } ?? "-"
            self.log.default("[heartbeat] pid=%{public}d providesHeartbeat=%{public}@ targetIn=%{public}@", pid, String(enabled), targetDesc)
            self.connectionDelegate?.omnipodLogDeviceEvent("[heartbeat] pid=\(pid) providesHeartbeat=\(enabled) targetIn=\(targetDesc)")
            if enabled {
                // (Re)arm against the known autoconnect pod (nil if no active pod — don't probe a
                // stale/discarded device). No-ops if a probe is already in flight.
                if let peripheral = self.keepAlivePeripheral {
                    self.issueDelayedConnectProbe(peripheral)
                }
            } else if wasEnabled {
                // Stop the loop; fall back to connect-on-demand + alarm scan. Don't drop a live connection
                // while we're holding it (foreground keep-alive, or a background Pod Keep Alive mode).
                self.delayedProbeInFlight = false
                if !self.shouldHoldConnection {
                    for device in self.devices where device.manager.peripheral.state != .disconnected {
                        self.noteConnectClosed(device.manager.peripheral, how: "cancelled:heartbeatRequest")
                        self.manager.cancelPeripheralConnection(device.manager.peripheral)
                    }
                }
                self.resumeScanIfNeeded()
            }
        }
    }

    /// Stamp the connect time and issue the connect, so didConnect can report the latency.
    private func timedConnect(_ peripheral: CBPeripheral) {
        if connectRequestedAt[peripheral.identifier.uuidString] == nil {
            connectRequestedAt[peripheral.identifier.uuidString] = Date()
        }
        let cm: CBCentralManager = manager
        guard noteConnectIssued(peripheral, via: "timedConnect") else { return }
        cm.connect(peripheral, options: nil)
    }

    /// Issue a connect with CBConnectPeripheralOptionStartDelayKey and record the time — the pump-provided
    /// heartbeat wake. iOS holds the request for `delayedConnectProbeSeconds`, then connects.
    private func issueDelayedConnectProbe(_ peripheral: CBPeripheral) {
        // Never run the heartbeat probe during pairing — its connect/disconnect churn clobbers the
        // discovery scan (this blocked pairing a new pod after the old one was discarded).
        guard !discoveryModeEnabled else { return }
        guard delayedConnectProbeActive, !delayedProbeInFlight, !commandConnectInFlight,
              peripheral.state == .disconnected else { return }
        // Compute the StartDelay so the wake lands no earlier than the next-heartbeat target
        // (lastCGMReading + expectedInterval + buffer). Floored so an overdue target can't collapse to a
        // near-zero delay — an overdue target (missed/late reading) retries at the floor, which for a
        // network CGM promptly catches a value that arrives a little late. Falls back to the fixed probe
        // interval when Loop hasn't supplied a schedule.
        // If no host is refreshing the schedule -- it set the heartbeat preference once (legacy
        // setMustProvideBLEHeartbeat) and hasn't updated it within ~1.5 reading intervals -- the fixed
        // target goes chronically overdue and every probe collapses onto heartbeatMinDelaySeconds (the 60s
        // floor). That produces a ~60s background wake cadence that burns the iOS background budget and gets
        // the app suspended for long stretches (Trio field report, LoopKit/LoopKit#599). Advance the stale
        // target by whole reading intervals so we hold the expected ~interval cadence instead. A host that
        // refreshes the schedule every reading (Loop) keeps heartbeatTargetSetAt fresh, so its floor-based
        // late-reading retry is untouched.
        if let interval = heartbeatInterval, interval > 0,
           let setAt = heartbeatTargetSetAt, Date().timeIntervalSince(setAt) > interval * 1.5,
           var advanced = heartbeatTargetDate, advanced <= Date() {
            let now = Date()
            while advanced <= now { advanced.addTimeInterval(interval) }
            heartbeatTargetDate = advanced
        }
        let target = heartbeatTargetDate ?? Date().addingTimeInterval(TimeInterval(BluetoothManager.delayedConnectProbeSeconds))
        // CBConnectPeripheralOptionStartDelayKey requires an INTEGER number of seconds — a fractional
        // NSNumber(double) is rejected with CBErrorDomain Code=1 "One or more parameters were invalid",
        // which (combined with the failure re-arm) produced a tight connect/fail loop. Round to whole
        // seconds, floored so an overdue target can't collapse to a near-zero delay.
        let delaySeconds = max(Int(BluetoothManager.heartbeatMinDelaySeconds), Int(target.timeIntervalSinceNow.rounded()))
        // Fault-listener coexistence: keep the alarm-filtered scan (C005, non-allowDuplicates — light)
        // running alongside the StartDelay probe, so faults are still caught during the heartbeat
        // wait. Only a HEAVY allowDuplicates scan (monitor/beacon mode) starves the connect, so stop
        // just that. didConnect stops whatever scan remains for the duration of the connection.
        if manager.isScanning, !BluetoothManager.lowPowerMonitorEnabled { manager.stopScan() }
        delayedProbeInFlight = true
        delayedProbeIssuedAt = Date()
        delayedProbeDelay = TimeInterval(delaySeconds)
        let pid = ProcessInfo.processInfo.processIdentifier
        log.default("[delayedConnect] pid=%{public}d everFg=%{public}@ issuing connect with StartDelay=%{public}ds for %{public}@", pid, String(everForeground), delaySeconds, peripheral.identifier.uuidString)
        connectionDelegate?.omnipodLogDeviceEvent("[delayedConnect] pid=\(pid) everFg=\(everForeground) issuing connect StartDelay=\(delaySeconds)s")
        guard noteConnectIssued(peripheral, via: "delayedProbe") else {
            // The re-arm found a connect already in flight. Roll back the probe bookkeeping set
            // just above, or delayedProbeInFlight latches true against a probe never issued.
            delayedProbeInFlight = false
            return
        }
        manager.connect(peripheral, options: [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: delaySeconds)])
    }

    /// The keep-connected auto-reconnect. Suppressed in connect-on-demand mode, where the pod is
    /// left disconnected between commands (and observable via advertisements) and connected on
    /// demand by PeripheralManager. Explicit connects (pairing, retrieveAndConnectKnownPod, the
    /// on-demand connect) do NOT route through here and are unaffected.
    private func autoReconnect(_ peripheral: CBPeripheral) {
        if BluetoothManager.connectOnDemandEnabled {
            log.debug("[connectOnDemand] suppressing auto-reconnect to %{public}@", peripheral.identifier.uuidString)
            return
        }
        timedConnect(peripheral)
    }

    init(podType: PodType) {
        self.podType = podType
        super.init()

        log.default("BluetoothManager #%{public}@ INIT (podType=%{public}@)", instanceID, String(describing: podType))

        managerQueue.sync {
#if os(iOS) // watchOS has no CoreBluetooth state restoration; the watch host owns reconnect policy
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.OmnipodKit"])
#else
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: nil)
#endif
        }

        // Track foreground/background so we can tell an iOS background wake/relaunch (everFg stays
        // false) from a user-initiated open (foregrounds → everFg true). Log the transitions to the
        // persistent device log with PID for the timeline.
        let center = NotificationCenter.default
#if os(iOS)
        let didBecomeActiveNotification = UIApplication.didBecomeActiveNotification
        let didEnterBackgroundNotification = UIApplication.didEnterBackgroundNotification
#else
        let didBecomeActiveNotification = WKApplication.didBecomeActiveNotification
        let didEnterBackgroundNotification = WKApplication.didEnterBackgroundNotification
#endif
        center.addObserver(forName: didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            self?.managerQueue.async {
                guard let self = self else { return }
                self.everForeground = true
                self.log.default("[lifecycle] pid=%{public}d APP FOREGROUND", pid)
                self.connectionDelegate?.omnipodLogDeviceEvent("[lifecycle] pid=\(pid) APP FOREGROUND")
                self.enterForeground()
            }
        }
        center.addObserver(forName: didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            let pid = ProcessInfo.processInfo.processIdentifier
            self?.managerQueue.async {
                guard let self = self else { return }
                self.log.default("[lifecycle] pid=%{public}d APP BACKGROUND", pid)
                self.connectionDelegate?.omnipodLogDeviceEvent("[lifecycle] pid=\(pid) APP BACKGROUND")
                self.enterBackground()
            }
        }
    }

    deinit {
        log.default("BluetoothManager #%{public}@ DEINIT", instanceID)
    }

#if os(watchOS)
    /// PODLOAN self-heal. The watch orphans the pod between doses; a reclaim that
    /// stalls leaves the peripheral `.connecting`, and the following release cancels it —
    /// which wedges it in `.disconnecting` and poisons the stack, so every subsequent
    /// reclaim then fails until the app is relaunched. Relaunch works only because it
    /// builds a FRESH `CBCentralManager`, so reproduce that in-process: drop the old
    /// central (its pending connects/disconnects go with it) and build a new one.
    /// `centralManagerDidUpdateState` re-retrieves and reconnects whatever is still in
    /// `autoConnectIDs` once the new central powers on — the same path that recovers a
    /// user-terminated restart. watchOS has no CB state restoration, so there is no
    /// restore identifier to reconcile. Isolated to `managerQueue`.
    private func recreateCentral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.default("PODLOAN: recreating CBCentralManager to clear a wedged/stalled BLE stack")
        // LEDGER, not a fix: this drop assumes it "clears the stalled pending connect", and
        // whether that is true at the SYSTEM level is precisely the open question. Intents open
        // at teardown are counted as ORPHANED; if the field Code=11 clusters track this number,
        // the assumption is false and the fix is to cancel before dropping. Counting first.
        if !openConnectIntents.isEmpty {
            intentsOrphaned += openConnectIntents.count
            connectionDelegate?.omnipodLogDeviceEvent(
                "[intent] recreateCentral ORPHANS \(openConnectIntents.count) open intent(s) → \(intentSummary)")
            openConnectIntents.removeAll()
        }
        manager.delegate = nil
        devices.removeAll()
        manager = CBCentralManager(delegate: self, queue: managerQueue, options: nil)
    }

    /// PODLOAN E4 reclaim escalation (157). A reclaim's bare pending-connect is
    /// probabilistic after a long idle (field 2026-07-22: caught a 578s-idle pod, missed a
    /// 518s-idle one) while the takeover's scan-and-adopt landed 4/4 from arbitrary state.
    /// When the gentle connect hasn't landed mid-ladder, escalate to the takeover-grade
    /// path: drop the central (clears the stalled pending connect) and arm the same
    /// scan-adopt used at takeover. The new central's poweredOn handler then races BOTH
    /// recovery paths — the autoConnectIDs re-connect and the address scan — and whichever
    /// sees the pod first wins.
    func escalateLoanReclaim(podId: UInt32) {
        managerQueue.async {
            self.log.default("PODLOAN: reclaim escalation — recreating central + arming scan-adopt for pod 0x%x", podId)
            self.loanScanMarkerReason = "escalate"
            self.loanTakeoverPodId = podId
            self.recreateCentral()
        }
    }
#endif

#if os(iOS)
    /// PODLOAN: the same escalation for the PHONE, minus the central rebuild.
    ///
    /// The watchOS version above was gated "iOS never reclaims a loan", which is not true of this
    /// design — the phone reclaims at every hand-back settle, whenever a grant is lost, and on the
    /// escape-hatch force-reclaim. It was therefore left with only the bare pending-connect that
    /// the comment above calls probabilistic, and it shows: a measured hand-back settle of 224.2s
    /// (and 237.0s earlier the same evening) against ~1s when the link happened to still be up.
    /// Four minutes of silence on the ESCAPE HATCH is the worst place for this to be slow.
    ///
    /// Arms the same scan-adopt, which is what actually finds an idle pod, and deliberately does
    /// NOT call recreateCentral(): watchOS has no CoreBluetooth state restoration, so dropping its
    /// central is free, whereas on iOS the central owns a restore identifier and rebuilding it
    /// would discard the restoration the app depends on after a background relaunch.
    func escalateLoanReclaim(podId: UInt32) {
        managerQueue.async {
            self.log.default("PODLOAN: reclaim escalation (iOS) — arming scan-adopt for pod 0x%x (central preserved)", podId)
            self.loanScanMarkerReason = "escalate"
            self.loanTakeoverPodId = podId
            if self.manager.state == .poweredOn, !self.manager.isScanning {
                self.startScanning()
            }
        }
    }
#endif

#if os(watchOS) || os(iOS)

    /// PODLOAN E4 (157): disarm an escalation scan that never found the pod. Called on
    /// release so the scan cannot outlive the reclaim ladder and contend with the G7
    /// window. No-op when nothing is armed (an adopt already cleared it).
    func cancelLoanScan() {
        managerQueue.async {
            guard self.loanTakeoverPodId != nil else { return }
            self.log.default("PODLOAN: cancelling unfinished reclaim-escalation scan")
            self.loanScanMarkerReason = "cancelLoanScan"
            self.loanTakeoverPodId = nil
            if self.manager.state == .poweredOn, self.manager.isScanning, !self.discoveryModeEnabled {
                self.manager.stopScan()
            }
        }
    }
#endif

    @discardableResult
    private func addPeripheral(_ peripheral: CBPeripheral, podAdvertisement: PodAdvertisement?) -> Omni {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        var device: Omni! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            log.default("Matched peripheral %{public}@ to existing device: %{public}@", peripheral, String(describing: device))
            device.manager.peripheral = peripheral
            device.manager.bluetoothManager = self   // ensure the queue-correct central helpers are reachable
            if let podAdvertisement = podAdvertisement {
                device.advertisement = podAdvertisement
            }
        } else {
            let pm = PeripheralManager(peripheral: peripheral, podType: podType, centralManager: manager)
            pm.bluetoothManager = self   // for fresh-discovery connect-on-demand
            device = Omni(peripheralManager: pm, advertisement: podAdvertisement)
            devices.append(device)
            log.info("Created device")
        }
        return device
    }
    
    // MARK: - Actions
    
    func discoverPods(completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.discoverPods(completion)
        }
    }
    
    func endPodDiscovery() {
        managerQueue.sync {
            self.discoveryModeEnabled = false
            self.manager.stopScan()
            
            // Disconnect from all devices not in our connection list
            for device in devices {
                let peripheral = device.manager.peripheral
                if !autoConnectIDs.contains(peripheral.identifier.uuidString) &&
                   (peripheral.state == .connected || peripheral.state == .connecting)
                {
                    log.default("Disconnecting from peripheral: %{public}@", peripheral)
                    noteConnectClosed(peripheral, how: "cancelled:endPodDiscovery")
                    manager.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
    
    func connectToDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.insert(uuidString)
            // If powered on and peripheral not yet in devices, retrieve it now.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            if self.manager.state == .poweredOn,
               !self.devices.contains(where: { $0.manager.peripheral.identifier.uuidString == uuidString }),
               let uuid = UUID(uuidString: uuidString),
               let peripheral = self.manager.retrievePeripherals(withIdentifiers: [uuid]).first
            {
                self.log.default("connectToDevice: retrieved peripheral %{public}@ via retrievePeripherals", uuidString)
                self.addPeripheral(peripheral, podAdvertisement: nil)
                self.autoReconnect(peripheral)
            }
        }
    }

    /// Retrieve a known peripheral by UUID (without scanning), add it to devices, and initiate connection.
    /// Returns the Omni device synchronously; the actual BLE connection completes asynchronously.
    func retrieveAndConnectKnownPod(uuidString: String) -> Omni? {
        var result: Omni?
        managerQueue.sync {
            guard manager.state == .poweredOn, let uuid = UUID(uuidString: uuidString) else { return }
            let peripherals = manager.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                log.error("retrieveAndConnectKnownPod: no peripheral found for UUID %{public}@", uuidString)
                return
            }
            let device = addPeripheral(peripheral, podAdvertisement: nil)
            autoConnectIDs.insert(uuidString)
            autoReconnect(peripheral)
            log.default("retrieveAndConnectKnownPod: initiating connection to %{public}@", peripheral)
            result = device
        }
        return result
    }
    
    func disconnectFromDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.remove(uuidString)
            // Prune the discarded pod from devices[] (otherwise append-only) and drop any connection, so
            // a stale device can't be picked up later by the heartbeat/keep-alive machinery or churned
            // while pairing a new pod. (devices[] never being pruned is long-standing; this closes it.)
            if let idx = self.devices.firstIndex(where: { $0.manager.peripheral.identifier.uuidString == uuidString }) {
                let peripheral = self.devices[idx].manager.peripheral
                if peripheral.state == .connected || peripheral.state == .connecting {
                    self.noteConnectClosed(peripheral, how: "cancelled:disconnectFromDevice")
                    self.manager.cancelPeripheralConnection(peripheral)
                }
                self.devices.remove(at: idx)
                self.log.default("Removed discarded pod %{public}@ from devices", uuidString)
                self.connectionDelegate?.omnipodLogDeviceEvent("[pairing] removed discarded pod \(uuidString) from devices")
            }
            // Quiet any heartbeat probe that was driving off the (now-discarded) pod.
            self.delayedProbeInFlight = false
        }
    }
    
    private func updateConnections() {
        guard manager.state == .poweredOn else {
            log.debug("Skipping updateConnections until state is poweredOn")
            return
        }
        
        for device in devices {
            let peripheral = device.manager.peripheral
            if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                    log.info("updateConnections: Connecting to peripheral: %{public}@", peripheral)
                    autoReconnect(peripheral)
                }
            } else {
                switch peripheral.state {
                case .connected:
                    log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral)
                    noteConnectClosed(peripheral, how: "cancelled:updateConnections")
                    manager.cancelPeripheralConnection(peripheral)
                case .connecting, .disconnecting:
                    #if os(watchOS)
                    // PODLOAN E4: cancelling a NON-settled connection wedges the peripheral
                    // in .disconnecting and poisons the stack. Drop the whole central
                    // instead — a clean teardown of the pending connect, no wedge. The pod
                    // is already out of autoConnectIDs, so the fresh central stays quiet.
                    log.default("updateConnections: peripheral not settled (%{public}@) — recreating central instead of cancelling", String(describing: peripheral.state.rawValue))
                    recreateCentral()
                    return
                    #else
                    // iOS (stock): cancel a pending connect; leave a disconnecting one.
                    if peripheral.state == .connecting {
                        log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral)
                        noteConnectClosed(peripheral, how: "cancelled:updateConnections")
                        manager.cancelPeripheralConnection(peripheral)
                    }
                    #endif
                case .disconnected:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func discoverPods(_ completion: @escaping (BluetoothManagerError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("discoverPods()")

        guard manager.state == .poweredOn else {
            completion(.bluetoothNotAvailable(manager.state))
            return
        }

        // We will attempt to connect to all pairable devices when in discovery mode
        discoveryModeEnabled = true
        connectionDelegate?.omnipodLogDeviceEvent("[pairing] discoverPods — scanning for a pairable pod")
        // Quiet any in-flight heartbeat probe / stale connect churn so it doesn't clobber discovery.
        delayedProbeInFlight = false
        alarmScanSuppressed = false
        manager.stopScan()
        for device in devices {
            let peripheral = device.manager.peripheral
            if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                log.info("discoverPods: Connecting to peripheral: %{public}@", peripheral)
                timedConnect(peripheral)  // pairing/discovery — an explicit connect, not auto-reconnect
            }
        }
        startScanning()

        completion(nil)
    }

    /// The service UUID the pod advertises when healthy-disconnected (used to discover it for a fast
    /// connect). O5 switches to a pdmId-based UUID after pairing.
    private var podScanServiceUUID: CBUUID {
        if podType.isO5, let pdmId = uuidPdmId {
            return o5ServiceAdvertisementUUID(pdmId)
        }
        return podType.blePodProfile.advertisementServiceUUID
    }

    /// O5 connectionless fault-watch filter: the pod-specific "attention" advertisement (status-suffix …02),
    /// built from our paired controllerId. Nil on DASH or until we know the controllerId (post-pairing).
    /// Analogous to the DASH `alarmServiceUUIDs` (C00A) but pod-specific — O5 embeds the controllerId in the
    /// UUID rather than using a shared 16-bit fault UUID, so this can't be a static constant.
    private var o5FaultScanServiceUUID: CBUUID? {
        guard podType.isO5, let pdmId = uuidPdmId else { return nil }
        return o5FaultAdvertisementUUID(pdmId)
    }

    /// Peripheral awaiting a fresh-discovery connect: while set, the next matching didDiscover stops
    /// the scan and connects on that just-heard advertisement (fast) instead of a cold reacquisition.
    private var pendingFreshConnectID: String?

    /// Connect fast by first hearing the pod: scan for its service, and on the next discovery stop the
    /// scan and connect on that fresh advertisement (~1-2s) rather than a bare cold connect (~16s).
    /// Falls back to a direct connect if we don't hear it quickly.
    func connectViaFreshDiscovery(_ peripheral: CBPeripheral) {
        managerQueue.async {
            let id = peripheral.identifier.uuidString
            // PODLOAN: during a TAKEOVER, leave a running scan alone.
            //
            // This method exists for the steady state, where the pod is known and a 4s listen
            // before a cold connect is a good trade. In a takeover it is actively harmful: the
            // takeover read loop calls a connect every 8s, so this tears the scan down and rebuilds
            // it every ~4.4s — measured — which (a) discards the takeover's allowDuplicates scan
            // armed in startScanning, and (b) is aggressive enough that iOS throttles the scanning.
            // The pod is then found only when a 4s window happens to coincide with an advertisement:
            // two measured takeovers took 190.9s and 195.2s, both succeeding, both after 8 reads.
            //
            // A takeover already has its own budget (14 reads / ~112s) and its own correctly-filtered
            // continuous scan. Let that scan run; a discovery will drive the connect through
            // didDiscover exactly as it does in the steady state.
            // NOT gated on isScanning — that was the bug in the first version of this guard. The
            // 4s fallback below calls stopScan() before its cold connect, so by the NEXT call
            // isScanning is false, the guard missed, and the teardown loop resumed: measured at
            // 265.2s / 11 reads with a scan rebuilt every ~4.3s throughout. The condition only
            // held on the first call, which is exactly when it did not matter.
            if self.loanTakeoverPodId != nil {
                self.pendingFreshConnectID = id
                if !self.manager.isScanning {
                    // The fallback (or a previous connect) stopped it. Re-arm through
                    // startScanning so it comes back with the TAKEOVER filter and
                    // allowDuplicates, rather than this method's narrower one-shot scan.
                    self.startScanning()
                }
                self.log.default("[connectOnDemand] takeover in progress — continuous scan, no 4s teardown (%{public}@)", id)
                self.connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] takeover: continuous scan (no 4s teardown)")
                return
            }
            self.pendingFreshConnectID = id
            self.manager.stopScan()
            self.manager.scanForPeripherals(withServices: [self.podScanServiceUUID], options: nil)
            self.log.default("[connectOnDemand] fresh-discovery scan for %{public}@", id)
            self.connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] fresh-discovery scan started")
            self.managerQueue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self, self.pendingFreshConnectID == id else { return }
                self.pendingFreshConnectID = nil
                self.log.default("[connectOnDemand] no fresh discovery in 4s — direct (cold) connect")
                self.connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] no fresh discovery in 4s — cold connect fallback")
                self.manager.stopScan()
                self.freshConnect(peripheral)
            }
        }
    }

    /// Issue an on-demand connect with a stale-state flush. The first connect on a peripheral is
    /// clean, but a cached CBPeripheral that was previously connected then cancelPeripheralConnection'd
    /// wedges in .connecting on a bare reconnect (measured: every reconnect after an idle-disconnect
    /// timed out at 20s while iOS reported it .disconnected + advertising connectable). Cancel any
    /// lingering iOS-side connection intent and re-fetch the peripheral before connecting.
    private func freshConnect(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // freshConnect exists ONLY to unstick a wedged .connecting state before a cold connect. If the pod
        // is already healthily .connected, cancelling here would murder the live link (the self-inflicted
        // disconnect that didDisconnect then mislabels a "drop"). Leave the connection alone.
        if peripheral.state == .connected {
            log.default("[connectOnDemand] freshConnect skipped — already connected to %{public}@", peripheral.identifier.uuidString)
            pendingFreshConnectID = nil
            return
        }
        noteConnectClosed(peripheral, how: "cancelled:freshConnect")
        manager.cancelPeripheralConnection(peripheral)
        let target = manager.retrievePeripherals(withIdentifiers: [peripheral.identifier]).first ?? peripheral
        // Keep the session's peripheral reference in sync with the object we actually connect.
        if let device = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier }) {
            device.manager.peripheral = target
        }
        // OBEY THE VERDICT (2026-08-20). This discarded the return value, so on the PHONE during a
        // loan the interlock logged "** CONNECT WHILE ON LOAN ** — REFUSED" and the connect went out
        // one line later regardless. A log that reports a refusal that did not happen is worse than no
        // log: it was read as evidence the interlock was holding while the phone was still taking the
        // pod. `force: true` means the only thing that can return false here is that interlock, which
        // is compiled in on iOS only — so on the watch this guard is unconditionally true and the
        // stale-flush behaviour is unchanged.
        guard noteConnectIssued(target, via: "freshConnect", force: true) else { return }
        manager.connect(target, options: nil)
    }

    // MARK: - Central calls (MUST run on managerQueue)
    //
    // CBCentralManager was created with `managerQueue`, so every call into it has to be serialized on
    // that same queue — otherwise connect/cancel race the delegate callbacks and CoreBluetooth's
    // internal state machine. Connect-on-demand was calling central.connect()/cancelPeripheralConnection()
    // from PeripheralManager.queue, which wedged reconnects in .connecting (intermittently). These
    // helpers give PeripheralManager a queue-correct way to drive the central.

    /// Connect the (known/recovered) peripheral on the central's queue for a real command. A command
    /// preempts the heartbeat probe: cancel any in-flight StartDelay probe first so its pending connect
    /// can't complete and get mis-attributed as this command connect, then mark the command in flight
    /// (so the probe won't re-arm or claim the didConnect) and connect.
    func connectOnDemand(_ peripheral: CBPeripheral) {
        managerQueue.async { [weak self] in
            self?.beginCommandConnect(peripheral)
        }
    }

    /// Start a command (or keep-alive) connect. Must run on managerQueue.
    private func beginCommandConnect(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        if delayedProbeInFlight {
            log.default("[connectOnDemand] command preempts heartbeat probe — cancelling probe")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] command preempts heartbeat probe — cancelling probe")
            delayedProbeInFlight = false
            delayedProbeIssuedAt = nil
            noteConnectClosed(peripheral, how: "cancelled:beginCommandConnect")
            manager.cancelPeripheralConnection(peripheral)
        }
        commandConnectInFlight = true
        // Fresh-discovery connect: briefly scan for the pod and connect on its just-heard advert
        // (~1-2s) instead of a bare cold connect() that waits out iOS's duty-cycled reacquisition
        // (~10-16s — the slow user-initiated Suspend). Falls back to a cold connect after 4s if the
        // pod isn't heard. (The heartbeat probe still uses StartDelay; the two stay serialized via
        // commandConnectInFlight.)
        log.default("[connectOnDemand] fresh-discovery command connect for %{public}@", peripheral.identifier.uuidString)
        connectViaFreshDiscovery(peripheral)
    }

    /// The known/autoconnect pod peripheral, for foreground keep-alive and heartbeat. Returns nil when
    /// there is no active pod (autoConnectIDs empty) — do NOT fall back to a stale device, or the
    /// heartbeat probe churns against the discarded pod and clobbers pairing a new one.
    private var keepAlivePeripheral: CBPeripheral? {
        return devices.first(where: { autoConnectIDs.contains($0.manager.peripheral.identifier.uuidString) })?.manager.peripheral
    }

    /// App entered the foreground: keep the pod connected so connection-gated UI is live and commands
    /// are instant. Pre-connect if it's currently disconnected. (Idle-disconnect is skipped while
    /// foreground; a drop is reconnected in didDisconnect.)
    private func enterForeground() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        isAppForeground = true
        if let peripheral = keepAlivePeripheral, peripheral.state == .disconnected {
            log.default("[connectOnDemand] foreground — pre-connecting for keep-alive")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] foreground — pre-connecting for keep-alive")
            beginCommandConnect(peripheral)
        }
    }

    /// App entered the background: normally drop the kept-alive connection and resume the heartbeat probe.
    /// EXCEPTION — a background Pod Keep Alive mode (silentTune / rileyLink, DASH): keep the pod connected,
    /// because those modes exist for phone/pod combos where a disconnect→reconnect is unreliable. The
    /// keep-alive's periodic status refresh maintains the link; we just leave it connected and don't probe.
    private func enterBackground() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        isAppForeground = false
        guard let peripheral = keepAlivePeripheral else { return }
        if shouldHoldConnection {   // background Pod Keep Alive mode — do NOT disconnect
            log.default("[connectOnDemand] background — Pod Keep Alive holding connection (no disconnect)")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] background — Pod Keep Alive holding connection")
            if peripheral.state == .disconnected {
                // We want it held connected but it's currently down — reconnect so keep-alive can refresh it.
                beginCommandConnect(peripheral)
            }
            return
        }
        commandConnectInFlight = false   // deliberate disconnect: let the probe re-arm
        if peripheral.state == .connected || peripheral.state == .connecting {
            log.default("[connectOnDemand] background — disconnecting, resuming heartbeat probe")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] background — disconnecting, resuming heartbeat probe")
            // Attribute it. A `.connected` peripheral has no open intent left to close, so the ordinary
            // path recorded nothing and this site never appeared in `cancels=`.
            if peripheral.state == .connected { noteLinkTornDown(peripheral, by: "enterBackground") }
            else { noteConnectClosed(peripheral, how: "cancelled:enterBackground") }
            manager.cancelPeripheralConnection(peripheral)   // didDisconnect resumes scan + arms probe
        } else {
            resumeScanIfNeeded()                             // fault-listener scan while idle
            issueDelayedConnectProbe(peripheral)             // + heartbeat probe alongside (if needed)
        }
    }

    /// Cancel/disconnect the peripheral on the central's queue. This is the idle-disconnect / teardown
    /// path, so we're going idle: clear commandConnectInFlight so the resulting didDisconnect re-arms
    /// the heartbeat probe.
    /// `site` names WHY we are hanging up — "idle" (the between-commands idle-disconnect) or
    /// "connectError" (connectOnDemand's catch, unsticking a connect after its command threw).
    /// The ledger recorded both as one anonymous "cancelled:disconnectOnDemand", which is how the
    /// loan-reclaim killer below hid for a week behind a legitimate teardown with the same name.
    func disconnectOnDemand(_ peripheral: CBPeripheral, by site: String, detail: String? = nil) {
        managerQueue.async { [weak self] in
            guard let self = self else { return }
            // THE LADDER'S OWN AXE (2026-08-20, loan e147). Every cancelled pod connect in the loan —
            // 6 of 6 — was this teardown, at 0.36-1.87 s after the connect was issued, against a
            // demonstrated ~1.3 s connect latency. The mechanism: the reclaim ladder polls every ~2 s;
            // a poll's connect command can throw FAST (`notReady` / pending-conditions collision —
            // runCommand's only sub-timeout throws; the 20 s timeout cannot fire at 0.4 s), and the
            // catch then "cleaned up" by cancelling the in-flight connect — which was the recovery
            // itself, about to land. L5 succeeded only because didConnect (1.28 s) beat the next
            // poll's error; L14 got one attempt, cancelled at 0.36 s, and the cycle failed with
            // enactFailed(communication(nil)).
            //
            // So: while the loan takeover/reclaim marker is armed, a connect-error teardown is
            // FORBIDDEN — the error belongs to the failed poll, not to the connect. The connect stays
            // pending (it has no timeout and adoption resolves it); if it truly wedges, the marker
            // teardown at ladder end restores the old behavior for the next attempt, and freshConnect
            // exists for exactly that unstick. The idle-disconnect site is untouched: it requires
            // `.connected`, which an open connect intent excludes, so it was provably never the axe.
            //
            // Checked on managerQueue, where the marker is authoritative — no cross-queue race.
            if site == "connectError", self.loanTakeoverPodId != nil {
                self.connectionDelegate?.omnipodLogDeviceEvent(
                    "[connectOnDemand] connect-command error (\(detail ?? "unknown")) during armed loan reclaim — pending connect LEFT RIDING (the connect is the recovery, not the wedge)")
                return
            }
            self.commandConnectInFlight = false
            self.log.default("[connectOnDemand] central.cancel on managerQueue for %{public}@ (site=%{public}@)", peripheral.identifier.uuidString, site)
            if let detail { self.connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] teardown by \(site): \(detail)") }
            noteConnectClosed(peripheral, how: "cancelled:onDemand-\(site)")
            self.manager.cancelPeripheralConnection(peripheral)
        }
    }

    private func startScanning() {
        let serviceUUID: CBUUID = podScanServiceUUID
        let services: [CBUUID]?
        let options: [String: Any]
        if discoveryModeEnabled || loanTakeoverPodId != nil {
            // Pairing OR PODLOAN takeover: scan for the pod's main advertisement service, so a pod
            // this device holds no peripheral for is actually found.
            //
            // MUST take precedence over the low-power alarm scan (which filters on C005/C00A and would
            // never see a pairing pod) and over scanningEnabled (pairing has to scan regardless).
            //
            // The TAKEOVER arm was missing, and it is the same situation as pairing: the watch
            // inherits a pod it has never seen, so it has no CBPeripheral and discovery is mandatory.
            // Falling through left it on the low-power fault-watch — C00A for DASH, the "…02"
            // attention UUID for O5 — which by design only fires when a pod is FAULTED. A healthy pod
            // never advertises it, so the takeover scan could not succeed at any distance or with any
            // amount of patience: 14 reads, 113 s, `no-peripheral · didConnect never (n=0)`, every
            // time. The fork's older driver had no low-power mode and always scanned the main
            // service, which is why this only appeared after adopting the newer OmnipodKit.
            let reason = discoveryModeEnabled ? "discovery/pairing" : "loan-takeover"
            services = [serviceUUID]
            options = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            log.default("Start scanning (%{public}@ filter=%{public}@)", reason, serviceUUID.uuidString)
            // WHERE THE FILTER CAME FROM (2026-08-20). `podScanServiceUUID` has two branches — an O5
            // UUID DERIVED from uuidPdmId, and the pod profile's static advertisement service — and a
            // wrong branch produces a scan that cannot match at any distance, for any duration, with no
            // symptom other than silence. That is indistinguishable from deafness in the log, and it is
            // the cheapest of the candidate causes to rule in or out, so name the branch.
            let filterSource = podType.isO5
                ? (uuidPdmId != nil ? "O5/pdm-derived" : "O5/profile-fallback")
                : "profile(\(String(describing: podType)))"
            connectionDelegate?.omnipodLogDeviceEvent(
                "[\(reason)] scan started (filter=\(serviceUUID.uuidString) via \(filterSource))")
            manager.scanForPeripherals(withServices: services, options: options)
            // Watchdog follows the SCAN, not the marker (2026-08-20 review). The didSet arming alone
            // left the timer dead for the between-ladders gap, so scanWD=0 meant "never checked".
            // Armed HERE — the acquisition-scan branch only — it can never police the C00A alarm
            // scan, whose silence is normal and whose filter a spurious restart would clobber.
            armLoanScanWatchdog()
            return
        }
        guard BluetoothManager.scanningEnabled else {
            log.default("[connectOnDemand] scanning disabled — not starting a scan (scan-free connect mode)")
            return
        }
        if BluetoothManager.lowPowerMonitorEnabled && podType.isDash {
            // Low-power fault-watch (DASH only): wake on a fault-state advertisement — filter on the alarm
            // UUID(s) (C00A), no allowDuplicates. C00A is DASH-specific, so never used for O5.
            services = BluetoothManager.alarmServiceUUIDs
            options = [:]
        } else if BluetoothManager.lowPowerMonitorEnabled, let o5Fault = o5FaultScanServiceUUID {
            // Low-power fault-watch (O5): filter on the pod-specific "attention" advertisement (status-suffix
            // …02), built from our controllerId. Not advertised in normal operation, so the …00→…02 flip is a
            // fresh discovery that wakes a suspended app — the same mechanism as the DASH C00A scan. The wake
            // is handled in didDiscover (own-pod-gated), which connects + reads the real status.
            services = [o5Fault]
            options = [:]
        } else {
            // Monitor mode: filter on the pod's main service (O5-aware via podScanServiceUUID);
            // allowDuplicates to see the advert cadence.
            services = [serviceUUID]
            options = BluetoothManager.advertisementMonitorEnabled ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : [:]
        }
        let filterDesc = services == nil ? "wildcard" : services!.map { $0.uuidString }.joined(separator: ",")
        log.default("Start scanning (filter=%{public}@, lowPowerMonitor=%{public}@, allowDuplicates=%{public}@)",
                    filterDesc,
                    String(describing: BluetoothManager.lowPowerMonitorEnabled),
                    String(describing: options[CBCentralManagerScanOptionAllowDuplicatesKey] != nil))
        // Device-log the idle-scan arm so a fault-detection test can confirm which filter is actually live
        // (e.g. the O5 …02 fault UUID built from our controllerId) even when the app is suspended and only
        // the persistent device log survives.
        connectionDelegate?.omnipodLogDeviceEvent("[scan] armed filter=[\(filterDesc)] lowPowerMonitor=\(BluetoothManager.lowPowerMonitorEnabled) allowDuplicates=\(options[CBCentralManagerScanOptionAllowDuplicatesKey] != nil)")
        manager.scanForPeripherals(withServices: services, options: options)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        loanScanWatchdog?.cancel(); loanScanWatchdog = nil
        wildcardProbeStartedAt = nil
        manager.stopScan()
    }

    /// Resume the monitor/beacon scan after a connect attempt ends (connect-on-demand stops the scan
    /// during the connect because an active allowDuplicates scan starves connection completion).
    /// Only when nothing is connected, so we never scan while a command is using the link.
    private func resumeScanIfNeeded() {
        guard BluetoothManager.advertisementMonitorEnabled || BluetoothManager.lowPowerMonitorEnabled else { return }
        guard !alarmScanSuppressed else { return }   // an alert is active — stay quiet (re-wake quieting)
        guard manager?.state == .poweredOn, !manager.isScanning else { return }
        guard !devices.contains(where: { $0.manager.peripheral.state == .connected || $0.manager.peripheral.state == .connecting }) else { return }
        log.default("[connectOnDemand] resuming scan after connect attempt")
        startScanning()
    }

    /// Called (via BlePodComms) when a connected status read shows all pod alerts cleared: lift the
    /// re-wake suppression and resume the connectionless alarm scan.
    func resumeAlarmScanAfterAlertsCleared() {
        managerQueue.async { [weak self] in
            guard let self = self, self.alarmScanSuppressed else { return }
            self.alarmScanSuppressed = false
            self.log.default("[POD-ALERT] alerts cleared — resuming alarm scan")
            self.connectionDelegate?.omnipodLogDeviceEvent("[POD-ALERT] alerts cleared — resuming alarm scan")
            self.resumeScanIfNeeded()
        }
    }

    // MARK: - Accessors

    func getConnectedDevices() -> [Omni] {
        var connected: [Omni] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
    }

    /// The PeripheralManager for a known device by peripheral UUID — connected OR NOT. Connect-on-demand
    /// uses this to obtain the pod's manager while disconnected (BlePodComms.manager is otherwise only
    /// set in omnipodPeripheralDidConnect, so it's nil on a fresh launch when auto-reconnect is off).
    func peripheralManager(forIdentifier uuidString: String) -> PeripheralManager? {
        var result: PeripheralManager?
        managerQueue.sync {
            result = self.devices.first(where: { $0.manager.peripheral.identifier.uuidString == uuidString })?.manager
        }
        return result
    }

    override var debugDescription: String {
        
        var report = [
            "## BluetoothManager",
            "central: \(manager!)"
        ]

        for device in devices {
            report.append(String(reflecting: device))
            report.append("")
        }

        return report.joined(separator: "\n\n")
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("[#%{public}@] %{public}@: %{public}@", instanceID, #function, String(describing: central.state.rawValue))

        if case .poweredOn = central.state {
            // bluetooth may have reset; update peripheral references
            for device in devices {
                if let newPeripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first {
                    log.debug("Re-connecting to known peripheral %{public}@", newPeripheral.identifier.uuidString)
                    device.manager.peripheral = newPeripheral
                    autoReconnect(newPeripheral)
                }
            }

            // Recover peripherals from autoConnectIDs that aren't yet in devices.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            let knownDeviceIDs = Set(devices.map { $0.manager.peripheral.identifier.uuidString })
            for uuidString in autoConnectIDs where !knownDeviceIDs.contains(uuidString) {
                if let uuid = UUID(uuidString: uuidString),
                   let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
                {
                    log.default("[#%{public}@] Recovered peripheral from autoConnectIDs: %{public}@", instanceID, uuidString)
                    addPeripheral(peripheral, podAdvertisement: nil)
                    autoReconnect(peripheral)
                }
            }

            updateConnections()
            
            if BluetoothManager.advertisementMonitorEnabled {
                // Monitor mode: keep scanning continuously so we observe pod advertisements,
                // regardless of whether all autoConnect devices are known/connected.
                if !manager.isScanning { startScanning() }
            // PODLOAN: an armed takeover is a first-class scan reason. beginLoanTakeover
            // races this central to poweredOn (it arms milliseconds after init), and the
            // takeover's autoConnectIDs are empty (the grant rides a released connection),
            // which makes hasDiscoveredAllAutoConnectDevices vacuously true — the stock
            // condition alone would never scan.
            } else if (discoveryModeEnabled || loanTakeoverPodId != nil || !hasDiscoveredAllAutoConnectDevices) && !manager.isScanning {
                startScanning()
            } else if !discoveryModeEnabled && loanTakeoverPodId == nil && manager.isScanning {
                stopScanning()
            }
        }

        for device in devices {
            device.manager.assertConfiguration()
        }
    }

#if os(iOS) // watchOS has no CoreBluetooth state restoration (willRestoreState / restored-state keys are iOS-only)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.info("Omni %{public}@: %{public}@", #function, dict)

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                let device = addPeripheral(peripheral, podAdvertisement: nil)
                
                if autoConnectIDs.contains(peripheral.identifier.uuidString) {
                    if peripheral.state == .connected {
                        connectionDelegate?.omnipodPeripheralWasRestored(manager: device.manager)
                    }
                } else if peripheral.state == .connected || peripheral.state == .connecting {
                    // Don't disconnect — autoConnectIDs may not be populated yet due to init ordering.
                    // updateConnections() will clean up any truly unwanted peripherals after autoConnectIDs is set.
                    log.info("Restored peripheral %{public}@ not yet in autoConnectIDs, deferring cleanup to updateConnections", peripheral.identifier.uuidString)
                }
            }
        }
    }
#endif

    /// The DASH "clear / no alert" status word (see DASH_BEACON_FINDINGS.md). Any other value while
    /// the pod is otherwise healthy indicates an active alert/alarm.
    private static let podStatusClear = Data([0x00, 0x02, 0x00, 0x00])

    /// Extract the 4-byte DASH status word from the manufacturer data: it sits immediately before the
    /// 3-byte address+trailer tail (…000a‹STATUS›f10cbc). End-anchored so it's robust to the fixed
    /// pod-id prefix. Returns nil if the mfg data isn't the expected DASH shape.
    private func podStatusWord(from advertisementData: [String: Any]) -> Data? {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8 else { return nil }
        return mfg.subdata(in: (mfg.count - 7)..<(mfg.count - 3))
    }

    /// Connectionless fault/alert detection: read the pod's alarm state straight from its advertisement —
    /// no connection needed. Decodes the status word (b2 = FaultEventCode, b3 = AlertSet bitmask) and, on
    /// a fault/alert transition, surfaces it to the pump manager (which fetches status and raises the pod
    /// alarm), then quiets the scan until it clears.
    private func detectPodAlertStatus(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        guard let status = podStatusWord(from: advertisementData) else { return }
        let id = peripheral.identifier.uuidString
        guard lastPodStatusWord[id] != status else { return }   // only on change
        // The 4-byte status word is [b0 b1 b2 b3]. b3 is the AlertSet bitmask (bit N = slot N firing);
        // e.g. clear=…00, expiration-reminder(slot3)=…08. b1 carries a baseline 0x02 (slot1 "NotUsed")
        // plus the same alert bit, so we log it too as a cross-check while enumerating alert types.
        // The 4-byte status word is [b0 b1 b2 b3]:
        //  - b3 = AlertSet bitmask (bit N = alert slot N FIRING); e.g. expiration-reminder(slot3)=0x08.
        //  - b2 = FAULT code (0x00 in every non-fault state; = FaultEventCode on a fault, e.g. occlusion
        //    0x14 — confirmed by a captured occlusion: word 00141400, connected read "0x14 Occluded").
        //  - b1 = an "alert configured"/current-alarm byte (baseline 0x02, 0x0a with a reminder set,
        //    and the fault code on a fault) — logged as a cross-check only.
        let bytes = Array(status)
        let alertByte: UInt8 = bytes.count >= 4 ? bytes[3] : 0
        let faultByte: UInt8 = bytes.count >= 3 ? bytes[2] : 0
        let statusByte1: UInt8 = bytes.count >= 2 ? bytes[1] : 0
        let alertSet = AlertSet(rawValue: alertByte)
        let prevBytes = lastPodStatusWord[id].map { Array($0) }
        let prevAlertByte: UInt8 = (prevBytes?.count ?? 0) >= 4 ? prevBytes![3] : 0
        let prevFaultByte: UInt8 = (prevBytes?.count ?? 0) >= 3 ? prevBytes![2] : 0
        let wasAlert = prevAlertByte != 0
        let isAlert = alertByte != 0
        let wasFault = prevFaultByte != 0
        let isFault = faultByte != 0
        lastPodStatusWord[id] = status
        let slotDesc = alertSet.isEmpty ? "none" : alertSet.map { String(describing: $0) }.joined(separator: ",")
        let faultDesc = isFault ? String(describing: FaultEventCode(rawValue: faultByte)) : "none"
        log.default("[POD-STATUS] %{public}@ status=%{public}@ alertByte=0x%{public}02x faultByte=0x%{public}02x b1=0x%{public}02x slots=[%{public}@] fault=%{public}@ — connectionless detect",
                    id, status.hexadecimalString, alertByte, faultByte, statusByte1, slotDesc, faultDesc)
        connectionDelegate?.omnipodLogDeviceEvent("[POD-STATUS] status=\(status.hexadecimalString) alertByte=0x\(String(format: "%02x", alertByte)) faultByte=0x\(String(format: "%02x", faultByte)) slots=[\(slotDesc)] fault=\(faultDesc) — connectionless detect")

        // A pod FAULT just appeared (b2 went non-zero): the pod has stopped delivery. Surface it.
        if !wasFault && isFault {
            log.default("[POD-FAULT] %{public}@ → FAULT 0x%{public}02x (%{public}@) (from advertisement, no connect)", id, faultByte, faultDesc)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-FAULT] → FAULT 0x\(String(format: "%02x", faultByte)) (\(faultDesc)) (from advertisement, no connect)")
            surfacePodConditionAndQuiet(alertSet: alertSet)
        } else if !wasAlert && isAlert {
            // An alert slot just started firing.
            log.default("[POD-ALERT] %{public}@ → ALERT ACTIVE slots=[%{public}@] (from advertisement, no connect)", id, slotDesc)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-ALERT] → ALERT ACTIVE slots=[\(slotDesc)] (from advertisement, no connect)")
            surfacePodConditionAndQuiet(alertSet: alertSet)
        } else if (wasAlert && !isAlert) || (wasFault && !isFault) {
            log.default("[POD-ALERT] %{public}@ → CLEARED slots=[%{public}@] (from advertisement, no connect)", id, slotDesc)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-ALERT] → CLEARED slots=[\(slotDesc)] (from advertisement, no connect)")
        }
    }

    /// Connect on demand + read the real pod status so a connectionless-detected alert/fault surfaces to
    /// Loop (getPodStatus -> alertsChanged/issueAlert or fault handling), then quiet the alarm scan while
    /// the condition persists (re-wake quieting; lifted by resumeAlarmScanAfterAlertsCleared()).
    private func surfacePodConditionAndQuiet(alertSet: AlertSet) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // Notify the host OFF managerQueue. The delegate handles this synchronously by driving
        // getPodStatus -> runSession -> bleRunSession -> peripheralManager(forIdentifier:), which does
        // managerQueue.sync. This runs from didDiscover (already on managerQueue), so calling the delegate
        // inline is a sync-to-self deadlock — it hung/crash-looped the app on a fresh launch when a DASH pod
        // advertised a fault/alert before any connection had established BlePodComms.manager
        // (loopandlearn/OmnipodKit#126). Quieting the alarm scan stays on managerQueue.
        let delegate = connectionDelegate
        DispatchQueue.global(qos: .userInitiated).async {
            delegate?.omnipodDidDetectAlert(slots: alertSet)
        }
        alarmScanSuppressed = true
        if manager.isScanning { manager.stopScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        lastAnyDiscoveryAt = Date(); anyDiscoveryCount += 1

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral, advertisementData)

        // Full advertisement dump for pod-adjacent frames — field data on what the pod advertises, and
        // the input to the connectionless fault-detection path. Captures every field.
        let advSvcUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isPodFrame = autoConnectIDs.contains(peripheral.identifier.uuidString) || PodAdvertisement(advertisementData, podType: podType) != nil
        // Only OUR paired pod (unique BLE identity) may drive fault detection / connect / probe. The
        // C00A fault-scan filter is generic (any DASH pod's fault matches), so a nearby stranger's
        // faulted pod can wake us — we must NOT act on it (no false alarm, and no foreign connect or
        // scan-suppression). Advert LOGGING below stays on any pod-shaped frame (diagnostics + pairing).
        let isOwnPod = autoConnectIDs.contains(peripheral.identifier.uuidString)
        // Census BEFORE any filtering or gating below: the question a failed ladder needs answered is
        // "did the radio hear the pod at all", and that must not depend on advertisementMonitorEnabled,
        // podType, or whether anything downstream chose to act on the frame.
        // COUNT BY ADDRESS, NOT BY autoConnectIDs (2026-08-20 correction). This was gated on
        // `isOwnPod`, i.e. membership of autoConnectIDs — which releaseConnection() EMPTIES via
        // disconnectFromDevice(). So after every post-dose release the pod's advertisements stopped
        // being counted even though they were being RECEIVED, and `adverts=0 last=never` was read for
        // two nights as "the watch cannot hear the pod". It may only ever have meant "not in the set".
        // The adopt path itself matches the ADDRESS out of the parsed advertisement, so that is what
        // the census must mirror.
        let parsedAdv = PodAdvertisement(advertisementData, podType: podType)
        let addressMatches = parsedAdv.map { adv in
            // Marker first, then the sticky id (see `lastKnownLoanPodId`), and only if we have never
            // seen a pod id at all does this fall back to set membership — the circular test that made
            // the census lie. In practice that last case is the pre-first-loan cold start, where there
            // is no loan to measure anyway.
            if let want = loanTakeoverPodId ?? lastKnownLoanPodId { return want == adv.podId }
            return autoConnectIDs.contains(peripheral.identifier.uuidString)
        } ?? false
        if addressMatches {
            let now = Date()
            if let prev = ownPodAdvertLastAt { lastAdvertGap = now.timeIntervalSince(prev) }
            ownPodAdvertsSeen += 1
            ownPodAdvertLastAt = now
            ownPodAdvertLastRSSI = RSSI.intValue
            // WHY an adopt did not follow. The three gates are parse / address / peripheral state,
            // and a peripheral stuck in .connecting (an orphaned connect) silently skips adoption
            // forever. Report the state so the failing gate is named instead of inferred.
            if loanTakeoverPodId != nil, peripheral.state != .disconnected {
                // DWELL QUALIFIED (2026-08-20). The bare state test fires on every HEALTHY adopt: the
                // pod keeps advertising for the second or two it sits in `.connecting`, so a normal
                // successful takeover printed "adopt SKIPPED" several times on its way to succeeding.
                // That is the instrument crying wolf on the good case, and it would have buried the
                // real signal on the one ladder that matters. The defect this line exists to catch is a
                // peripheral WEDGED in `.connecting` — an orphaned connect that never resolves and
                // silently blocks adoption forever — and that is a dwell-time condition, not a state
                // condition. 10 s is well past any healthy connect (field connects resolve in <1 s)
                // and well short of the 28 s ladder, so a wedge still gets named inside the window.
                let id = peripheral.identifier.uuidString
                let since = nonDisconnectedSince[id] ?? now
                if nonDisconnectedSince[id] == nil { nonDisconnectedSince[id] = now }
                let dwell = now.timeIntervalSince(since)
                if dwell > 10 {
                    podHeardButNotAdopted += 1
                    connectionDelegate?.omnipodLogDeviceEvent(String(format:
                        "[adopt-gate] HEARD our pod (rssi %@) but state=%d != disconnected for %.0fs — WEDGED, adopt SKIPPED (#%d)",
                        "\(RSSI)", peripheral.state.rawValue, dwell, podHeardButNotAdopted))
                }
            } else {
                nonDisconnectedSince[peripheral.identifier.uuidString] = nil
            }
        }
        if BluetoothManager.advertisementMonitorEnabled, isPodFrame {
            let svcUUIDs = advSvcUUIDs.map { $0.uuidString }.joined(separator: ",")
            let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.hexadecimalString ?? "-"
            let svcData = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?
                .map { "\($0.key.uuidString):\($0.value.hexadecimalString)" }.joined(separator: ",") ?? "-"
            let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
            let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "-"
            // Inter-frame delta = the advertising cadence (RE's DS-beacon-rate question).
            let now = Date()
            let dt = lastAdvSeen[peripheral.identifier.uuidString].map { String(format: "%.2f", now.timeIntervalSince($0)) } ?? "-"
            lastAdvSeen[peripheral.identifier.uuidString] = now
            log.default("[ADV] %{public}@ dt=%{public}@s rssi=%{public}@ state=%{public}@ connectable=%{public}@ name=%{public}@ svcUUIDs=[%{public}@] mfg=%{public}@ svcData=%{public}@",
                        peripheral.identifier.uuidString, dt, RSSI, String(describing: peripheral.state.rawValue),
                        String(describing: connectable), name.isEmpty ? "-" : name, svcUUIDs.isEmpty ? "-" : svcUUIDs, mfg, svcData)
            // Field advert logging (kept in production): record each DISTINCT pod advert to the device log
            // so real-world Issue Reports capture what the pod advertises — the raw material for decoding
            // more fault/alert states. Deduped by svcUUIDs|mfg (the advert is stable between state changes,
            // so this logs a transition once, not every ~1Hz frame). Fires whenever we discover the pod —
            // i.e. during each command connect's fresh-discovery scan and on a C00A fault-scan wake.
            if isPodFrame {
                let advKey = "\(svcUUIDs)|\(mfg)|conn=\(String(describing: connectable))"
                if lastLoggedAdvKey[peripheral.identifier.uuidString] != advKey {
                    lastLoggedAdvKey[peripheral.identifier.uuidString] = advKey
                    connectionDelegate?.omnipodLogDeviceEvent("[ADV] svcUUIDs=[\(svcUUIDs.isEmpty ? "-" : svcUUIDs)] mfg=\(mfg) connectable=\(String(describing: connectable)) svcData=\(svcData)")
                }
            }
        } else if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                  BluetoothManager.advertisementMonitorEnabled {
            log.default("[SCAN] ManufacturerData: %{public}@ (%{public}d bytes)", mfgData.hexadecimalString, mfgData.count)
        }

        // Connectionless alarm decode is DASH-specific (parses the DASH iBeacon status word). O5 encodes
        // state differently (see the capture) — never run the DASH decode against an O5 advert. Gated on
        // isOwnPod so a foreign pod that matched the generic C00A filter can't drive detection/connect/probe.
        if isOwnPod && podType.isDash {
            detectPodAlertStatus(peripheral: peripheral, advertisementData: advertisementData)
            // Fresh-discovery connect: we just heard the pod — stop scanning and connect NOW on this
            // fresh advertisement (fast) instead of waiting out iOS's cold reacquisition (~16s).
            if pendingFreshConnectID == peripheral.identifier.uuidString {
                pendingFreshConnectID = nil
                log.default("[connectOnDemand] fresh discovery -> connect %{public}@", peripheral.identifier.uuidString)
                connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] pod heard -> connecting on fresh advert")
                manager.stopScan()
                // Defer the connect one managerQueue tick so the scan actually tears down first.
                // Connecting synchronously here (still inside the scan's didDiscover) starved the
                // connect -> it wedged in .connecting and timed out at 20s. Let iOS settle the
                // stopScan, then connect on the just-heard advert. Direct connect (not freshConnect):
                // the peripheral was just heard and is connectable, so skip the cancel+re-retrieve
                // stale-flush (an In-Play stall workaround) that added a round-trip on the good pod.
                // Deferred one tick so the stopScan settles first — which is exactly the window in
                // which another path (a reclaim ladder's timedConnect) can connect the same pod.
                // Re-check on arrival rather than on scheduling.
                managerQueue.async { [weak self] in
                    guard let self, self.noteConnectIssued(peripheral, via: "adopt-retry") else { return }
                    self.manager.connect(peripheral, options: nil)
                }
            }
            // Kick off / re-arm the delayed-connect probe once we know the pod is present + disconnected.
            issueDelayedConnectProbe(peripheral)
        }

        // O5 connectionless fault-watch. Our O5 pod flips its single service-UUID status suffix from …00
        // (normal) to …02 (attention/fault). Field-validated end-to-end: an induced occlusion flipped the
        // advert to …02, this scan woke the backgrounded app, and the follow-on getPodStatus surfaced
        // "Occluded" (0x14) to the pump manager (see O5_ADVERTISING_FINDINGS.md). Gated on isOwnPod: the
        // controllerId embedded in the UUID can collide across app builds, so a stranger's faulted pod can
        // match the …02 filter; only OUR pod (unique BLE identity) may drive detection. The suffix is a
        // COARSE 4-state signal (00/01/02/03), NOT fault-specific — so we don't decode a fault type from it,
        // we surface it to connect + read the real status (getPodStatus resolves the exact fault/alert), then
        // quiet the scan while it persists. Suffixes 01/03 have not been observed and are intentionally not
        // matched; any other attention state is simply caught on the next status read instead of the scan.
        if isOwnPod, podType.isO5, let o5Fault = o5FaultScanServiceUUID, advSvcUUIDs.contains(o5Fault) {
            log.default("[POD-FAULT] %{public}@ → O5 attention advert (…02) (from advertisement, no connect)", peripheral.identifier.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[POD-FAULT] → O5 attention advert (…02) — connecting to read status")
            surfacePodConditionAndQuiet(alertSet: AlertSet(rawValue: 0))
        }

        if let podAdvertisement = PodAdvertisement(advertisementData, podType: podType) {
            addPeripheral(peripheral, podAdvertisement: podAdvertisement)

            // PODLOAN: adopt an already-paired pod by its advertised ADDRESS. A pod paired on
            // another device stores that device's per-device CoreBluetooth UUID, which means
            // nothing here — the address is the only identifier both devices agree on. Match it,
            // record THIS device's identifier as the pod's, and connect; the session
            // re-establishes from the granted keys.
            if let takeoverId = loanTakeoverPodId, podAdvertisement.podId == takeoverId, peripheral.state == .disconnected {
                let adopted = peripheral.identifier.uuidString
                log.default("PODLOAN: adopting pod 0x%x as %{public}@", takeoverId, adopted)
                // KEEP THE MARKER UNTIL THE CONNECT IS CONFIRMED.
                //
                // This used to clear it here, on merely HEARING a matching advertisement. Field
                // 2026-08-19, one millisecond apart:
                //
                //   07:31:43.285  [loan-scan] marker 0x177e6b7e -> nil (adopted)
                //   07:31:43.294  Pod failed to connect … CBErrorDomain Code=11
                //                 "The system has reached the maximum number of connections"
                //
                // The connect was refused, and the ladder then polled for another twenty seconds
                // with no scan armed and no marker — so connectOnDemand was free to stop and
                // replace whatever scan remained, and a retry had nothing to hear the pod with.
                // An advertisement means the pod is THERE, not that we have it.
                //
                // Cleared instead in didConnect (success) and left standing in didFailToConnect,
                // so a refused connect keeps the scan armed for the next attempt. `cancelLoanScan`
                // still clears it when the reclaim genuinely ends.
                pendingAdoptedLoanPod = adopted
                autoConnectIDs.insert(adopted)
                connectionDelegate?.omnipodDidAdoptLoanPod(uuidString: adopted)
                timedConnect(peripheral)  // takeover — an explicit connect, not auto-reconnect
            } else {
                if discoveryModeEnabled {
                    connectionDelegate?.omnipodLogDeviceEvent("[pairing] heard pod \(peripheral.identifier.uuidString) pairable=\(podAdvertisement.pairable) state=\(peripheral.state.rawValue)")
                }
                if discoveryModeEnabled && podAdvertisement.pairable {
                    // We've heard our target pairable pod — stop the discovery scan so it doesn't starve the
                    // connect (an active allowDuplicates scan wedges the connect in .connecting, which is
                    // what stalled pairing), then connect if it's disconnected. If it's already mid-connect,
                    // stopping the scan lets that connect complete.
                    if manager.isScanning { manager.stopScan() }
                    if peripheral.state == .disconnected {
                        log.default("Connecting to pairable device %{public}@ in discovery mode", peripheral)
                        connectionDelegate?.omnipodLogDeviceEvent("[pairing] connecting to pairable pod \(peripheral.identifier.uuidString)")
                        timedConnect(peripheral)  // pairing — an explicit connect, not auto-reconnect
                    }
                } else if autoConnectIDs.contains(peripheral.identifier.uuidString) && peripheral.state == .disconnected {
                    log.debug("Reonnecting to autoconnect device")
                    autoReconnect(peripheral)
                } else {
                    log.info("Ignoring paired or unconnectable peripheral: %{public}@", peripheral)
                }
            }
        } else {
            log.info("Ignoring peripheral with unexpected advertisement data: %{public}@", advertisementData)
        }
        
        // PODLOAN: never stop while a takeover is armed — with empty autoConnectIDs,
        // hasDiscoveredAllAutoConnectDevices is vacuously true and the first discovery
        // of ANY peripheral would otherwise kill the takeover scan.
        if !BluetoothManager.advertisementMonitorEnabled && !discoveryModeEnabled && loanTakeoverPodId == nil && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.debug("All peripherals discovered")
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        noteConnectClosed(peripheral, how: "resolved")

        // We are connected — any outstanding fresh-discovery cold-connect fallback is now moot. Clearing
        // the token no-ops a still-pending 4s fallback timer (connectViaFreshDiscovery) so it cannot fire
        // freshConnect() → cancelPeripheralConnection() against THIS live link. That stale-timer teardown,
        // re-read by didDisconnect as an unintended "drop", was the root of the self-inflicted
        // connect → cancel → "reconnecting after drop" → reconnect loop.
        // The adoption is only real once the link is up. Until this point the marker stayed
        // armed so the scan could keep hunting through a refused connect.
        if pendingAdoptedLoanPod == peripheral.identifier.uuidString {
            pendingAdoptedLoanPod = nil
            if loanTakeoverPodId != nil {
                loanScanMarkerReason = "adopted+connected"
                loanTakeoverPodId = nil
            }
            connectionDelegate?.omnipodDidAdoptLoanPod(uuidString: peripheral.identifier.uuidString)
        }
        if pendingFreshConnectID == peripheral.identifier.uuidString {
            pendingFreshConnectID = nil
        }

        // Connected — stop the connect-helper scan (connectOnDemand started a light scan to speed the
        // connect). We don't scan while connected; the monitor scan is restored on the next disconnect.
        if manager.isScanning {
            manager.stopScan()
        }

        // Delayed-connect probe: report the delay, then disconnect after a brief hold so the loop
        // re-arms (didDisconnect issues the next probe). Skip the normal session proxy — timing only.
        // A genuine heartbeat-probe wake: the StartDelay connect WE issued completed, and no command
        // is using the link. (A command connect sets commandConnectInFlight and clears delayedProbeInFlight,
        // so it never lands here — that was the old hijack that cancelled real commands after 2s.)
        let treatAsProbe = (delayedProbeInFlight && !commandConnectInFlight)
        if treatAsProbe {
            let measured = delayedProbeIssuedAt.map { String(format: "%.1f", Date().timeIntervalSince($0)) } ?? "?(restored)"
            let startDelayStr = delayedProbeDelay.map { String(format: "%.0f", $0) } ?? "?"
            let pid = ProcessInfo.processInfo.processIdentifier
            log.default("[delayedConnect] pid=%{public}d everFg=%{public}@ CONNECTED after %{public}@s (StartDelay=%{public}@s) %{public}@ — heartbeat wake",
                        pid, String(everForeground), measured, startDelayStr, peripheral.identifier.uuidString)
            connectionDelegate?.omnipodLogDeviceEvent("[delayedConnect] pid=\(pid) everFg=\(everForeground) CONNECTED after \(measured)s (StartDelay=\(startDelayStr)s) — heartbeat wake")
            delayedProbeInFlight = false
            delayedProbeIssuedAt = nil
            delayedProbeDelay = nil
            // Drop the wake connection and fire the heartbeat from didDisconnect (clean idle state), so
            // Loop's resulting status/dose commands run via connect-on-demand rather than fighting this
            // transient probe link.
            pendingHeartbeatFire = true
            noteLinkTornDown(peripheral, by: "didConnect-dupe")
            manager.cancelPeripheralConnection(peripheral)
            return
        }

        if let requestedAt = connectRequestedAt.removeValue(forKey: peripheral.identifier.uuidString) {
            let latency = String(format: "%.3f", Date().timeIntervalSince(requestedAt))
            log.default("[#%{public}@] CONNECTED: %{public}@ — connect latency %{public}@s (known device: %{public}@)",
                        instanceID, peripheral, latency,
                        String(describing: devices.contains { $0.manager.peripheral.identifier == peripheral.identifier }))
        } else {
            log.default("[#%{public}@] CONNECTED: %{public}@ — connect latency unknown (no request stamp) (known device: %{public}@)",
                        instanceID, peripheral, String(describing: devices.contains { $0.manager.peripheral.identifier == peripheral.identifier }))
        }

        // Proxy connection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didConnect: peripheral)
            connectionDelegate?.omnipodPeripheralDidConnect(manager: device.manager)

            // Get an RSSI reading for logging
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("[#%{public}@] DISCONNECTED: %{public}@ error=%{public}@ willReconnect=%{public}@", instanceID, peripheral,
                    String(describing: error), String(describing: autoConnectIDs.contains(peripheral.identifier.uuidString)))

        // Proxy disconnection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didDisconnect: peripheral, error: error)
        }

        connectionDelegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            log.debug("Reconnecting disconnected autoconnect peripheral")
            autoReconnect(peripheral)
        }
        delayedProbeInFlight = false
        if shouldHoldConnection && commandConnectInFlight {
            // Keep-alive (foreground, or a background Pod Keep Alive mode): an unintended drop while we want
            // to stay connected (a deliberate background/idle disconnect clears commandConnectInFlight first,
            // so it won't reconnect).
            log.default("[connectOnDemand] keep-alive — reconnecting after drop")
            connectionDelegate?.omnipodLogDeviceEvent("[connectOnDemand] keep-alive — reconnecting after drop")
            connectViaFreshDiscovery(peripheral)
        } else {
            // Idle: run the fault-listener alarm scan, AND (if a heartbeat is needed) arm the StartDelay
            // probe alongside it. The two coexist — the scan is light and issueDelayedConnectProbe no
            // longer stops it. Re-arm the probe only when idle (never while a command owns the link).
            resumeScanIfNeeded()
            if delayedConnectProbeActive && !commandConnectInFlight && autoConnectIDs.contains(peripheral.identifier.uuidString) {
                issueDelayedConnectProbe(peripheral)
            }
        }
        // If this disconnect ended a heartbeat-probe wake, fire the heartbeat now (clean idle state) so
        // Loop runs its cycle; its commands then preempt the just-armed probe via connect-on-demand.
        if pendingHeartbeatFire {
            pendingHeartbeatFire = false
            log.default("[delayedConnect] firing heartbeat (pumpManagerBLEHeartbeatDidFire)")
            connectionDelegate?.omnipodLogDeviceEvent("[delayedConnect] firing heartbeat (pumpManagerBLEHeartbeatDidFire)")
            connectionDelegate?.omnipodHeartbeatDidFire()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("[#%{public}@] FAILED TO CONNECT: %{public}@ error=%{public}@", instanceID, peripheral, String(describing: error))

        noteConnectClosed(peripheral, how: "refused")
        lastConnectFailure = (id: peripheral.identifier.uuidString,
                              code: (error as NSError?).map { "\($0.domain)#\($0.code)" } ?? "no-error",
                              at: Date())

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        // A refused adoption keeps the marker, so the scan stays armed for the next advertisement
        // rather than leaving the ladder blind. Named loudly because Code=11 ("maximum number of
        // connections") is a SYSTEM state, not a pod fault, and reads as one in a bare log.
        if pendingAdoptedLoanPod == peripheral.identifier.uuidString {
            pendingAdoptedLoanPod = nil
            let code = (error as NSError?).map { "\($0.domain)#\($0.code)" } ?? "no-error"
            connectionDelegate?.omnipodLogDeviceEvent(
                "[loan-scan] adoption connect FAILED (\(code)) — marker HELD, scan stays armed for the next advert")
        }

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            autoReconnect(peripheral)
        }
        delayedProbeInFlight = false
        resumeScanIfNeeded()   // keep the fault-listener alarm scan running while idle
        if delayedConnectProbeActive && !commandConnectInFlight && autoConnectIDs.contains(peripheral.identifier.uuidString) {
            // Re-arm AFTER a backoff — a synchronously-failing connect (bad parameters, radio off, pod
            // gone) must never re-issue at CPU speed. Re-fetch and re-check state after the delay.
            let id = peripheral.identifier.uuidString
            managerQueue.asyncAfter(deadline: .now() + BluetoothManager.heartbeatFailureBackoffSeconds) { [weak self] in
                guard let self = self,
                      self.delayedConnectProbeActive, !self.commandConnectInFlight, !self.delayedProbeInFlight,
                      self.autoConnectIDs.contains(id),
                      let p = self.devices.first(where: { $0.manager.peripheral.identifier.uuidString == id })?.manager.peripheral,
                      p.state == .disconnected else { return }
                self.issueDelayedConnectProbe(p)
            }
        }
    }
}
