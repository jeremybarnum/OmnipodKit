//
//  PodStateTests.swift
//  OmniTests
//
//  From OmniBLE/OmniBLETests/PodStateTests.swift
//  Created by Pete Schwamb on 10/13/17.
//  Copyright © 2017 Pete Schwamb. All rights reserved.
//

import XCTest
@testable import OmnipodKit

class PodStateTests: XCTestCase {
    
    func testErrorResponse() {
        do {
            let errorResponse = try ErrorResponse(encodedData: Data(hexadecimalString: "0603070008019a")!)

            switch errorResponse.errorResponseType {
            case .nonretryableError(let errorCode, let faultEventCode, let podProgress):
                XCTAssertEqual(7, errorCode)
                XCTAssertEqual(.noFaults, faultEventCode.faultType)
                XCTAssertEqual(.aboveFiftyUnits, podProgress)
                break
            default:
                XCTFail("Unexpected bad nonce response")
                break
            }
        } catch (let error) {
            XCTFail("message decoding threw error: \(error)")
        }
    }

    // PODLOAN (2026-10-23, from next-dev 3ea82ce): after another controller has run the pod, a bolus
    // the pod reports that this driver did not command is that controller's, already in its records.
    // Booking it here too double-counted a watch bolus on a Take Back (3.6 U booked for 2 U).
    func testABolusAnotherControllerStartedIsNotBookedAfterAForeignSession() {
        var pod = PodState(address: 0x1f0b3557, firmwareVersion: "2.7.0", iFirmwareVersion: "2.7.0", lotNo: 43620,
                           lotSeq: 560313, insulinType: .novolog, podType: dashType,
                           ltk: Data(hexadecimalString: "fedcba98765432100123456789abcdef")!, bleIdentifier: "0000-0000")
        pod.setupProgress = .completed
        func status(_ delivery: DeliveryStatus, notDelivered: Double) -> StatusResponse {
            StatusResponse(deliveryStatus: delivery, podProgressStatus: .aboveFiftyUnits, timeActive: .hours(10),
                           reservoirLevel: Pod.reservoirLevelAboveThresholdMagicNumber, insulinDelivered: 13,
                           bolusNotDelivered: notDelivered, lastProgrammingMessageSeqNum: 5, alerts: AlertSet(slots: []))
        }

        pod.untrackedDeliveryIsForeign = true          // the session resynced: another controller ran the pod
        pod.updateFromStatusResponse(status(.bolusInProgress, notDelivered: 1.6))
        XCTAssertNil(pod.unfinalizedBolus, "the other controller's bolus is not booked as this driver's")
        XCTAssertTrue(PodState(rawValue: pod.rawValue)?.untrackedDeliveryIsForeign == true, "survives a relaunch")

        pod.updateFromStatusResponse(status(.scheduledBasal, notDelivered: 0))
        XCTAssertFalse(pod.untrackedDeliveryIsForeign, "cleared once no bolus is running")

        // Its own lost tracking (no foreign session) is still captured, as stock does.
        pod.updateFromStatusResponse(status(.bolusInProgress, notDelivered: 0.5))
        XCTAssertNotNil(pod.unfinalizedBolus)
    }
}
