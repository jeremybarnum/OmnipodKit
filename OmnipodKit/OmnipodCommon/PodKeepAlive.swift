//
//  PodKeepAlive.swift
//  OmnipodKit
//
//  Created by Joe Moran on 7/21/26.
//  Copyright © 2026 Joe Moran. All rights reserved.
//

import Foundation

enum PodKeepAlive: Int, CaseIterable, Codable {
    case disabled
    case whenOpen
    case silentTune
    case rileyLink

    var title: String {
        switch self {
        case .disabled:
            return LocalizedString("Disabled", comment: "Title string for PodKeepAlive.disabled")
        case .whenOpen:
            return "" /// N/A as only background PKA options should be displayed
        case .silentTune:
            return LocalizedString("Silent Tune", comment: "Title string for PodKeepAlive.silentTune")
        case .rileyLink:
            return LocalizedString("RileyLink", comment: "Title string for PodKeepAlive.rileyLink")
        }
    }

    /// The displayed UI title string; maps "When Open" to "Disabled" as it is not a background option
    var displayTitle: String {
        switch self {
        case .disabled, .silentTune, .rileyLink:
            return self.title
        case .whenOpen:
            return PodKeepAlive.disabled.title /// display this internal only foreground mode as disabled
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return LocalizedString("Background keep alive is off (default).", comment: "Description for PodKeepAlive.disabled")
        case .whenOpen:
            return "" /// N/A as only background PKA options should be displayed
        case .silentTune:
            return LocalizedString("Background keep alive enabled using a silent tune. If silent tune is interrupted by other apps, pod keep alive will stop working. The silent tune consumes extra iPhone battery.", comment: "Description for PodKeepAlive.silentTune")
        case .rileyLink:
            return LocalizedString("Background keep alive enabled using a selected RileyLink-compatible device in the pump view that is in Bluetooth range. This method uses less iPhone battery than the Silent Tune method.",
                comment: "Description for PodKeepAlive.rileyLink")
        }
    }

    /// Modes that keep the pod connected even while the app is backgrounded / phone locked (silentTune via
    /// a background silent-tune, rileyLink via a BLE wake device). The connection layer holds the pod
    /// connected in these modes instead of applying connect-on-demand's idle/background disconnect.
    /// `.whenOpen` keeps alive only while foregrounded (already covered by the foreground keep-alive), and
    /// `.disabled` is nominal connect-on-demand — both are false here.
    var keepsPodConnectedInBackground: Bool {
        switch self {
        case .disabled:
            return false /// No additional pod status requests to keep pod connected
        case .whenOpen:
            return false /// Only tries to keep pod connected when in foreground
        case .silentTune:
            return true /// Always tries to stay connected by playing a silent tune in background
        case .rileyLink:
            return true /// Always tries to stay connected by using RileyLink BLE wakeups
        }
    }

    /// Modes that use a timer based keep alive either in foreground or background.
    var usesTimerBasedKeepAlives: Bool {
        switch self {
        case .disabled:
            return false /// No additional pod status requests to keep pod connected
        case .whenOpen:
            return true /// Uses timer based keep alives when in foreground
        case .silentTune:
            return true /// Uses timer based keep alives, both when in foreground and in background
        case .rileyLink:
            return false /// Uses BLE wakeups instead of timers
        }
    }
}

/// Return the default Pod Keep Alive value for the given podType
func defaultPodKeepAliveValue(podType: PodType) -> PodKeepAlive {
    if podType.isDash || podType.isO5 {
        /// Default value for all BLE pod types to improve the user experience,
        /// but displayed as disabled as only background PKA modes are shown.
        return .whenOpen
    }
    return .disabled
}
