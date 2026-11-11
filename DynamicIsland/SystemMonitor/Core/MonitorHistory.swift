import Foundation

/// Fixed-capacity history ring. Kept deliberately small (120 samples by
/// default) and allocation-light: one append per successful sample.
struct MonitorHistory: Equatable, Sendable {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 120) {
        self.capacity = max(1, capacity)
        values.reserveCapacity(self.capacity)
    }

    mutating func append(_ value: Double) {
        guard value.isFinite else { return }
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    mutating func reset() {
        values.removeAll(keepingCapacity: true)
    }

    var latest: Double? { values.last }
    var isEmpty: Bool { values.isEmpty }
}
