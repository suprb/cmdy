import CoreGraphics
import XCTest
@testable import sim

final class SimMirrorSessionsTests: XCTestCase {
    func testEachWindowReceivesAnIndependentPort() {
        var slots = SimMirrorSlots()

        let first = slots.reserve(
            for: 101, device: "iPhone 16",
            ports: 3200...3202, isPortAvailable: { _ in true })
        let second = slots.reserve(
            for: 202, device: "iPad mini",
            ports: 3200...3202, isPortAvailable: { _ in true })

        XCTAssertEqual(first?.slot.port, 3200)
        XCTAssertEqual(first?.slot.device, "iPhone 16")
        XCTAssertEqual(second?.slot.port, 3201)
        XCTAssertEqual(second?.slot.device, "iPad mini")
        XCTAssertEqual(slots.all.map(\.windowNumber), [101, 202])
    }

    func testSameWindowReusesItsExistingSlot() {
        var slots = SimMirrorSlots()
        let first = slots.reserve(
            for: 101, device: nil,
            ports: 3200...3202, isPortAvailable: { _ in true })
        let again = slots.reserve(
            for: 101, device: "ignored",
            ports: 3200...3202, isPortAvailable: { _ in true })

        XCTAssertEqual(first?.slot, again?.slot)
        XCTAssertEqual(first?.inserted, true)
        XCTAssertEqual(again?.inserted, false)
        XCTAssertEqual(slots.all.count, 1)
    }

    func testUnavailablePortsAreSkipped() {
        var slots = SimMirrorSlots()
        let slot = slots.reserve(
            for: 101, device: nil,
            ports: 3200...3202,
            isPortAvailable: { $0 == 3202 })

        XCTAssertEqual(slot?.slot.port, 3202)
    }

    func testClosingOneWindowReleasesOnlyItsMirror() {
        var slots = SimMirrorSlots()
        _ = slots.reserve(
            for: 101, device: nil,
            ports: 3200...3202, isPortAvailable: { _ in true })
        _ = slots.reserve(
            for: 202, device: nil,
            ports: 3200...3202, isPortAvailable: { _ in true })

        XCTAssertEqual(slots.release(101)?.port, 3200)
        XCTAssertNil(slots.slot(for: 101))
        XCTAssertEqual(slots.slot(for: 202)?.port, 3201)

        let replacement = slots.reserve(
            for: 303, device: nil,
            ports: 3200...3202, isPortAvailable: { _ in true })
        XCTAssertEqual(replacement?.slot.port, 3200)
    }

    func testReservationFailsWhenEveryPortIsUnavailableOrReserved() {
        var slots = SimMirrorSlots()
        _ = slots.reserve(
            for: 101, device: nil,
            ports: 3200...3200, isPortAvailable: { _ in true })

        XCTAssertNil(slots.reserve(
            for: 202, device: nil,
            ports: 3200...3200, isPortAvailable: { _ in true }))
    }
}
