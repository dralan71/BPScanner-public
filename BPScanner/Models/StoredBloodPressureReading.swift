import Foundation

struct StoredBloodPressureReading: Identifiable, Equatable, Sendable {
    let systolic: Int
    let diastolic: Int
    let pulse: Int?
    let timestamp: Date

    var id: String {
        "\(timestamp.timeIntervalSinceReferenceDate)-\(systolic)-\(diastolic)-\(pulse ?? -1)"
    }
}
