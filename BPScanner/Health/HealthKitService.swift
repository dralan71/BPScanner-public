// MARK: Health/HealthKitService.swift

import Foundation
import HealthKit

/// Service for managing all HealthKit operations.
/// Handles authorization, reading historical BP data, and saving new readings.
actor HealthKitService {
    static let shared = HealthKitService()

    private let store = HKHealthStore()

    private init() {}

    /// Request HealthKit permissions for reading and writing blood pressure and heart rate.
    /// Should be called once on app launch.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.healthDataUnavailable
        }

        let typesToWrite: Set<HKSampleType> = [
            HKSampleType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            HKSampleType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            HKSampleType.quantityType(forIdentifier: .heartRate)!,
        ]

        let typesToRead: Set<HKObjectType> = [
            HKSampleType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            HKSampleType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            HKSampleType.quantityType(forIdentifier: .heartRate)!,
        ]

        try await store.requestAuthorization(toShare: typesToWrite, read: typesToRead)
    }

    /// Save a blood pressure reading to HealthKit.
    /// Saves systolic and diastolic as an HKCorrelation, and pulse as a separate HKQuantitySample.
    func saveReading(
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        at timestamp: Date
    ) async throws {
        let systolicSample = HKQuantitySample(
            type: HKSampleType.quantityType(forIdentifier: .bloodPressureSystolic)!,
            quantity: HKQuantity(unit: HKUnit.millimeterOfMercury(), doubleValue: Double(systolic)),
            start: timestamp,
            end: timestamp
        )

        let diastolicSample = HKQuantitySample(
            type: HKSampleType.quantityType(forIdentifier: .bloodPressureDiastolic)!,
            quantity: HKQuantity(unit: HKUnit.millimeterOfMercury(), doubleValue: Double(diastolic)),
            start: timestamp,
            end: timestamp
        )

        let bpCorrelation = HKCorrelation(
            type: HKCorrelationType(.bloodPressure),
            start: timestamp,
            end: timestamp,
            objects: [systolicSample, diastolicSample]
        )

        var samplesToSave: [HKSample] = [bpCorrelation]

        // Save pulse if provided
        if let pulse = pulse {
            let pulseSample = HKQuantitySample(
                type: HKSampleType.quantityType(forIdentifier: .heartRate)!,
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: HKUnit.minute()), doubleValue: Double(pulse)),
                start: timestamp,
                end: timestamp
            )
            samplesToSave.append(pulseSample)
        }

        try await store.save(samplesToSave)
    }

    func updateReading(
        _ originalReading: StoredBloodPressureReading,
        systolic: Int,
        diastolic: Int,
        pulse: Int?,
        at timestamp: Date
    ) async throws {
        try await deleteReading(originalReading)
        try await saveReading(systolic: systolic, diastolic: diastolic, pulse: pulse, at: timestamp)
    }

    /// Retrieve blood pressure and heart rate readings for a given time range.
    /// Returns tuples of (systolic, diastolic, pulse, timestamp) sorted by timestamp.
    func fetchReadings(startDate: Date, endDate: Date) async throws -> [StoredBloodPressureReading] {
        let bpType = HKCorrelationType(.bloodPressure)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)

        let bpReadings: [HKSample] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: bpType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                ]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }

        // Fetch heart rate data separately
        let heartRateType = HKSampleType.quantityType(forIdentifier: .heartRate)!
        let pulseReadings: [HKSample] = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
                ]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }

        let pulseSamples = pulseReadings.compactMap { sample -> (date: Date, value: Int)? in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            let pulse = Int(quantitySample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())))
            return (sample.startDate, pulse)
        }

        // Extract systolic and diastolic from correlations
        var result: [StoredBloodPressureReading] = []
        for sample in bpReadings {
            guard let correlation = sample as? HKCorrelation else { continue }

            var systolic: Int?
            var diastolic: Int?

            for obj in correlation.objects {
                guard let quantitySample = obj as? HKQuantitySample else { continue }

                if quantitySample.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue {
                    systolic = Int(quantitySample.quantity.doubleValue(for: HKUnit.millimeterOfMercury()))
                } else if quantitySample.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue {
                    diastolic = Int(quantitySample.quantity.doubleValue(for: HKUnit.millimeterOfMercury()))
                }
            }

            if let systolic = systolic, let diastolic = diastolic {
                let pulse = pulseValue(for: sample.startDate, in: pulseSamples)
                result.append(
                    StoredBloodPressureReading(
                        systolic: systolic,
                        diastolic: diastolic,
                        pulse: pulse,
                        timestamp: sample.startDate
                    )
                )
            }
        }

        return result
    }

    func deleteReading(_ reading: StoredBloodPressureReading) async throws {
        let samples = try await samplesMatching(reading)

        guard !samples.isEmpty else {
            return
        }

        try await store.delete(samples)
    }

    private func samplesMatching(_ reading: StoredBloodPressureReading) async throws -> [HKSample] {
        let nearbyPredicate = HKQuery.predicateForSamples(
            withStart: reading.timestamp.addingTimeInterval(-2),
            end: reading.timestamp.addingTimeInterval(2),
            options: []
        )

        let bloodPressureSamples = try await samples(
            of: HKCorrelationType(.bloodPressure),
            matching: nearbyPredicate
        ).filter { sample in
            guard let correlation = sample as? HKCorrelation else { return false }
            return abs(sample.startDate.timeIntervalSince(reading.timestamp)) <= 2
                && correlation.matches(reading)
        }

        var samplesToDelete = bloodPressureSamples

        if let pulse = reading.pulse {
            let heartRateSamples = try await samples(
                of: HKSampleType.quantityType(forIdentifier: .heartRate)!,
                matching: nearbyPredicate
            ).filter { sample in
                guard let quantitySample = sample as? HKQuantitySample else { return false }
                let value = Int(quantitySample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())))
                return abs(sample.startDate.timeIntervalSince(reading.timestamp)) <= 2
                    && value == pulse
            }
            samplesToDelete.append(contentsOf: heartRateSamples)
        }

        return samplesToDelete
    }

    private func samples(of sampleType: HKSampleType, matching predicate: NSPredicate) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    private func pulseValue(for timestamp: Date, in samples: [(date: Date, value: Int)]) -> Int? {
        if let exactMatch = samples.first(where: { $0.date == timestamp }) {
            return exactMatch.value
        }

        return samples
            .map { sample in
                (value: sample.value, distance: abs(sample.date.timeIntervalSince(timestamp)))
            }
            .filter { $0.distance <= 2 }
            .min { $0.distance < $1.distance }?
            .value
    }
}

private extension HKCorrelation {
    nonisolated func matches(_ reading: StoredBloodPressureReading) -> Bool {
        var systolic: Int?
        var diastolic: Int?

        for obj in objects {
            guard let quantitySample = obj as? HKQuantitySample else { continue }

            if quantitySample.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue {
                systolic = Int(quantitySample.quantity.doubleValue(for: HKUnit.millimeterOfMercury()))
            } else if quantitySample.quantityType.identifier == HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue {
                diastolic = Int(quantitySample.quantity.doubleValue(for: HKUnit.millimeterOfMercury()))
            }
        }

        return systolic == reading.systolic && diastolic == reading.diastolic
    }
}

extension HealthKitService: HealthKitServicing {}

enum HealthKitError: LocalizedError {
    case healthDataUnavailable

    var errorDescription: String? {
        String(localized: "HealthKit data is not available on this device.", bundle: .main)
    }
}
