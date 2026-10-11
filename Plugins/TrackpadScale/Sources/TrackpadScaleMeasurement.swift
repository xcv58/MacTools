import Foundation
import MacToolsPluginKit

/// Empirical pressure units, never an Apple-specified mass or accuracy contract.
/// Only a small transient stability window is retained, and it is cleared at boundaries.
struct TrackpadScaleMeasurement {
    enum State: String {
        case stopped, unsupported, noContact, multipleContacts, needsTare, measuring, invalidSample, interrupted
    }

    private(set) var state: State = .stopped
    private(set) var device: TrackpadSensorDevice?
    private(set) var factor: Double = 1
    private(set) var estimatedGrams: Double?
    private(set) var isStable = false
    private(set) var hasPressureReading = false
    private(set) var tare: Double?
    private var contactID: Int?
    private var filtered: Double?
    private var lastTimestamp: TimeInterval?
    private var history: [(TimeInterval, Double)] = []

    var canTare: Bool { isStable && filtered != nil && contactID != nil }
    var canCalibrate: Bool {
        isStable && tare != nil && (filtered ?? 0) - (tare ?? 0) > 0.5
    }

    mutating func start(device: TrackpadSensorDevice?, factor: Double) {
        self = Self()
        guard let device, device.supportsWeighing else { state = .unsupported; return }
        self.device = device
        self.factor = Self.validFactor(factor) ? factor : 1
        state = .noContact
    }

    mutating func stop(interrupted: Bool = false) {
        self = Self()
        state = interrupted ? .interrupted : .stopped
    }

    mutating func invalidate(_ state: State) {
        tare = nil
        contactID = nil
        resetFilter()
        self.state = state
    }

    mutating func receive(_ frame: TrackpadSensorFrame, pressureRange: ClosedRange<Double>? = nil) {
        guard let device, state != .stopped, state != .unsupported else { return }
        guard frame.deviceID == device.deviceID else { invalidate(.interrupted); return }
        guard frame.timestamp.isFinite,
              lastTimestamp.map({ frame.timestamp > $0 }) ?? true else {
            invalidate(.invalidSample)
            return
        }
        if let lastTimestamp, frame.timestamp - lastTimestamp > 0.8 {
            invalidate(.interrupted)
        }
        guard !frame.contacts.isEmpty else { invalidate(.noContact); return }
        guard frame.contacts.count == 1 else { invalidate(.multipleContacts); return }
        let contact = frame.contacts[0]
        guard contact.pressure.isFinite, contact.pressure > 0,
              contact.x.isFinite, contact.y.isFinite,
              (0...1).contains(contact.x), (0...1).contains(contact.y) else {
            invalidate(.invalidSample)
            return
        }
        if contactID != contact.identifier {
            invalidate(.needsTare)
            contactID = contact.identifier
        }
        hasPressureReading = true
        let elapsed = frame.timestamp - (lastTimestamp ?? frame.timestamp)
        let alpha = 1 - exp(-max(0, elapsed) / 0.20)
        filtered = filtered.map { $0 + alpha * (contact.pressure - $0) } ?? contact.pressure
        lastTimestamp = frame.timestamp
        // Time-based stability uses unsmoothed values so smoothing cannot hide motion.
        if let pressureRange {
            history.append((frame.timestamp, pressureRange.lowerBound))
            history.append((frame.timestamp, pressureRange.upperBound))
        } else {
            history.append((frame.timestamp, contact.pressure))
        }
        history.removeAll { frame.timestamp - $0.0 > 0.6 }
        if history.count > 80 { history.removeFirst(history.count - 80) }
        let spread = (history.map(\.1).max() ?? 0) - (history.map(\.1).min() ?? 0)
        isStable = history.count >= 6
            && frame.timestamp - (history.first?.0 ?? frame.timestamp) >= 0.45
            && spread * factor <= 1.5
        if let tare, let filtered {
            let grams = (filtered - tare) * factor
            guard grams.isFinite else { invalidate(.invalidSample); return }
            estimatedGrams = max(0, grams)
            state = .measuring
        } else {
            estimatedGrams = nil
            state = .needsTare
        }
    }

    @discardableResult
    mutating func zero() -> Bool {
        guard canTare, let filtered else { return false }
        tare = filtered
        resetFilter()
        state = .measuring
        return true
    }

    /// Calibrate with an independently known small mass while the same finger stays in place.
    @discardableResult
    mutating func calibrate(knownGrams: Double) -> Bool {
        guard knownGrams.isFinite, (1...100).contains(knownGrams), canCalibrate,
              let filtered, let tare else { return false }
        let newFactor = knownGrams / (filtered - tare)
        guard Self.validFactor(newFactor) else { return false }
        factor = newFactor
        resetFilter()
        state = .measuring
        return true
    }

    mutating func resetCalibration() {
        factor = 1
        invalidate(.needsTare)
    }

    private mutating func resetFilter() {
        filtered = nil
        lastTimestamp = nil
        history.removeAll(keepingCapacity: true)
        estimatedGrams = nil
        isStable = false
        hasPressureReading = false
    }

    static func validFactor(_ factor: Double) -> Bool {
        factor.isFinite && (0.01...100).contains(factor)
    }
}
