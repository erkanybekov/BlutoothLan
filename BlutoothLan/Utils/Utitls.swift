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
    
    init?(hexString: String) {
        let cleanHex = hexString.replacingOccurrences(of: " ", with: "")
        let len = cleanHex.count / 2
        var data = Data(capacity: len)
        var index = cleanHex.startIndex
        
        for _ in 0..<len {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            guard let byte = UInt8(cleanHex[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
    
    /// Попытка декодировать Data как ASCII/UTF-8 текст
    /// Возвращает nil если данные не являются читаемым текстом
    func asReadableText() -> String? {
        // Пробуем декодировать как UTF-8
        guard let string = String(data: self, encoding: .utf8) else {
            return nil
        }
        
        // Убираем управляющие символы
        let cleaned = string.trimmingCharacters(in: .controlCharacters)
        
        // Проверяем что большинство символов печатаемые
        let printableCount = cleaned.unicodeScalars.filter { scalar in
            // Печатаемые ASCII (32-126) + кириллица + другие буквы/цифры
            (scalar.value >= 32 && scalar.value <= 126) ||
            scalar.properties.isAlphabetic ||
            scalar.properties.isHexDigit ||
            CharacterSet.punctuationCharacters.contains(scalar) ||
            CharacterSet.symbols.contains(scalar)
        }.count
        
        // Если меньше 70% символов печатаемые — не показываем как текст
        guard cleaned.count > 0, Double(printableCount) / Double(cleaned.count) >= 0.7 else {
            return nil
        }
        
        return cleaned
    }
    
    /// Декодирует hex байты и показывает как текст (если возможно) + hex
    func formattedDisplay() -> (text: String?, hex: String) {
        return (asReadableText(), hexString(spaced: true))
    }
}
