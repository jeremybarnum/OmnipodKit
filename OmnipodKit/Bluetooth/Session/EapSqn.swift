//
//  EapSqn.swift
//  OmnipodKit
//
//  From OmniBLE/OmniBLE/Bluetooth/Session/EapSqn.swift
//  Created by Randall Knutson on 11/17/21.
//  Copyright © 2021 LoopKit Authors. All rights reserved.
//

import Foundation

enum EapSqnError: Error {
    case InvalidSize
}

class EapSqn {
    private let SIZE = 6
    let data: Data
    
    init(data: Data)  throws {
        guard data.count == SIZE else { throw EapSqnError.InvalidSize }
        self.data = data
    }
    
    init(int: Int) {
        self.data = withUnsafeBytes(of: Int64(int).bigEndian) { Data($0) }
    }
    
    func toInt() -> Int {
        // Byte by byte: loading an Int reads only 4 of the 8 bytes on 32-bit watches.
        return Int(data.reduce(Int64(0)) { $0 << 8 | Int64($1) })
    }
    
    func increment() -> EapSqn {
        return EapSqn(int: toInt() + 1)
    }
}
