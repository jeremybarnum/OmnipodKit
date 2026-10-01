//
//  UIDevice+watchOS.swift
//  OmnipodKit
//
//  watchOS has no UIDevice, and Common/UIDevice.swift is excluded from the watch target. The BLE
//  layer's affected-iPhone checks (UIDevice.hasPossibleInPlayBLEIssues) still have to compile there,
//  and a watch host is never an affected iPhone, so they read false. Same idea as HostAppState:
//  keep the platform split in one place instead of guarding every call site.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

#if os(watchOS)
import Foundation

enum UIDevice {
    static var hasPossibleInPlayBLEIssues: Bool { false }
}
#endif
