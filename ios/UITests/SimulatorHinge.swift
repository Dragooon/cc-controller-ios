import Foundation
import XCTest

enum DuoPosture {
    case folded
    case unfolded

    var hingeAngle: Double { self == .folded ? 0 : 180 }
}

/// Opens or closes a foldable simulator's hinge. A Duo simulator boots folded, on its compact outer
/// display, and `simctl` can't change that. The event works in both directions on a running simulator.
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

    /// Applies TEST_RUNNER_HINGE_ANGLE, which is folded when empty, and gives the simulator time to switch displays.
    static func applyConfiguredAngle(settleSeconds: TimeInterval = 4) {
        let angle = ProcessInfo.processInfo.environment["TEST_RUNNER_HINGE_ANGLE"].flatMap { Double($0) } ?? DuoPosture.folded.hingeAngle
        guard set(angle: angle) else {
            XCTFail("Could not dispatch the hinge event for angle \(angle)")
            return
        }
        RunLoop.current.run(until: Date().addingTimeInterval(settleSeconds))
    }

    /// Puts the Duo in a posture and waits until the display has really switched.
    @MainActor
    static func apply(_ posture: DuoPosture) {
        guard current != posture else { return }
        guard set(angle: posture.hingeAngle) else {
            XCTFail("Could not dispatch the hinge event for \(posture)")
            return
        }
        // Budgeted: an unfolding Duo takes a few seconds, and the app isn't running yet at this point.
        XCTAssertTrue(pollUntil(timeout: 15) { current == posture }, "The Duo did not reach \(posture); journeys need the iPhone Duo simulator")
    }

    /// The main screen is the outer display, which the simulator reports as landscape while the Duo is open.
    @MainActor
    private static var current: DuoPosture {
        let size = XCUIScreen.main.screenshot().image.size
        return size.width > size.height ? .unfolded : .folded
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
