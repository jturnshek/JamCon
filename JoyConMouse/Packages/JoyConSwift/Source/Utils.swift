//
//  Utils.swift
//  JoyConSwift
//
//  Created by magicien on 2019/06/16.
//  Copyright © 2019 DarkHorse. All rights reserved.
//
//  Modified: Fixed alignment crash on Apple Silicon (arm64e)
//  by reading bytes individually instead of using withMemoryRebound

import Foundation
import Darwin

// Convert mach absolute time ticks to seconds using cached timebase info
private let machTimebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func MachTicksToSeconds(_ ticks: UInt64) -> TimeInterval {
    // mach_absolute_time units -> nanoseconds -> seconds
    let nanos = (ticks * UInt64(machTimebase.numer)) / UInt64(machTimebase.denom)
    return TimeInterval(Double(nanos) / 1_000_000_000.0)
}

func ReadInt16(from ptr: UnsafePointer<UInt8>) -> Int16 {
    // Read little-endian Int16 byte-by-byte (avoids alignment issues on arm64e)
    return Int16(bitPattern: UInt16(ptr[0]) | (UInt16(ptr[1]) << 8))
}

func ReadUInt16(from ptr: UnsafePointer<UInt8>) -> UInt16 {
    // Read little-endian UInt16 byte-by-byte
    return UInt16(ptr[0]) | (UInt16(ptr[1]) << 8)
}

func ReadInt32(from ptr: UnsafePointer<UInt8>) -> Int32 {
    // Read little-endian Int32 byte-by-byte
    return Int32(bitPattern: UInt32(ptr[0]) | (UInt32(ptr[1]) << 8) | (UInt32(ptr[2]) << 16) | (UInt32(ptr[3]) << 24))
}

func ReadUInt32(from ptr: UnsafePointer<UInt8>) -> UInt32 {
    // Read little-endian UInt32 byte-by-byte
    return UInt32(ptr[0]) | (UInt32(ptr[1]) << 8) | (UInt32(ptr[2]) << 16) | (UInt32(ptr[3]) << 24)
}
