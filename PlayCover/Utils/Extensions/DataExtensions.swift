//
//  DataExtensions.swift
//  PlayCover
//

import Foundation

extension String {
    init(data: Data, offset: Int, commandSize: Int, loadCommandString: lc_str) {
        let loadCommandStringOffset = Int(loadCommandString.offset)
        guard offset >= 0,
              loadCommandStringOffset >= 0,
              loadCommandStringOffset <= Int.max - offset else {
            self = ""
            return
        }
        let stringOffset = offset + loadCommandStringOffset
        let length = commandSize - loadCommandStringOffset
        guard length >= 0,
              stringOffset >= data.startIndex,
              stringOffset <= data.endIndex,
              length <= data.endIndex - stringOffset else {
            self = ""
            return
        }
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
        let size = MemoryLayout<T>.size
        guard offset >= 0, size <= self.count - offset else {
            // Return zeroed-out value as fallback for corrupted/truncated data
            return Data.zeroed(T.self)
        }
        let endOffset = offset + size
        var result = Data.zeroed(T.self)
        withUnsafeMutableBytes(of: &result) { destination in
            copyBytes(to: destination, from: offset..<endOffset)
        }
        swap?(&result, NXHostByteOrder())
        return result
    }

    private static func zeroed<T>(_ type: T.Type) -> T {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                                       alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        return pointer.load(as: T.self)
    }
}
