//
//  File.swift
//  BlutoothLan
//
//  Created by Erlan Kanybekov on 10/17/25.
//

import SwiftUI
import CoreBluetooth
// MARK: - Utilities

extension Data {
    func hexString(spaced: Bool = false) -> String {
        let hex = self.map { String(format: "%02X", $0) }.joined()
        if spaced {
            return stride(from: 0, to: hex.count, by: 2).map { idx in
                let start = hex.index(hex.startIndex, offsetBy: idx)
                let end = hex.index(start, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                return String(hex[start..<end])
            }.joined(separator: " ")
        }
        return hex
    }
}
