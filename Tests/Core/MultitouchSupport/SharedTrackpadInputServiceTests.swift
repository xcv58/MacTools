import Foundation
import XCTest
import MacToolsPluginKit
import MultitouchSupport
@testable import MacTools

@MainActor
private final class SensorTestDriver: MultitouchFrameListening {
    var startCount = 0
    var stopCount = 0
    var deviceCount = 1
    var connectedDeviceIDs: Set<UInt64> = [1]
    var handlers: [@Sendable (TrackpadSensorFrame) -> Void] = []
    func start(handler: @escaping @Sendable (TrackpadSensorFrame) -> Void) -> Bool {
        startCount += 1
        handlers.append(handler)
        return true
    }
    func stop() { stopCount += 1 }
    func send(_ contacts: [TrackpadSensorContact] = []) {
        handlers.last?(TrackpadSensorFrame(deviceID: 1, timestamp: 1, contacts: contacts))
    }
}

@MainActor
private final class SensorTestLease: TrackpadSensorLeaseManaging {
    var allowsAcquisition = true
    var shouldRetryAfterFailedAcquisition: Bool { false }
    var owned = false
    func acquire() -> Bool { owned = allowsAcquisition; return owned }
    func release() { owned = false }
}

private final class SensorTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var interruptions = 0
    func receive(_ event: TrackpadSensorEvent) {
        lock.withLock {
            switch event {
            case .frame: frames += 1
            case .interrupted: interruptions += 1
            }
        }
    }
    var counts: (Int, Int) { lock.withLock { (frames, interruptions) } }
}

@MainActor
final class SharedTrackpadInputServiceTests: XCTestCase {
    private let device = TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn,
                                              supportsForce: true, hasPersistentIdentity: true)

    func testSubscribersShareListenerAndResumeOnlyAfterFingerLift() throws {
        let driver = SensorTestDriver()
        let lease = SensorTestLease()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] }, observesDevices: false)
        let gestures = SensorTestEvents()
        let scale = SensorTestEvents()
        let gestureID = try XCTUnwrap(service.subscribe(purpose: .gestures, handler: { gestures.receive($0) }))
        let contact = TrackpadSensorContact(identifier: 1, x: 0.5, y: 0.5, pressure: 10)
        driver.send([contact])
        let scaleID = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { scale.receive($0) }))
        XCTAssertTrue(service.gesturesArePaused)
        XCTAssertNil(service.subscribe(purpose: .weighing, handler: { scale.receive($0) }))
        driver.send([contact])
        XCTAssertEqual(gestures.counts.0, 1)
        XCTAssertEqual(scale.counts.0, 1)
        XCTAssertEqual(driver.startCount, 1)
        service.unsubscribe(scaleID)
        XCTAssertFalse(service.gesturesArePaused)
        driver.send([contact])
        XCTAssertEqual(gestures.counts.0, 1)
        driver.send()
        driver.send([contact])
        XCTAssertEqual(gestures.counts.0, 2)
        service.unsubscribe(gestureID)
        XCTAssertFalse(lease.owned)
        let oldHandler = try XCTUnwrap(driver.handlers.last)
        oldHandler(TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: [contact]))
        XCTAssertEqual(gestures.counts.0, 2)
        XCTAssertEqual(driver.stopCount, 1)
    }

    func testDisabledGesturesRepeatedWeighingAndInterruptedListening() throws {
        let driver = SensorTestDriver()
        let lease = SensorTestLease()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] }, observesDevices: false)
        let events = SensorTestEvents()
        for _ in 0..<3 {
            let token = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
            driver.send()
            service.setActivityState(.systemSleeping)
            XCTAssertEqual(events.counts.1, driver.startCount)
            XCTAssertNil(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
            service.unsubscribe(token)
            service.setActivityState(.interactive)
            XCTAssertFalse(service.gesturesArePaused)
            XCTAssertFalse(lease.owned)
        }
        XCTAssertEqual(driver.startCount, 3)
        service.shutdown()
        XCTAssertNil(service.subscribe(purpose: .gestures, handler: { events.receive($0) }))
    }

    func testPauseCallbackCanUnsubscribeAndRestoreGestureConsumer() throws {
        let driver = SensorTestDriver()
        let device = device
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(), inventory: { [device] }, observesDevices: false)
        let events = SensorTestEvents()
        var gestureToken = service.subscribe(purpose: .gestures, handler: { events.receive($0) })
        service.onGesturePauseChange = { paused in
            if paused {
                if let token = gestureToken { service.unsubscribe(token); gestureToken = nil }
            } else {
                gestureToken = service.subscribe(purpose: .gestures, handler: { events.receive($0) })
            }
        }
        let token = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
        service.unsubscribe(token)
        XCTAssertNotNil(gestureToken)
        XCTAssertEqual(driver.startCount, 1)
        service.shutdown()
    }

    func testDeviceChangesInterruptAndDiscardOldCallbacks() throws {
        let driver = SensorTestDriver()
        var inventory = [device]
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(),
            inventory: { inventory }, observesDevices: false)
        let events = SensorTestEvents()
        let token = try XCTUnwrap(service.subscribe(purpose: .weighing, handler: { events.receive($0) }))
        let staleCallback = try XCTUnwrap(driver.handlers.last)
        inventory = [TrackpadSensorDevice(deviceID: 2, isBuiltIn: true, transport: .builtIn,
                                          supportsForce: true, hasPersistentIdentity: true)]
        service.deviceTopologyDidChange()
        XCTAssertEqual(events.counts.1, 1)
        XCTAssertEqual(service.devices.map(\.deviceID), [2])
        staleCallback(TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: []))
        XCTAssertEqual(events.counts.0, 0)
        service.unsubscribe(token)
        XCTAssertFalse(service.gesturesArePaused)
    }

    func testUnsupportedCapabilitiesAndFailedLeaseDoNotPauseGestures() {
        let driver = SensorTestDriver()
        let unsupported = TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn)
        let service = SharedTrackpadInputService(driver: driver, lease: SensorTestLease(), inventory: { [unsupported] }, observesDevices: false)
        XCTAssertNil(service.subscribe(purpose: .weighing) { _ in })
        XCTAssertFalse(service.gesturesArePaused)
        XCTAssertEqual(driver.startCount, 0)
        let lease = SensorTestLease()
        lease.allowsAcquisition = false
        let device = device
        let denied = SharedTrackpadInputService(driver: driver, lease: lease, inventory: { [device] }, observesDevices: false)
        XCTAssertNil(denied.subscribe(purpose: .weighing) { _ in })
        XCTAssertFalse(denied.gesturesArePaused)
        XCTAssertFalse(lease.owned)
        let native = MultitouchDeviceDriver(runtime: nil)
        XCTAssertFalse(native.start { _ in })
        XCTAssertEqual(native.deviceCount, 0)
    }

    func testNativeTouchPressureLayoutRemainsCompatible() {
        XCTAssertEqual(MemoryLayout<MTTouch>.stride, 96)
        XCTAssertEqual(MemoryLayout<MTTouch>.offset(of: \.pressure), 52)
    }

    func testCallbackRegistryRejectsUnregisteredAndUnknownSources() {
        let events = SensorTestEvents()
        let gate = MultitouchFrameCallbackGate()
        gate.activate(deviceIDsByCallbackSource: [4: 1]) { frame in events.receive(.frame(frame)) }
        let refcon = MultitouchCallbackContextRegistry.shared.insert(gate)
        XCTAssertNotNil(MultitouchCallbackContextRegistry.shared.gate(for: refcon))
        XCTAssertFalse(gate.deliver(TrackpadSensorFrame(deviceID: 5, timestamp: 1, contacts: [])))
        XCTAssertTrue(gate.deliver(TrackpadSensorFrame(deviceID: 4, timestamp: 1, contacts: [])))
        gate.invalidate()
        MultitouchCallbackContextRegistry.shared.remove(refcon)
        XCTAssertNil(MultitouchCallbackContextRegistry.shared.gate(for: refcon))
        XCTAssertFalse(gate.deliver(TrackpadSensorFrame(deviceID: 4, timestamp: 2, contacts: [])))
        XCTAssertEqual(events.counts.0, 1)
    }

    func testProcessLeaseHonorsDisabledPolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let denied = TrackpadSensorProcessLease(temporaryDirectory: directory, isAcquisitionAllowed: false)
        let allowed = TrackpadSensorProcessLease(temporaryDirectory: directory, isAcquisitionAllowed: true)
        XCTAssertFalse(denied.acquire())
        XCTAssertTrue(allowed.acquire())
        allowed.release()
    }
}
