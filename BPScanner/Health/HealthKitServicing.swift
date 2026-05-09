import Foundation

protocol HealthKitServicing: Sendable {
    func requestAuthorization() async throws
    func saveReading(systolic: Int, diastolic: Int, pulse: Int?, at timestamp: Date) async throws
    func updateReading(
        _ originalReading: StoredBloodPressureReading,
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        at timestamp: Date
    ) async throws
    func fetchReadings(startDate: Date, endDate: Date) async throws -> [StoredBloodPressureReading]
}
