//
//  DataExtensions.swift
//  PlayCover
//

import Foundation

extension String {
    init(data: Data, offset: Int, commandSize: Int, loadCommandString: lc_str) {
        let loadCommandStringOffset = Int(loadCommandString.offset)
        let stringOffset = offset + loadCommandStringOffset
        let length = commandSize - loadCommandStringOffset
        let rawData = data[stringOffset..<(stringOffset + length)]
        let endIndex = rawData.firstIndex(of: 0x00) ?? rawData.endIndex
        self = String(data: data[stringOffset..<endIndex], encoding: .utf8)
            ?? String(data: data[stringOffset..<endIndex], encoding: .ascii)
            ?? ""
    }
}

extension Data {
    func extract<T>(_ type: T.Type, offset: Int = 0,
                    swap: ((UnsafeMutablePointer<T>, NXByteOrder) -> Void)? = nil) -> T {
        let endOffset = offset + MemoryLayout<T>.size
        guard offset >= 0, endOffset <= self.count else {
            // Return zeroed-out value as fallback for corrupted/truncated data
            var zero = T.init()
            return zero
        }
        let data = self[offset..<endOffset]
        var result = data.withUnsafeBytes { dataBytes -> T in
            guard let baseAddress = dataBytes.baseAddress else {
                var zero = T.init()
                return zero
            }
            return baseAddress
                .assumingMemoryBound(to: UInt8.self)
                .withMemoryRebound(to: T.self, capacity: 1) { $0.pointee }
        }
        swap?(&result, NXHostByteOrder())
        return result
    }
}
