import Foundation
import XCTest

/// Opens or closes a foldable simulator's hinge. A Duo simulator boots folded, on its compact outer
/// display, and `simctl` can't change that. Set TEST_RUNNER_HINGE_ANGLE to 180 for the large display.
///
/// The hinge is driven by a vendor-defined HID event carrying an OSSerializeBinary dictionary.
/// Adapted from `IOHingeSet.swift` in mobile-next/devicekit-ios, Copyright 2025-2026 Mobile Next HQ, Inc.,
/// under the Functional Source License, Version 1.1, ALv2 Future License.
enum SimulatorHinge {
    private static let vendorUsagePage: UInt32 = 0xFF61
    private static let hingeUsage: UInt32 = 0x5B
    private static let adminClientType: Int32 = 1

    private typealias CreateVendorDefinedEvent = @convention(c) (
        CFAllocator?, UInt64, UInt32, UInt32, UInt32, UnsafePointer<UInt8>, CFIndex, UInt32
    ) -> Unmanaged<CFTypeRef>?
    private typealias CreateEventSystemClient = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<CFTypeRef>?
    private typealias DispatchEvent = @convention(c) (CFTypeRef, CFTypeRef) -> Void

    /// Applies the configured angle, if any, and gives the simulator time to switch displays.
    static func applyConfiguredAngle(settleSeconds: TimeInterval = 4) {
        guard let value = ProcessInfo.processInfo.environment["TEST_RUNNER_HINGE_ANGLE"],
              let angle = Double(value) else { return }
        guard set(angle: angle) else {
            XCTFail("Could not dispatch the hinge event for angle \(angle)")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settleSeconds))
    }

    private static func set(angle: Double) -> Bool {
        guard let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createEventSymbol = dlsym(ioKit, "IOHIDEventCreateVendorDefinedEvent"),
              let createClientSymbol = dlsym(ioKit, "IOHIDEventSystemClientCreateWithType"),
              let dispatchSymbol = dlsym(ioKit, "IOHIDEventSystemClientDispatchEvent") else { return false }
        let createEvent = unsafeBitCast(createEventSymbol, to: CreateVendorDefinedEvent.self)
        let createClient = unsafeBitCast(createClientSymbol, to: CreateEventSystemClient.self)
        let dispatch = unsafeBitCast(dispatchSymbol, to: DispatchEvent.self)

        let payload = serializedPayload(angle: angle)
        let event = payload.withUnsafeBufferPointer { buffer in
            createEvent(nil, mach_absolute_time(), vendorUsagePage, hingeUsage, 0, buffer.baseAddress!, buffer.count, 0)
        }
        guard let hingeEvent = event?.takeRetainedValue(),
              let client = createClient(nil, adminClientType, nil)?.takeRetainedValue() else { return false }
        dispatch(client, hingeEvent)
        return true
    }

    /// `{value: angle, provider: ..., type: "range", source: "hinge-slider-control"}`
    private static func serializedPayload(angle: Double) -> [UInt8] {
        let endOfCollection: UInt32 = 0x8000_0000
        let dictionaryKind: UInt32 = 0x01 << 24
        let numberKind: UInt32 = 0x04 << 24
        let numberBitCount: UInt32 = 63
        var bytes: [UInt8] = []
        appendWord(0x0000_00D3, to: &bytes)
        appendWord(endOfCollection | dictionaryKind | 4, to: &bytes)
        appendSymbol("value", to: &bytes)
        appendWord(numberKind | numberBitCount, to: &bytes)
        withUnsafeBytes(of: angle.bitPattern.littleEndian) { bytes += $0 }
        appendSymbol("provider", to: &bytes)
        appendString("com.apple.Virtualization.VirtualMachines", isLast: false, to: &bytes)
        appendSymbol("type", to: &bytes)
        appendString("range", isLast: false, to: &bytes)
        appendSymbol("source", to: &bytes)
        appendString("hinge-slider-control", isLast: true, to: &bytes)
        return bytes
    }

    private static func appendSymbol(_ key: String, to bytes: inout [UInt8]) {
        let symbolKind: UInt32 = 0x08 << 24
        let terminated = Array(key.utf8) + [0]
        appendWord(symbolKind | UInt32(terminated.count), to: &bytes)
        appendPadded(terminated, to: &bytes)
    }

    private static func appendString(_ value: String, isLast: Bool, to bytes: inout [UInt8]) {
        let stringKind: UInt32 = 0x09 << 24
        let endOfCollection: UInt32 = isLast ? 0x8000_0000 : 0
        let characters = Array(value.utf8)
        appendWord(endOfCollection | stringKind | UInt32(characters.count), to: &bytes)
        appendPadded(characters, to: &bytes)
    }

    private static func appendPadded(_ content: [UInt8], to bytes: inout [UInt8]) {
        bytes += content
        bytes += [UInt8](repeating: 0, count: (4 - content.count % 4) % 4)
    }

    private static func appendWord(_ word: UInt32, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: word.littleEndian) { bytes += $0 }
    }
}
