//
//  PodCommsSessionTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodCommsSessionTests.swift
//  Created by Pete Schwamb on 3/25/19.
//  Copyright © 2019 Pete Schwamb. All rights reserved.
//

import Foundation

import XCTest
import LoopKit
@testable import OmnipodKit

class MockMessageTransport: MessageTransport {
    var delegate: MessageTransportDelegate?

    var messageNumber: Int

    var responseMessageBlocks = [MessageBlock]()
    var sentMessages = [Message]()

    var address: UInt32

    var sentMessageHandler: ((Message) -> Void)?

    init(address: UInt32, messageNumber: Int) {
        self.address = address
        self.messageNumber = messageNumber
    }

    func sendMessage(_ message: Message) throws -> Message {
        sentMessages.append(message)
        if responseMessageBlocks.isEmpty {
            throw PodCommsError.noResponse
        }
        return Message(address: address, messageBlocks: [responseMessageBlocks.removeFirst()], sequenceNum: messageNumber)
    }

    func addResponse(_ messageBlock: MessageBlock) {
        responseMessageBlocks.append(messageBlock)
    }

    func assertOnSessionQueue() {
        // Do nothing in tests
    }
}

class PodCommsSessionTests: XCTestCase, PodCommsSessionDelegate {

    var lastPodStateUpdate: PodState?

    let address: UInt32 = 521580830
    let fakeLtk = Data(hexadecimalString: "fedcba98765432100123456789abcdef")!
    var mockTransport: MockMessageTransport! = nil
    var podState: PodState! = nil

    override func setUp() {
        mockTransport = MockMessageTransport(address: address, messageNumber: 1)
        podState = PodState(address: address, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620, lotSeq: 560313, insulinType: .novolog, podType: dashType, ltk: fakeLtk, bleIdentifier: "0000-0000")
    }

    func podCommsSession(_ podCommsSession: PodCommsSession, didChange state: PodState) {
        lastPodStateUpdate = state
    }

    func testBolusFinishedEarlyOnPodIsMarkedNonMutable() {
         let mockStart = Date()
         podState.unfinalizedBolus = UnfinalizedDose(decisionId: nil, bolusAmount: 4.45, startTime: mockStart, scheduledCertainty: .certain, insulinType: .novolog)
         let session = PodCommsSession(podState: podState, transport: mockTransport, delegate: self)

         // Simulate a status request a bit before the bolus is expected to finish
         let statusRequestTime = podState.unfinalizedBolus!.finishTime!.addingTimeInterval(-5)
         session.mockCurrentDate = statusRequestTime

         let statusResponse = StatusResponse(
             deliveryStatus: .scheduledBasal,
             podProgressStatus: .aboveFiftyUnits,
             timeActive: .minutes(10),
             reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber,
             insulinDelivered: 25,
             bolusNotDelivered: 0,
             lastProgrammingMessageSeqNum: 5,
             alerts: AlertSet(slots: []))

         mockTransport.addResponse(statusResponse)

         let _ = try! session.getStatus()

         XCTAssertEqual(1, lastPodStateUpdate!.finalizedDoses.count)

         let finalizedBolus = lastPodStateUpdate!.finalizedDoses[0]

         XCTAssertTrue(finalizedBolus.isFinished(at: statusRequestTime))
         XCTAssertFalse(finalizedBolus.isMutable(at: statusRequestTime))
     }

    // MARK: - PODLOAN #72: re-arming the C5-cancelled inherited running temp

    private func makeRunningTemp(rate: Double = 2.0, startedMinutesAgo: TimeInterval = 10, durationMinutes: TimeInterval = 30) -> UnfinalizedDose {
        return UnfinalizedDose(tempBasalRate: rate,
                               startTime: Date().addingTimeInterval(-startedMinutesAgo * 60),
                               duration: durationMinutes * 60,
                               isHighTemp: true, automatic: true,
                               scheduledCertainty: .certain, insulinType: .novolog)
    }

    /// The C5 handover cancel must be exactly reversible: after re-arm the temp is mutable
    /// again with its full programmed extent — the state the WATCH needs so IOB tracks the
    /// live delivery instead of freezing at the handover stamp.
    func testPodLoanRearmReversesC5Cancel() {
        var temp = makeRunningTemp()   // 2.0 U/hr × 30 min = 1.0 U programmed, 10 min in
        let programmedUnits = temp.units
        let programmedFinish = temp.finishTime!
        XCTAssertTrue(temp.isMutable())

        temp.cancel(at: Date())        // C5: releaseConnection's record-close at handover
        XCTAssertFalse(temp.isMutable(), "C5-cancelled temp reads finished — the pre-#72 freeze")
        XCTAssertNotNil(temp.scheduledUnits, "cancel stamps the programmed total (the C5 signature)")

        XCTAssertTrue(temp.podLoanRearmHandoverCancel())
        XCTAssertTrue(temp.isMutable(), "re-armed temp is live again — mutable re-reports track IOB")
        XCTAssertEqual(temp.units, programmedUnits, accuracy: 1e-9)
        XCTAssertEqual(temp.finishTime!.timeIntervalSince1970, programmedFinish.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(temp.scheduledUnits, "signature cleared — re-arm is one-shot")
    }

    /// The grant-blob path: cancel → rawValue (what the phone serializes) → decode (what the
    /// watch inherits) → re-arm. This is the layer the 2026-07-28 adversarial review flagged
    /// as untested — the C5 fields must survive the plist round-trip for the re-arm to work.
    func testPodLoanRearmSurvivesRawValueRoundTrip() {
        var temp = makeRunningTemp()
        let programmedFinish = temp.finishTime!
        temp.cancel(at: Date())

        guard var inherited = UnfinalizedDose(rawValue: temp.rawValue) else {
            return XCTFail("rawValue round-trip failed")
        }
        XCTAssertFalse(inherited.isMutable(), "the inherited copy arrives C5-cancelled")
        XCTAssertTrue(inherited.podLoanRearmHandoverCancel(), "C5 fields must survive serialization")
        XCTAssertTrue(inherited.isMutable())
        XCTAssertEqual(inherited.finishTime!.timeIntervalSince1970, programmedFinish.timeIntervalSince1970, accuracy: 0.001)
    }

    /// PODLOAN #72 copy-divergence fix: the PodState-level shared transform — the SAME guarded
    /// re-arm now applied to both the manager's copy and BlePodComms' session-facing copy
    /// (the 2026-07-29 field finding: the setState-only re-arm never reached the copy that
    /// reports doses, so the store froze the inherited temp at the handover stamp).
    func testPodLoanPodStateRearmSharedTransform() {
        var temp = makeRunningTemp()
        let programmedFinish = temp.finishTime!
        let liveStart = temp.startTime
        temp.cancel(at: Date())
        podState.unfinalizedTempBasal = temp

        // Matching live record → re-arm applies to the PodState in place.
        let rearmed = podState.podLoanRearmInheritedTempBasal(liveTempStart: liveStart, liveTempEnd: programmedFinish)
        XCTAssertNotNil(rearmed)
        XCTAssertTrue(podState.unfinalizedTempBasal!.isMutable(),
                      "the copy sessions report from must carry the temp LIVE — mutable full-span re-reports")
        XCTAssertEqual(podState.unfinalizedTempBasal!.finishTime!.timeIntervalSince1970,
                       programmedFinish.timeIntervalSince1970, accuracy: 0.001)

        // Idempotent through the PodState layer too (signature cleared by the first pass).
        XCTAssertNil(podState.podLoanRearmInheritedTempBasal(liveTempStart: liveStart, liveTempEnd: programmedFinish))
    }

    /// The shared transform must keep the adversarial-review guard: a live-record start that
    /// doesn't match the inherited temp (superseded across back-to-back loans) is refused and
    /// the PodState is left untouched.
    func testPodLoanPodStateRearmRejectsMismatchedLiveRecord() {
        var temp = makeRunningTemp()
        temp.cancel(at: Date())
        let cancelled = temp
        podState.unfinalizedTempBasal = cancelled

        let mismatchedStart = cancelled.startTime.addingTimeInterval(5.0)
        XCTAssertNil(podState.podLoanRearmInheritedTempBasal(liveTempStart: mismatchedStart, liveTempEnd: nil))
        XCTAssertFalse(podState.unfinalizedTempBasal!.isMutable(), "guard reject must leave the C5 cancel in place")
        XCTAssertEqual(podState.unfinalizedTempBasal!.scheduledUnits, cancelled.scheduledUnits,
                       "state untouched on reject — the C5 signature survives for a later matching re-arm")

        // Empty PodState: clean nil, no crash.
        podState.unfinalizedTempBasal = nil
        XCTAssertNil(podState.podLoanRearmInheritedTempBasal(liveTempStart: Date(), liveTempEnd: nil))
    }

    /// Selectivity + idempotency: re-arm touches ONLY C5-cancelled temps — a second call, a
    /// never-cancelled temp, and a cancelled bolus must all refuse.
    func testPodLoanRearmIdempotentAndSelective() {
        var temp = makeRunningTemp()
        XCTAssertFalse(temp.podLoanRearmHandoverCancel(), "never-cancelled temp: nothing to re-arm")
        temp.cancel(at: Date())
        XCTAssertTrue(temp.podLoanRearmHandoverCancel())
        XCTAssertFalse(temp.podLoanRearmHandoverCancel(), "idempotent — signature cleared by first re-arm")

        var bolus = UnfinalizedDose(bolusAmount: 2.0, startTime: Date().addingTimeInterval(-10),
                                    scheduledCertainty: .certain, insulinType: .novolog)
        bolus.cancel(at: Date())
        XCTAssertFalse(bolus.podLoanRearmHandoverCancel(), "boluses are never C5-cancelled — refuse")
    }

    /// Identity stability across the whole lifecycle: the NewPumpEvent raw (uniqueKey) must be
    /// byte-identical pre-cancel / post-cancel / post-re-arm, or the #69 dedup layers split the
    /// dose into multiple identities again.
    func testPodLoanRearmPreservesUniqueKeyIdentity() {
        var temp = makeRunningTemp()
        let preCancelRaw = NewPumpEvent(temp).raw
        temp.cancel(at: Date())
        XCTAssertEqual(NewPumpEvent(temp).raw, preCancelRaw, "cancel is identity-stable (scheduledUnits ?? units)")
        _ = temp.podLoanRearmHandoverCancel()
        XCTAssertEqual(NewPumpEvent(temp).raw, preCancelRaw, "re-arm is identity-stable too")
    }

    /// A 0 U/hr temp (Loop's standard predicted-low — plausible at sport start): the cancel
    /// math destroys its span (scheduledUnits=0, scheduledTempRate=0 → 0/0), so the re-arm
    /// must restore it from the grant record's programmed end — and must REFUSE without one
    /// rather than fabricate a span.
    func testPodLoanRearmZeroRateTempNeedsRecordEnd() {
        let programmedEnd = Date().addingTimeInterval(20 * 60)
        var temp = makeRunningTemp(rate: 0.0, startedMinutesAgo: 10, durationMinutes: 30)
        temp.cancel(at: Date())
        XCTAssertFalse(temp.isMutable())

        var noFallback = temp
        XCTAssertFalse(noFallback.podLoanRearmHandoverCancel(), "rate-0 span is unrecoverable without the record end — refuse")

        XCTAssertTrue(temp.podLoanRearmHandoverCancel(programmedEnd: programmedEnd))
        XCTAssertTrue(temp.isMutable(), "restored from the grant record — live again")
        XCTAssertEqual(temp.units, 0, accuracy: 1e-9, "a 0-rate temp delivers nothing")
        XCTAssertEqual(temp.finishTime!.timeIntervalSince1970, programmedEnd.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A temp whose programmed end passed before the takeover completes: re-arm restores the
    /// full span and the dose reads finished — the pod really did deliver it all (nobody sent
    /// a cancel while the phone had released the connection), so booking full units is truth.
    func testPodLoanRearmExpiredTempBooksFullSpan() {
        // Started 40 min ago, 30-min programmed span, C5-cancelled 5 min before its end.
        var temp = makeRunningTemp(rate: 2.0, startedMinutesAgo: 40, durationMinutes: 30)
        let programmedUnits = 2.0 * 0.5
        temp.cancel(at: temp.startTime.addingTimeInterval(25 * 60))   // handover at +25 min

        XCTAssertTrue(temp.podLoanRearmHandoverCancel())
        XCTAssertTrue(temp.isFinished(), "programmed end already passed — reads finished")
        XCTAssertFalse(temp.isMutable())
        XCTAssertEqual(temp.units, programmedUnits, accuracy: 1e-9, "full programmed delivery is booked — the pod ran it to expiry")
    }
}
