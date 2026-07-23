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

    /// PODLOAN: a loan takeover scan adopted the pod as `uuidString` (this device's own
    /// peripheral UUID). The delegate must record it as the pod's bleIdentifier so the
    /// connection/session path recognizes the peripheral.
    func omnipodDidAdoptLoanPod(uuidString: String)
}

extension OmniConnectionDelegate {
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
    private var loanTakeoverPodId: UInt32? = nil

    /// The uuidPdmId is set after pairing...
    private var uuidPdmId: UInt32? = nil

    /// PODLOAN: arm loan-takeover — scan for the pod with this address and adopt the
    /// peripheral this device discovers (its own CoreBluetooth UUID), rather than the
    /// foreign identifier from the granted pod state.
    func beginLoanTakeover(podId: UInt32) {
        managerQueue.async {
            self.loanTakeoverPodId = podId
            if self.manager.state == .poweredOn {
                self.log.default("PODLOAN: begin takeover scan for pod 0x%x", podId)
                if !self.manager.isScanning {
                    self.startScanning()
                }
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

    init(podType: PodType) {
        self.podType = podType
        super.init()

        managerQueue.sync {
#if os(iOS) // watchOS has no CoreBluetooth state restoration; the watch host owns reconnect policy
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.OmnipodKit"])
#else
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: nil)
#endif
        }
    }

#if os(watchOS)
    /// PODLOAN E4 self-heal. The watch orphans the pod between doses; a reclaim that
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
        manager.delegate = nil
        devices.removeAll()
        manager = CBCentralManager(delegate: self, queue: managerQueue, options: nil)
    }
#endif

    @discardableResult
    private func addPeripheral(_ peripheral: CBPeripheral, podAdvertisement: PodAdvertisement?) -> Omni {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        var device: Omni! = devices.first(where: { $0.manager.peripheral.identifier == peripheral.identifier })

        if let device = device {
            log.default("Matched peripheral %{public}@ to existing device: %{public}@", peripheral, String(describing: device))
            device.manager.peripheral = peripheral
            if let podAdvertisement = podAdvertisement {
                device.advertisement = podAdvertisement
            }
        } else {
            device = Omni(peripheralManager: PeripheralManager(peripheral: peripheral, podType: podType, centralManager: manager), advertisement: podAdvertisement)
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
                self.manager.connect(peripheral, options: nil)
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
            manager.connect(peripheral, options: nil)
            log.default("retrieveAndConnectKnownPod: initiating connection to %{public}@", peripheral)
            result = device
        }
        return result
    }
    
    func disconnectFromDevice(uuidString: String) {
        managerQueue.async {
            self.autoConnectIDs.remove(uuidString)
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
                    manager.connect(peripheral, options: nil)
                }
            } else {
                switch peripheral.state {
                case .connected:
                    log.info("updateConnections: Disconnecting from peripheral: %{public}@", peripheral)
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
        for device in devices {
            let peripheral = device.manager.peripheral
            if peripheral.state == .disconnected || peripheral.state == .disconnecting {
                log.info("discoverPods: Connecting to peripheral: %{public}@", peripheral)
                manager.connect(peripheral, options: nil)
            }
        }
        startScanning()

        completion(nil)
    }

    private func startScanning() {
        let serviceUUID: CBUUID
        if podType.isO5, let pdmId = uuidPdmId {
            // The O5 service advertisement UUID is now using the pdmId
            serviceUUID = o5ServiceAdvertisementUUID(pdmId)
        } else {
            serviceUUID = podType.blePodProfile.advertisementServiceUUID
        }
        log.default("Start scanning for %{public}@", serviceUUID.uuidString)
        manager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func stopScanning() {
        log.default("Stop scanning")
        manager.stopScan()
    }

    // MARK: - Accessors

    func getConnectedDevices() -> [Omni] {
        var connected: [Omni] = []
        managerQueue.sync {
            connected = self.devices.filter { $0.manager.peripheral.state == .connected }
        }
        return connected
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

        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        if case .poweredOn = central.state {
            // bluetooth may have reset; update peripheral references
            for device in devices {
                if let newPeripheral = central.retrievePeripherals(withIdentifiers: [device.manager.peripheral.identifier]).first {
                    log.debug("Re-connecting to known peripheral %{public}@", newPeripheral.identifier.uuidString)
                    device.manager.peripheral = newPeripheral
                    central.connect(newPeripheral)
                }
            }

            // Recover peripherals from autoConnectIDs that aren't yet in devices.
            // This handles the user-terminated app restart where willRestoreState wasn't called.
            let knownDeviceIDs = Set(devices.map { $0.manager.peripheral.identifier.uuidString })
            for uuidString in autoConnectIDs where !knownDeviceIDs.contains(uuidString) {
                if let uuid = UUID(uuidString: uuidString),
                   let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first
                {
                    log.default("Recovered peripheral from autoConnectIDs: %{public}@", uuidString)
                    addPeripheral(peripheral, podAdvertisement: nil)
                    central.connect(peripheral, options: nil)
                }
            }

            updateConnections()
            
            // PODLOAN: an armed takeover is a first-class scan reason. beginLoanTakeover
            // races this central to poweredOn (it arms milliseconds after init), and the
            // takeover's autoConnectIDs are empty (the grant rides a released connection),
            // which makes hasDiscoveredAllAutoConnectDevices vacuously true — the stock
            // condition alone would never scan.
            if (discoveryModeEnabled || loanTakeoverPodId != nil || !hasDiscoveredAllAutoConnectDevices) && !manager.isScanning {
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

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@, %{public}@", #function, peripheral, advertisementData)

        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            log.default("[SCAN] ManufacturerData: %{public}@ (%{public}d bytes)", mfgData.hexadecimalString, mfgData.count)
        }

        if let podAdvertisement = PodAdvertisement(advertisementData, podType: podType) {
            addPeripheral(peripheral, podAdvertisement: podAdvertisement)

            // PODLOAN: adopt an already-paired pod by its advertised ADDRESS (the phone's
            // per-device peripheral UUID is useless here). Match, record THIS device's
            // identifier as the pod's, and connect — the session re-establishes from the
            // granted keys.
            if let takeoverId = loanTakeoverPodId, podAdvertisement.podId == takeoverId, peripheral.state == .disconnected {
                let adopted = peripheral.identifier.uuidString
                log.default("PODLOAN: adopting pod 0x%x as %{public}@", takeoverId, adopted)
                loanTakeoverPodId = nil
                autoConnectIDs.insert(adopted)
                connectionDelegate?.omnipodDidAdoptLoanPod(uuidString: adopted)
                manager.connect(peripheral, options: nil)
            } else if discoveryModeEnabled && peripheral.state == .disconnected && podAdvertisement.pairable {
                // Connect to any pairable device, during discovery
                log.default("Connecting to pairable device %{public} in discovery mode", peripheral)
                manager.connect(peripheral, options: nil)
            } else if autoConnectIDs.contains(peripheral.identifier.uuidString) && peripheral.state == .disconnected {
                log.debug("Reonnecting to autoconnect device")
                manager.connect(peripheral, options: nil)
            } else {
                log.info("Ignoring paired or unconnectable peripheral: %{public}@", peripheral)
            }
        } else {
            log.info("Ignoring peripheral with unexpected advertisement data: %{public}@", advertisementData)
        }
        
        // PODLOAN: never stop while a takeover is armed — with empty autoConnectIDs,
        // hasDiscoveredAllAutoConnectDevices is vacuously true and the first discovery
        // of ANY peripheral would otherwise kill the takeover scan.
        if !discoveryModeEnabled && loanTakeoverPodId == nil && central.isScanning && hasDiscoveredAllAutoConnectDevices {
            log.debug("All peripherals discovered")
            stopScanning()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.debug("%{public}@: %{public}@", #function, peripheral)
        
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

        // Proxy disconnection events to peripheral manager
        for device in devices where device.manager.peripheral.identifier == peripheral.identifier {
            device.manager.centralManager(central, didDisconnect: peripheral, error: error)
        }

        connectionDelegate?.omnipodPeripheralDidDisconnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            log.debug("Reconnecting disconnected autoconnect peripheral")
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("%{public}@: %{public}@", #function, String(describing: error))

        connectionDelegate?.omnipodPeripheralDidFailToConnect(peripheral: peripheral, error: error)

        if autoConnectIDs.contains(peripheral.identifier.uuidString) {
            central.connect(peripheral, options: nil)
        }
    }
}
