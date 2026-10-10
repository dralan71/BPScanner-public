import Foundation

nonisolated struct StoredBloodPressureReading: Identifiable, Equatable, Sendable {
    let id: UUID
    let systolic: Int
    let diastolic: Int
    let pulse: Int?
    let timestamp: Date

    init(id: UUID = UUID(), systolic: Int, diastolic: Int, pulse: Int?, timestamp: Date) {
        self.id = id
        self.systolic = systolic
        self.diastolic = diastolic
        self.pulse = pulse
        self.timestamp = timestamp
    }
}
